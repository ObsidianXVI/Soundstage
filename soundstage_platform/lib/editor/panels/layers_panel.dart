import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import 'layers_model.dart';

/// The Layers panel (architecture §15): the active scene's node tree.
///
/// - Virtualised: only the rows in view are built (every row is
///   [SsSpace.controlHeight] tall), so a 5,000-node scene stays smooth.
/// - Selection and hover are the editor's: a click selects, Shift extends a
///   range, Cmd/Ctrl toggles; the row under the pointer is the hovered node
///   on the canvas and vice versa.
/// - Rows rename inline (double-click, Enter or F2, or Cmd+R anywhere in the
///   editor through `EditorController.events`), toggle visibility and
///   lock, and open a context menu. Keys: Up/Down move the selection,
///   Left/Right collapse and expand, Delete deletes.
/// - Dragging a row reorders and reparents (one [MoveNodes] on drop, so one
///   undo step), with a line between rows or an outline around a frame.
/// - An instance's inside is shown read-only.
///
/// Reads and writes everything through [editorControllerProvider].
class LayersPanel extends ConsumerStatefulWidget {
  const LayersPanel({super.key});

  @override
  ConsumerState<LayersPanel> createState() => _LayersPanelState();
}

class _Drag {
  _Drag({required this.ids, required this.label, required this.pointer});

  final Set<String> ids;
  final String label;

  /// The pointer in the list's coordinates.
  Offset pointer;
  LayerDropPlan? plan;

  /// Whether the pointer has travelled far enough to be a drag, not a click.
  bool active = false;
}

const double _rowH = SsSpace.controlHeight;
const double _topPad = SsSpace.s1;
const double _dragSlop = 5;

