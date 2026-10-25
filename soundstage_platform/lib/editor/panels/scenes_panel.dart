import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';

/// The Scenes panel (architecture §3.2, §15): the story's scenes in reading
/// order, and the settings of the active scene.
///
/// - Click a scene to make it the active one (the canvas shows it).
/// - Add (pinned or flow), duplicate, delete (with confirmation), rename
///   inline (double-click or F2), and drag to reorder.
/// - Settings of the active scene: kind (pinned / flow), scroll length
///   (pinned only), background colour, export mode and poster clock.
///   Scrubbing and colour drags are one undo step each.
///
/// Reads and writes everything through [editorControllerProvider].
class ScenesPanel extends ConsumerStatefulWidget {
  const ScenesPanel({super.key});

  @override
  ConsumerState<ScenesPanel> createState() => _ScenesPanelState();
}

const double _rowH = SsSpace.controlHeight;
const double _pad = SsSpace.s1;

String _sceneLabel(ir.Scene s, int index) =>
    s.name.trim().isEmpty ? 'Scene ${index + 1}' : s.name;

class _ScenesPanelState extends ConsumerState<ScenesPanel> {
  final ScrollController _scroll = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  final FocusNode _focus = FocusNode(debugLabel: 'ScenesPanel');

  String? _renamingId;
  String? _dragId;
  Offset? _dragStart;
  Offset _pointer = Offset.zero;
  bool _dragActive = false;
  int? _dropIndex;
  Timer? _autoScroll;

  EditorController get _ctl => ref.read(editorControllerProvider.notifier);
  EditorState get _state => ref.read(editorControllerProvider);