class _LayersPanelState extends ConsumerState<LayersPanel> {
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'LayersPanel');
  final GlobalKey _listKey = GlobalKey();

  List<LayerRow> _rows = const [];
  Map<String, int> _indexOf = const {};
  Object? _rowsRoot;
  Set<String>? _rowsExpanded;
  String _rootId = '';

  String? _anchor;
  String? _renamingId;
  _Drag? _drag;
  Offset? _dragStartGlobal;
  Timer? _autoScroll;
  StreamSubscription<String>? _renames;

  EditorController get _ctl => ref.read(editorControllerProvider.notifier);
  EditorState get _state => ref.read(editorControllerProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reveal(_state.selection);
    });
    // Cmd+R / F2 from anywhere in the editor (T1.4): reveal the row, then
    // open its rename field once it is built.
    _renames = _ctl.events.renameRequests.listen((id) {
      if (!mounted) return;
      _reveal({id});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _beginRename(id);
      });
    });
  }

  @override
  void dispose() {
    unawaited(_renames?.cancel());
    _autoScroll?.cancel();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---- Rows -----------------------------------------------------------------

  ir.ResolvedScene? _scene() {
    final bp = _state.breakpointId;
    if (bp == null) return null;
    return ref.read(resolvedForProvider(bp)).scene(_state.activeSceneId);
  }

  void _updateRows(ir.ResolvedScene scene, Set<String> expanded) {
    if (identical(_rowsRoot, scene.root) &&
        identical(_rowsExpanded, expanded)) {
      return;
    }
    _rowsRoot = scene.root;
    _rowsExpanded = expanded;
    _rootId = scene.root.id;
    _rows = flattenLayers(scene.root, expanded);
    _indexOf = {for (final (i, r) in _rows.indexed) r.id: i};
  }

  // ---- Reveal ---------------------------------------------------------------

  /// Expands the ancestors of the last selected node and scrolls it into
  /// view.
  void _reveal(Set<String> selection) {
    if (selection.isEmpty) return;
    final scene = _scene();
    if (scene == null) return;
    final tree = ResolvedSelectionTree.of(scene.root);
    final id = selection.last;
    if (!tree.contains(id)) return;
    ref
        .read(layersExpansionProvider.notifier)
        .expandAll(tree.ancestorsOf(id).where((a) => a != tree.rootId));
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (mounted) _scrollTo(id);
      })
      ..ensureVisualUpdate();
  }

  void _scrollTo(String id, {bool animate = true}) {
    final i = _indexOf[id];
    if (i == null || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final top = _topPad + i * _rowH;
    double? target;
    if (top < pos.pixels) {
      target = top - _topPad;
    } else if (top + _rowH > pos.pixels + pos.viewportDimension) {
      target = top + _rowH - pos.viewportDimension + _topPad;
    }
    if (target == null) return;
    target = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (animate) {
      _scroll.animateTo(
        target,
        duration: SsMotion.fast,
        curve: SsMotion.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  // ---- Selection ------------------------------------------------------------

  static bool get _shift => HardwareKeyboard.instance.isShiftPressed;
  static bool get _deep =>
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isControlPressed;

  void _click(LayerRow row) {
    final sel = _state.selection;
    if (HardwareKeyboard.instance.logicalKeysPressed.contains(
          LogicalKeyboardKey.enter,
        ) &&
        sel.length == 1 &&
        sel.contains(row.id)) {
      // Enter on a focused row activates it.
      _beginRename(row.id);
      return;
    }
    if (_shift) {
      _selectRange(row.id);
    } else if (_deep) {
      final next = {...sel};
      if (!next.remove(row.id)) next.add(row.id);
      _ctl.select(next);
      _anchor = row.id;
    } else {
      _ctl.select({row.id});
      _anchor = row.id;
    }
    _focus.requestFocus();
  }

  /// Selects the rows between the anchor and [id], without descendants of
  /// selected rows.
  void _selectRange(String id) {
    final anchor =
        _anchor ?? (_state.selection.isEmpty ? id : _state.selection.first);
    final a = _indexOf[anchor], b = _indexOf[id];
    if (a == null || b == null) {
      _ctl.select({id});
      _anchor = id;
      return;
    }
    final lo = math.min(a, b), hi = math.max(a, b);
    final ids = {for (var i = lo; i <= hi; i++) _rows[i].id};
    final picked = <String>{
      for (var i = lo; i <= hi; i++)
        if (!_hasSelectedAncestor(_rows[i], ids)) _rows[i].id,
    };
    _ctl.select(picked);
    _anchor = anchor;
  }

  bool _hasSelectedAncestor(LayerRow row, Set<String> ids) {
    String p = row.parentId;
    while (true) {
      if (ids.contains(p)) return true;
      final i = _indexOf[p];
      if (i == null) return false;
      p = _rows[i].parentId;
    }
  }

  /// The nodes a command on [row] applies to: the selection when [row] is
  /// in it, else just [row].
  List<String> _targets(String id) {
    final sel = _state.selection;
    final ids = sel.contains(id) ? sel.toList() : [id];
    return [
      for (final t in ids)
        if (!t.contains('/')) t,
    ];
  }

  // ---- Keyboard -------------------------------------------------------------

  String? get _cursor =>
      _state.selection.isEmpty ? null : _state.selection.last;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _renamingId != null) {
      return KeyEventResult.ignored;
    }
    if (_rows.isEmpty) return KeyEventResult.ignored;
    final k = event.logicalKey;
    final cursor = _cursor;
    final i = cursor == null ? null : _indexOf[cursor];
    if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp) {
      final down = k == LogicalKeyboardKey.arrowDown;
      final next = i == null
          ? (down ? 0 : _rows.length - 1)
          : (i + (down ? 1 : -1)).clamp(0, _rows.length - 1);
      final row = _rows[next];
      if (_shift) {
        _selectRange(row.id);
      } else {
        _ctl.select({row.id});
        _anchor = row.id;
      }
      _scrollTo(row.id, animate: false);
      _focus.requestFocus();
      return KeyEventResult.handled;
    }
    if (i == null) return KeyEventResult.ignored;
    final row = _rows[i];
    if (k == LogicalKeyboardKey.arrowRight) {
      final expansion = ref.read(layersExpansionProvider.notifier);
      if (row.hasChildren && !row.expanded) {
        expansion.set(row.id, true);
      } else if (row.expanded && i + 1 < _rows.length) {
        _ctl.select({_rows[i + 1].id});
        _anchor = _rows[i + 1].id;
        _scrollTo(_rows[i + 1].id, animate: false);
      }
      _focus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (row.expanded) {
        ref.read(layersExpansionProvider.notifier).set(row.id, false);
      } else if (_indexOf[row.parentId] case final p?) {
        _ctl.select({_rows[p].id});
        _anchor = _rows[p].id;
        _scrollTo(_rows[p].id, animate: false);
      }
      _focus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.f2) {
      _beginRename(row.id);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete || k == LogicalKeyboardKey.backspace) {
      final ids = _targets(row.id);
      if (ids.isNotEmpty) _ctl.execute(DeleteNodes(ids));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- Rename, toggles, menu ------------------------------------------------

  void _beginRename(String id) {
    final i = _indexOf[id];
    if (i == null || _rows[i].readOnly || _rows[i].node.node.common.locked) {
      return;
    }
    _scrollTo(id, animate: false);
    setState(() => _renamingId = id);
  }

  void _endRename() {
    if (_renamingId == null) return;
    setState(() => _renamingId = null);
    _focus.requestFocus();
  }

  void _openMenu(LayerRow row, Offset position) {
    final sel = _state.selection;
    if (!sel.contains(row.id)) {
      _ctl.select({row.id});
      _anchor = row.id;
    }
    final ids = _targets(row.id);
    final nodes = [
      for (final id in ids) ?ir.DocumentIndex.of(_state.document).node(id),
    ];
    final editable = !row.readOnly && ids.isNotEmpty;
    final allHidden = nodes.isNotEmpty && nodes.every((n) => !n.common.visible);
    final allLocked = nodes.isNotEmpty && nodes.every((n) => n.common.locked);
    showSsContextMenu(
      context,
      position: position,
      entries: [
        SsMenuItem(
          label: 'Rename',
          icon: SsIcons.pencil,
          shortcut: 'Enter',
          enabled: editable && ids.length == 1,
          onSelected: () => _beginRename(row.id),
        ),
        SsMenuItem(
          label: 'Duplicate',
          icon: SsIcons.copy,
          shortcut: '⌘D',
          enabled: editable,
          onSelected: () => _ctl.execute(DuplicateNodes(ids)),
        ),
        SsMenuItem(
          label: 'Delete',
          icon: SsIcons.trash2,
          shortcut: '⌫',
          danger: true,
          enabled: editable,
          onSelected: () => _ctl.execute(DeleteNodes(ids)),
        ),
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Wrap in frame',
          icon: SsIcons.frame,
          shortcut: '⌥⌘G',
          enabled: editable,
          onSelected: () => _ctl.execute(WrapInFrame(ids)),
        ),
        SsMenuItem(
          label: 'Add auto layout',
          icon: SsIcons.layoutTemplate,
          shortcut: '⇧A',
          enabled: editable,
          onSelected: () => _ctl.execute(AddAutoLayout(ids)),
        ),
        const SsMenuDivider(),
        SsMenuItem(
          label: allHidden ? 'Show' : 'Hide',
          icon: allHidden ? SsIcons.eye : SsIcons.eyeOff,
          enabled: editable,
          onSelected: () => _ctl.execute(SetVisible(ids, allHidden)),
        ),
        SsMenuItem(
          label: allLocked ? 'Unlock' : 'Lock',
          icon: allLocked ? SsIcons.lockOpen : SsIcons.lock,
          enabled: editable,
          onSelected: () => _ctl.execute(SetLocked(ids, !allLocked)),
        ),
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Copy ID',
          icon: SsIcons.link,
          onSelected: () => Clipboard.setData(ClipboardData(text: row.id)),
        ),
      ],
    );
  }

  // ---- Drag and drop --------------------------------------------------------

  Offset? _toList(Offset global) {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  void _dragStart(LayerRow row, DragStartDetails d) {
    final local = _toList(d.globalPosition);
    if (local == null || row.readOnly) return;
    _dragStartGlobal = d.globalPosition;
    final sel = _state.selection;
    final ids = sel.contains(row.id)
        ? {
            for (final id in sel)
              if (!id.contains('/')) id,
          }
        : {row.id};
    final label = ids.length == 1
        ? layerName(row.node.node, instance: row.isInstance)
        : '${ids.length} layers';
    _drag = _Drag(ids: ids, label: label, pointer: local);
  }

  void _dragUpdate(DragUpdateDetails d) {
    final drag = _drag;
    final local = _toList(d.globalPosition);
    if (drag == null || local == null) return;
    if (!drag.active) {
      if ((d.globalPosition - _dragStartGlobal!).distance < _dragSlop) return;
      drag.active = true;
      if (!_state.selection.containsAll(drag.ids)) _ctl.select(drag.ids);
      _autoScroll ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _autoScrollTick(),
      );
    }
    drag.pointer = local;
    _replan();
  }

  void _replan() {
    final drag = _drag;
    if (drag == null) return;
    final y = drag.pointer.dy + _scroll.offset - _topPad;
    final plan = planLayerDrop(
      rows: _rows,
      rootId: _rootId,
      rowPos: y / _rowH,
      dragged: drag.ids,
    );
    setState(() => drag.plan = plan);
  }

  void _autoScrollTick() {
    final drag = _drag;
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (drag == null || box == null || !_scroll.hasClients) return;
    const edge = 28.0;
    final h = box.size.height;
    var dy = 0.0;
    if (drag.pointer.dy < edge) {
      dy = -(edge - drag.pointer.dy) / 2;
    } else if (drag.pointer.dy > h - edge) {
      dy = (drag.pointer.dy - (h - edge)) / 2;
    }
    if (dy == 0) return;
    final pos = _scroll.position;
    final next = (pos.pixels + dy).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (next == pos.pixels) return;
    _scroll.jumpTo(next);
    _replan();
  }

  void _dragEnd(LayerRow row) {
    final drag = _drag;
    _endDrag();
    if (drag == null) return;
    if (!drag.active) {
      _click(row);
      return;
    }
    final plan = drag.plan;
    if (plan == null || !plan.valid) return;
    final r = _ctl.execute(
      MoveNodes(drag.ids.toList(), plan.parentId, plan.index),
    );
    if (r.ok && plan.insideRow != null) {
      ref.read(layersExpansionProvider.notifier).set(plan.parentId, true);
    }
  }

  void _endDrag() {
    _autoScroll?.cancel();
    _autoScroll = null;
    _dragStartGlobal = null;
    if (mounted) setState(() => _drag = null);
  }

  // ---- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bp = ref.watch(
      editorControllerProvider.select((s) => s.breakpointId),
    );
    final sceneId = ref.watch(
      editorControllerProvider.select((s) => s.activeSceneId),
    );
    final expanded = ref.watch(layersExpansionProvider);
    ref.listen(
      editorControllerProvider.select((s) => s.selection),
      (_, next) => _reveal(next),
    );
    final scene = bp == null
        ? null
        : ref.watch(resolvedForProvider(bp)).scene(sceneId);
    if (scene == null) {
      return const _PanelEmpty(
        icon: SsIcons.layers,
        title: 'No scene',
        body: 'Pick a scene to see its layers.',
      );
    }
    _updateRows(scene, expanded);
    if (_rows.isEmpty) {
      return const _PanelEmpty(
        icon: SsIcons.layers,
        title: 'This scene is empty',
        body: 'Layers you add to the scene appear here.',
      );
    }
    final t = context.ss;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: Semantics(
        container: true,
        label: 'Layers',
        child: Stack(
          children: [
            Positioned.fill(
              key: _listKey,
              child: ListView.builder(
                controller: _scroll,
                itemCount: _rows.length,
                itemExtent: _rowH,
                padding: const EdgeInsets.symmetric(
                  horizontal: SsSpace.s2,
                  vertical: _topPad,
                ),
                itemBuilder: (context, i) => _buildRow(_rows[i]),
              ),
            ),
            if (_drag?.active ?? false) ...[
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _scroll,
                    builder: (context, _) => CustomPaint(
                      painter: _DropPainter(
                        plan: _drag!.plan,
                        scroll: _scroll.hasClients ? _scroll.offset : 0,
                        valid: t.colors.accent,
                        invalid: t.colors.danger,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: _drag!.pointer.dx + 12,
                top: _drag!.pointer.dy + 8,
                child: IgnorePointer(child: _DragChip(label: _drag!.label)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRow(LayerRow row) {
    final tile = _LayerTile(
      key: ValueKey<String>(row.id),
      row: row,
      renaming: _renamingId == row.id,
      dragging: (_drag?.active ?? false) && _drag!.ids.contains(row.id),
      onTap: () => _click(row),
      onKey: _onKey,
      onMenu: (p) => _openMenu(row, p),
      onToggleExpanded: (open) =>
          ref.read(layersExpansionProvider.notifier).set(row.id, open),
      onRename: (name) => _ctl.execute(RenameNode(row.id, name)),
      onRenameEnd: _endRename,
      onVisible: (v) => _ctl.execute(SetVisible(_targets(row.id), v)),
      onLocked: (v) => _ctl.execute(SetLocked(_targets(row.id), v)),
    );
    if (row.readOnly) return tile;
    return GestureDetector(
      key: ValueKey<String>('drag-${row.id}'),
      supportedDevices: const {
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      },
      onPanStart: (d) => _dragStart(row, d),
      onPanUpdate: _dragUpdate,
      onPanEnd: (_) => _dragEnd(row),
      onPanCancel: _endDrag,
      child: tile,
    );
  }
}

/// One row: reads its own selection and hover, so selecting or hovering
/// rebuilds the rows that changed.
class _LayerTile extends ConsumerWidget {
  const _LayerTile({
    required this.row,
    required this.renaming,
    required this.dragging,
    required this.onTap,
    required this.onKey,
    required this.onMenu,
    required this.onToggleExpanded,
    required this.onRename,
    required this.onRenameEnd,
    required this.onVisible,
    required this.onLocked,
    super.key,
  });

  final LayerRow row;
  final bool renaming;
  final bool dragging;
  final VoidCallback onTap;
  final FocusOnKeyEventCallback onKey;
  final ValueChanged<Offset> onMenu;
  final ValueChanged<bool> onToggleExpanded;
  final ValueChanged<String> onRename;
  final VoidCallback onRenameEnd;
  final ValueChanged<bool> onVisible;
  final ValueChanged<bool> onLocked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = row.id;
    final selected = ref.watch(
      editorControllerProvider.select((s) => s.selection.contains(id)),
    );
    final hovered = ref.watch(
      editorControllerProvider.select((s) => s.hoverId == id),
    );
    final node = row.node.node;
    final common = node.common;
    final c = context.ss.colors;
    final badge = roleBadge(common.role);
    final ctl = ref.read(editorControllerProvider.notifier);
    return Opacity(
      opacity: dragging ? 0.5 : 1,
      child: MouseRegion(
        onEnter: (_) => ctl.hover(id),
        onExit: (_) {
          if (ref.read(editorControllerProvider).hoverId == id) ctl.hover(null);
        },
        child: SsTreeRow(
          label: layerName(node, instance: row.isInstance),
          depth: row.depth,
          indent: 14,
          icon: layerIcon(node, instance: row.isInstance),
          hasChildren: row.hasChildren,
          expanded: row.expanded,
          selected: selected,
          highlighted: hovered && !selected,
          visible: common.visible,
          locked: common.locked,
          dimmed: row.dimmed,
          renameEnabled: !row.readOnly,
          startRenaming: renaming,
          onRenameEnd: onRenameEnd,
          onKeyEvent: onKey,
          onTap: onTap,
          onExpandedChanged: onToggleExpanded,
          onRename: row.readOnly ? null : onRename,
          onVisibleChanged: row.readOnly ? null : onVisible,
          onLockedChanged: row.readOnly ? null : onLocked,
          onSecondaryTapDown: (d) => onMenu(d.globalPosition),
          trailing: row.readOnly
              ? Semantics(
                  label: 'Read-only',
                  child: SsIcon(SsIcons.lock, size: 12, color: c.textDisabled),
                )
              : (badge == null
                    ? null
                    : _RoleBadge(role: common.role, text: badge)),
        ),
      ),
    );
  }
}

class _RoleBadge extends StatelessWidget {
  const _RoleBadge({required this.role, required this.text});

  final ir.NodeRole role;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Semantics(
      label: 'Role: ${roleName(role)}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: SsSpace.s1),
        decoration: BoxDecoration(
          borderRadius: SsRadius.brSm,
          border: Border.all(color: t.colors.borderSubtle),
        ),
        child: Text(
          text,
          maxLines: 1,
          style: t.text.caption.copyWith(
            color: t.colors.textDisabled,
            fontSize: 10,
            height: 14 / 10,
          ),
        ),
      ),
    );
  }
}

class _DragChip extends StatelessWidget {
  const _DragChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2, vertical: 2),
      decoration: BoxDecoration(
        color: t.colors.surface3,
        borderRadius: SsRadius.brSm,
        border: Border.all(color: t.colors.border),
        boxShadow: SsElevation.e2,
      ),
      child: Text(label, style: t.text.small),
    );
  }
}