  @override
  void dispose() {
    _autoScroll?.cancel();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---- Actions --------------------------------------------------------------

  void _add(ir.SceneKind kind, {int? index}) {
    final n = _state.document.scenes.length + 1;
    _ctl.execute(AddScene(kind: kind, index: index, name: 'Scene $n'));
  }

  Future<void> _delete(ir.Scene scene, int index) async {
    final ok = await showSsConfirm(
      context,
      title: 'Delete scene',
      message:
          '"${_sceneLabel(scene, index)}" and everything in it will be '
          'deleted. You can undo this.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (ok && mounted) _ctl.execute(DeleteScene(scene.id));
  }

  void _openMenu(ir.Scene scene, int index, Offset position) {
    final scenes = _state.document.scenes;
    _ctl.setActiveScene(scene.id);
    showSsContextMenu(
      context,
      position: position,
      entries: [
        SsMenuItem(
          label: 'Rename',
          icon: SsIcons.pencil,
          shortcut: 'F2',
          onSelected: () => setState(() => _renamingId = scene.id),
        ),
        SsMenuItem(
          label: 'Duplicate',
          icon: SsIcons.copy,
          onSelected: () => _ctl.execute(DuplicateScene(scene.id)),
        ),
        SsMenuItem(
          label: 'Delete',
          icon: SsIcons.trash2,
          danger: true,
          enabled: scenes.length > 1,
          onSelected: () => _delete(scene, index),
        ),
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Add pinned scene after',
          icon: SsIcons.maximize,
          onSelected: () => _add(ir.SceneKind.pinned, index: index + 1),
        ),
        SsMenuItem(
          label: 'Add flow scene after',
          icon: SsIcons.bookOpen,
          onSelected: () => _add(ir.SceneKind.flow, index: index + 1),
        ),
      ],
    );
  }

  void _showAddMenu(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox;
    showSsMenu(
      context,
      anchor: box.localToGlobal(Offset.zero) & box.size,
      placement: SsPlacement.belowEnd,
      entries: [
        SsMenuItem(
          label: 'Pinned scene',
          icon: SsIcons.maximize,
          onSelected: () => _add(ir.SceneKind.pinned),
        ),
        SsMenuItem(
          label: 'Flow scene',
          icon: SsIcons.bookOpen,
          onSelected: () => _add(ir.SceneKind.flow),
        ),
      ],
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || _renamingId != null) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.f2) {
      if (_state.activeSceneId case final id?) {
        setState(() => _renamingId = id);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (k != LogicalKeyboardKey.arrowDown && k != LogicalKeyboardKey.arrowUp) {
      return KeyEventResult.ignored;
    }
    final scenes = _state.document.scenes;
    final i = ir.DocumentIndex.of(
      _state.document,
    ).sceneIndexOf(_state.activeSceneId ?? '');
    if (i == null) return KeyEventResult.ignored;
    final next = (i + (k == LogicalKeyboardKey.arrowDown ? 1 : -1)).clamp(
      0,
      scenes.length - 1,
    );
    _ctl.setActiveScene(scenes[next].id);
    _focus.requestFocus();
    return KeyEventResult.handled;
  }

  // ---- Drag to reorder ------------------------------------------------------

  Offset? _toList(Offset global) {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.globalToLocal(global);
  }

  void _dragBegin(ir.Scene scene, DragStartDetails d) {
    _dragId = scene.id;
    _dragStart = d.globalPosition;
    _dragActive = false;
  }

  void _dragMove(DragUpdateDetails d) {
    if (_dragId == null) return;
    if (!_dragActive) {
      if ((d.globalPosition - _dragStart!).distance < 5) return;
      _dragActive = true;
      _autoScroll ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _autoScrollTick(),
      );
    }
    final local = _toList(d.globalPosition);
    if (local == null) return;
    _pointer = local;
    _replan();
  }

  void _replan() {
    final n = _state.document.scenes.length;
    final y = _pointer.dy + _scroll.offset - _pad;
    setState(() => _dropIndex = (y / _rowH).round().clamp(0, n));
  }

  void _autoScrollTick() {
    final box = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (!_dragActive || box == null || !_scroll.hasClients) return;
    const edge = 24.0;
    var dy = 0.0;
    if (_pointer.dy < edge) {
      dy = -(edge - _pointer.dy) / 2;
    } else if (_pointer.dy > box.size.height - edge) {
      dy = (_pointer.dy - (box.size.height - edge)) / 2;
    }
    final pos = _scroll.position;
    final next = (pos.pixels + dy).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (dy == 0 || next == pos.pixels) return;
    _scroll.jumpTo(next);
    _replan();
  }

  void _dragEnd(ir.Scene scene) {
    final id = _dragId, drop = _dropIndex, active = _dragActive;
    _endDrag();
    if (id == null) return;
    if (!active) {
      _ctl.setActiveScene(scene.id);
    } else if (drop != null) {
      _ctl.execute(MoveScene(id, drop));
    }
  }

  void _endDrag() {
    _autoScroll?.cancel();
    _autoScroll = null;
    if (!mounted) return;
    setState(() {
      _dragId = null;
      _dragStart = null;
      _dragActive = false;
      _dropIndex = null;
    });
  }

  // ---- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    // The scenes' ids, names and kinds only (T2.1-6): edits inside a scene
    // don't rebuild the panel.
    final scenes = ref
        .watch(
          editorControllerProvider.select((s) => _SceneList(s.document.scenes)),
        )
        .scenes;
    final activeId = ref.watch(
      editorControllerProvider.select((s) => s.activeSceneId),
    );
    return LayoutBuilder(
      builder: (context, box) {
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Column(
            children: [
              SizedBox(
                height: 36,
                child: Padding(
                  padding: const EdgeInsets.only(
                    left: SsSpace.s3,
                    right: SsSpace.s1,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          scenes.length == 1
                              ? '1 scene'
                              : '${scenes.length} scenes',
                          style: t.text.caption,
                        ),
                      ),
                      Builder(
                        builder: (buttonContext) => SsIconButton(
                          icon: SsIcons.plus,
                          semanticLabel: 'Add scene',
                          size: 24,
                          iconSize: 14,
                          onPressed: () => _showAddMenu(buttonContext),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: scenes.isEmpty
                    ? _EmptyScenes(onAdd: () => _add(ir.SceneKind.pinned))
                    : Stack(
                        children: [
                          Positioned.fill(
                            key: _listKey,
                            child: ListView.builder(
                              controller: _scroll,
                              itemCount: scenes.length,
                              itemExtent: _rowH,
                              padding: const EdgeInsets.symmetric(
                                horizontal: SsSpace.s2,
                                vertical: _pad,
                              ),
                              itemBuilder: (context, i) =>
                                  _row(scenes[i], i, scenes[i].id == activeId),
                            ),
                          ),
                          if (_dragActive && _dropIndex != null)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: AnimatedBuilder(
                                  animation: _scroll,
                                  builder: (context, _) => CustomPaint(
                                    painter: _LinePainter(
                                      index: _dropIndex!,
                                      scroll: _scroll.hasClients
                                          ? _scroll.offset
                                          : 0,
                                      color: t.colors.accent,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _row(ir.Scene scene, int index, bool active) {
    final c = context.ss.colors;
    final pinned = scene.kind == ir.SceneKind.pinned;
    return GestureDetector(
      key: ValueKey<String>('scene-${scene.id}'),
      supportedDevices: const {
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      },
      onPanStart: (d) => _dragBegin(scene, d),
      onPanUpdate: _dragMove,
      onPanEnd: (_) => _dragEnd(scene),
      onPanCancel: _endDrag,
      child: Opacity(
        opacity: _dragActive && _dragId == scene.id ? 0.5 : 1,
        child: SsTreeRow(
          label: _sceneLabel(scene, index),
          icon: pinned ? SsIcons.maximize : SsIcons.bookOpen,
          selected: active,
          startRenaming: _renamingId == scene.id,
          onRenameEnd: () {
            if (_renamingId != null) setState(() => _renamingId = null);
            _focus.requestFocus();
          },
          onTap: () {
            _ctl.setActiveScene(scene.id);
            _focus.requestFocus();
          },
          onRename: (name) =>
              _ctl.execute(UpdateSceneSettings(scene.id, name: name)),
          onSecondaryTapDown: (d) => _openMenu(scene, index, d.globalPosition),
          trailing: Text(
            pinned ? 'Pinned' : 'Flow',
            style: context.ss.text.caption.copyWith(color: c.textDisabled),
          ),
        ),
      ),
    );
  }
}

class _EmptyScenes extends StatelessWidget {
  const _EmptyScenes({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsIcon(
              SsIcons.clapperboard,
              size: 24,
              color: t.colors.textDisabled,
            ),
            const SizedBox(height: SsSpace.s3),
            Text('No scenes yet', style: t.text.bodyStrong),
            const SizedBox(height: SsSpace.s3),
            SsButton(label: 'Add a scene', onPressed: onAdd),
          ],
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  const _LinePainter({
    required this.index,
    required this.scroll,
    required this.color,
  });

  final int index;
  final double scroll;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final y = _pad + index * _rowH - scroll;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas.drawLine(
      Offset(SsSpace.s2, y),
      Offset(size.width - SsSpace.s2, y),
      paint,
    );
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.index != index || old.scroll != scroll || old.color != color;
}

/// The scene list as the panel shows it: equal while every scene keeps its
/// id, name and kind (and order).
class _SceneList {
  _SceneList(this.scenes);

  final List<ir.Scene> scenes;

  @override
  bool operator ==(Object other) {
    if (other is! _SceneList || other.scenes.length != scenes.length) {
      return false;
    }
    for (var i = 0; i < scenes.length; i++) {
      final a = scenes[i], b = other.scenes[i];
      if (a.id != b.id || a.name != b.name || a.kind != b.kind) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll([for (final s in scenes) s.id]);
}