/// Paints the drop indicator: a line between rows, or an outline around the
/// frame being dropped into.
class _DropPainter extends CustomPainter {
  const _DropPainter({
    required this.plan,
    required this.scroll,
    required this.valid,
    required this.invalid,
  });

  final LayerDropPlan? plan;
  final double scroll;
  final Color valid;
  final Color invalid;

  @override
  void paint(Canvas canvas, Size size) {
    final p = plan;
    if (p == null) return;
    final color = p.valid ? valid : invalid;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    const left = SsSpace.s2;
    final width = size.width - SsSpace.s2 * 2;
    if (p.insideRow case final i?) {
      final top = _topPad + i * _rowH - scroll;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, top, width, _rowH),
          const Radius.circular(SsRadius.sm),
        ),
        paint,
      );
    } else if (p.lineAtRow case final i?) {
      final y = _topPad + i * _rowH - scroll;
      final x = left + SsSpace.s1 + p.lineDepth * 14 + 18;
      canvas.drawLine(Offset(x, y), Offset(left + width, y), paint);
      canvas.drawCircle(Offset(x, y), 3, paint..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_DropPainter old) =>
      old.plan != plan ||
      old.scroll != scroll ||
      old.valid != valid ||
      old.invalid != invalid;
}

class _PanelEmpty extends StatelessWidget {
  const _PanelEmpty({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsIcon(icon, size: 24, color: t.colors.textDisabled),
            const SizedBox(height: SsSpace.s3),
            Text(title, style: t.text.bodyStrong, textAlign: TextAlign.center),
            const SizedBox(height: SsSpace.s1),
            Text(
              body,
              textAlign: TextAlign.center,
              style: t.text.small.copyWith(color: t.colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
