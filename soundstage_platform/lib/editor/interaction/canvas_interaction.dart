import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../canvas/canvas_controller.dart';
import '../overlay/canvas_overlay.dart' show OverlayPainter;
import '../overlay/gradient_handles.dart';
import '../overlay/interaction_model.dart';
import '../overlay/overlay_geometry.dart';
import '../overlay/selection_frame.dart';
import 'geometry_writes.dart';
import 'snapping.dart';
import 'transform_math.dart';

/// Pointer travel (screen px) before a press becomes a drag.
const double kDragSlop = 3;

/// Maximum gap between the clicks of a double-click.
const Duration kDoubleClickTime = Duration(milliseconds: 400);

/// Modifier keys of a canvas gesture, read live from the keyboard.
///
/// [deep] is Cmd or Ctrl: deep select on click, no snapping and no
/// reparenting while dragging (Figma). [alt]: duplicate on move, resize
/// from the centre, measure on hover.
typedef CanvasModifiers = ({bool shift, bool alt, bool deep});

CanvasModifiers _modifiers() {
  final k = HardwareKeyboard.instance;
  return (
    shift: k.isShiftPressed,
    alt: k.isAltPressed,
    deep: k.isMetaPressed || k.isControlPressed,
  );
}

bool _isModifier(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.shiftLeft ||
    k == LogicalKeyboardKey.shiftRight ||
    k == LogicalKeyboardKey.altLeft ||
    k == LogicalKeyboardKey.altRight ||
    k == LogicalKeyboardKey.metaLeft ||
    k == LogicalKeyboardKey.metaRight ||
    k == LogicalKeyboardKey.controlLeft ||
    k == LogicalKeyboardKey.controlRight;

/// The canvas's pointer tools (T1.4/T1.5): hover, click selection,
/// marquee, and the move/resize/rotate transforms with snapping, smart
/// spacing and Alt measurement. Sits above the overlay (which paints what
/// it does through [CanvasController.interaction]) and below the artboard
/// chrome.
///
/// **Selection** (Figma, via `EditorController`): click, Shift-click,
/// Cmd/Ctrl-click (deep), double-click (enter a frame; on text, request
/// text editing through `EditorController.events`), marquee from empty
/// canvas or the artboard background. Any artboard can be used: the
/// clicked artboard becomes the edited one (`setEditingBreakpoint`) and the
/// selection shows on every artboard.
///
/// **Gestures** are one undo step each (`beginGesture`/`endGesture`, every
/// step a [GestureStep] recomputed from the gesture's starting document):
///
/// - Move: constraint-placed nodes move freely, written back through the
///   inverse constraints (so a move at a free artboard width means the same
///   at the design size); in-flow children of auto layout reorder with an
///   insertion indicator (applied on drop); dragging over another frame
///   reparents (live into free frames, on drop into auto layout). Shift
///   locks the axis, Alt duplicates first, Cmd/Ctrl neither snaps nor
///   reparents.
/// - Resize from any handle or edge: Shift keeps the aspect ratio, Alt
///   resizes about the centre; rotated nodes resize in their own frame; a
///   multi-selection scales proportionally within its union.
/// - Rotate from just outside a corner; Shift snaps to 15°.
/// - The edit scope during a drag is the toolbar's: Alt is taken by the
///   gesture (DECISIONS 23/10/26 T1.4).
///
/// Esc during a drag cancels it.
class CanvasInteraction extends ConsumerStatefulWidget {
  const CanvasInteraction({
    required this.controller,
    required this.pansWith,
    super.key,
  });

  final CanvasController controller;

  /// Whether a press belongs to the camera (Space, the hand tool, the
  /// middle button); those are left to the canvas.
  final bool Function(PointerDownEvent e) pansWith;

  @override
  ConsumerState<CanvasInteraction> createState() => CanvasInteractionState();
}

/// The state of [CanvasInteraction]; public for tests.
class CanvasInteractionState extends ConsumerState<CanvasInteraction> {
  EditorController get _ctl => ref.read(editorControllerProvider.notifier);
  EditorState get _st => ref.read(editorControllerProvider);
  CanvasController get _c => widget.controller;
  OverlayGeometry get _g => _c.overlay;
  InteractionModel get _m => _c.interaction;

  MouseCursor _cursor = MouseCursor.defer;
  Offset? _hoverAt;
  _Press? _press;
  _Session? _session;
  Offset _pointer = Offset.zero;
  ({Duration time, Offset at})? _lastDown;
  bool _alt = false;
  int _serial = 0;

  /// The active gesture, for tests.
  @visibleForTesting
  Object? get debugSession => _session;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // Gradient editing ends when its node leaves the selection.
    ref.listenManual(editorControllerProvider.select((s) => s.selection), (
      _,
      next,
    ) {
      final t = _c.gradientEdit.value;
      if (t != null && !next.contains(t.nodeId)) _c.gradientEdit.value = null;
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    final s = _session;
    if (s != null) {
      _session = null;
      s.end();
    }
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    if (!mounted) return false;
    final s = _session;
    if (s != null) {
      if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
        _session = null;
        s.cancel();
        _setCursor(MouseCursor.defer);
        // Every keyboard handler sees the key, so the shortcuts' Esc
        // ("select parent") runs too; put the selection back after it.
        final keep = _ctl.selectionState;
        scheduleMicrotask(() {
          if (mounted) _ctl.applySelection(keep);
        });
        return true;
      }
      if (_isModifier(e.logicalKey)) s.update(_pointer, _modifiers());
      return false;
    }
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.escape &&
        _c.gradientEdit.value != null) {
      // Esc leaves gradient editing first (not "select parent").
      _c.gradientEdit.value = null;
      final keep = _ctl.selectionState;
      scheduleMicrotask(() {
        if (mounted) _ctl.applySelection(keep);
      });
      return true;
    }
    final alt = HardwareKeyboard.instance.isAltPressed;
    if (alt != _alt) {
      _alt = alt;
      final at = _hoverAt;
      if (at != null) _hover(at);
    }
    return false;
  }

  void _setCursor(MouseCursor c) {
    if (c != _cursor) setState(() => _cursor = c);
  }

  // ---- Hover ------------------------------------------------------------

  void _onHover(PointerHoverEvent e) {
    _hoverAt = e.localPosition;
    _pointer = e.localPosition;
    if (_session != null || _press != null) return;
    _hover(e.localPosition);
  }

  void _onExit(PointerExitEvent e) {
    _hoverAt = null;
    if (_session != null) return;
    _ctl.hover(null);
    _m
      ..setMeasures(const [], null)
      ..setRotateCursor(null);
    _setCursor(MouseCursor.defer);
  }

  /// The zone of the selection frame under [p], on any artboard.
  ({FrameZone zone, String breakpointId, SelectionFrame frame})? _zoneAt(
    Offset p,
  ) {
    final st = _st;
    if (st.selection.isEmpty ||
        st.tool != EditorTool.move ||
        st.textEditId != null) {
      return null;
    }
    for (final bp in _c.artboards.keys) {
      final f = SelectionFrame.of(_g, st.selection, bp);
      final z = f?.zoneAt(p);
      if (z != null) return (zone: z, breakpointId: bp, frame: f!);
    }
    return null;
  }

  static MouseCursor resizeCursor(double screenAngle) =>
      switch (resizeCursorAngle(screenAngle)) {
        0 => SystemMouseCursors.resizeLeftRight,
        45 => SystemMouseCursors.resizeUpLeftDownRight,
        90 => SystemMouseCursors.resizeUpDown,
        _ => SystemMouseCursors.resizeUpRightDownLeft,
      };

  void _hover(Offset p) {
    if (_st.tool != EditorTool.move) {
      _ctl.hover(null);
      return;
    }
    final z = _zoneAt(p);
    switch (z?.zone) {
      case ResizeZone(:final screenAngle):
        _m.setRotateCursor(null);
        _setCursor(resizeCursor(screenAngle));
      case RotateZone(:final screenAngle):
        _m.setRotateCursor(p, screenAngle + 135);
        _setCursor(SystemMouseCursors.none);
      case null:
        _m.setRotateCursor(null);
        _setCursor(MouseCursor.defer);
    }
    final hits = _g.hitTest(p);
    final bp = hits.isEmpty ? _g.artboardAt(p) : hits.first.breakpointId;
    final target = _targetOf(hits, _modifiers().deep);
    _ctl.hover(target);
    _measure(target, bp);
  }

  /// What a click on [hits] would select (Figma's rules), without
  /// changing anything.
  String? _targetOf(List<OverlayHit> hits, bool deep) {
    final tree = _ctl.selectionTree(
      hits.isEmpty ? null : hits.first.breakpointId,
    );
    if (tree == null) return null;
    for (final h in hits) {
      if (!tree.contains(h.nodeId) || !tree.isSelectable(h.nodeId)) continue;
      if (deep) return h.nodeId == tree.rootId ? null : h.nodeId;
      return clickTarget(tree, h.nodeId, _st.selectionContext);
    }
    return null;
  }

  /// Alt held over a node: distances from the selection to it (or to the
  /// selection's parent when hovering the selection or nothing).
  void _measure(String? hovered, String? bp) {
    final sel = _st.selection;
    if (!HardwareKeyboard.instance.isAltPressed || sel.isEmpty || bp == null) {
      _m.setMeasures(const [], null);
      return;
    }
    Rect? a;
    for (final id in sel) {
      final r = _g.worldRectFor(id, bp);
      if (r != null) a = a == null ? r : a.expandToInclude(r);
    }
    var other = hovered;
    if (other == null || sel.contains(other)) {
      other = parentIdOf(_g, sel.first, bp);
    }
    final b = other == null ? null : _g.worldRectFor(other, bp);
    if (a == null || b == null) {
      _m.setMeasures(const [], null);
      return;
    }
    _m.setMeasures(measureBetween(a, b), bp);
  }

  // ---- Press, drag, release --------------------------------------------

  void _onDown(PointerDownEvent e) {
    if (e.buttons == kSecondaryMouseButton && _session == null) {
      _contextMenu(e);
      return;
    }
    if (e.buttons & kPrimaryButton == 0 || widget.pansWith(e)) return;
    if (_st.tool != EditorTool.move || _session != null) return;
    final p = e.localPosition;
    _pointer = p;
    final mods = _modifiers();
    _m.setMeasures(const [], null);

    final last = _lastDown;
    final isDouble =
        last != null &&
        e.timeStamp - last.time <= kDoubleClickTime &&
        (p - last.at).distance <= 5;
    _lastDown = isDouble ? null : (time: e.timeStamp, at: p);
    if (isDouble) {
      _doubleClick(p);
      return;
    }

    if (_gradientPress(p, mods)) return;

    // The artboard's name label selects the scene root (Figma: clicking a
    // top-level frame's title), the one way to reach the root's fills, clip
    // and auto layout on the canvas.
    if (_g.artboardLabelAt(p) case final labelBp?) {
      final rootId = _c.artboards[labelBp]?.scene?.root.id;
      if (rootId != null) {
        _ctl.setEditingBreakpoint(labelBp);
        _ctl.select({rootId});
        return;
      }
    }

    final z = _zoneAt(p);
    if (z != null) {
      _ctl.setEditingBreakpoint(z.breakpointId);
      _press = _Press(p, z.breakpointId, mods, zone: z.zone, frame: z.frame);
      return;
    }
    final hits = _g.hitTest(p);
    final bp = hits.isEmpty ? _g.artboardAt(p) : hits.first.breakpointId;
    if (bp != null) _ctl.setEditingBreakpoint(bp);
    final ids = [for (final h in hits) h.nodeId];
    final target = _targetOf(hits, mods.deep);
    final sel = _st.selection;
    if (target != null && sel.contains(target)) {
      // Drag the selection; a click without drag narrows to the target
      // (with Shift: removes it).
      _press = _Press(p, bp, mods, hits: ids, clickOnUp: true, move: true);
      return;
    }
    if (target == null && sel.isNotEmpty && bp != null && !mods.shift) {
      final f = SelectionFrame.of(_g, sel, bp);
      if (f != null && f.containsPoint(p)) {
        _press = _Press(p, bp, mods, hits: ids, clickOnUp: true, move: true);
        return;
      }
    }
    if (target == null) {
      _press = _Press(p, bp, mods, hits: ids, clickOnUp: true, marquee: true);
      return;
    }
    _ctl.click(ids, (shift: mods.shift, deep: mods.deep, alt: mods.alt).sel);
    _press = _Press(
      p,
      bp,
      mods,
      hits: ids,
      move: _st.selection.contains(target),
    );
  }

  /// Right-click: selects the node under the pointer (keeping a selection
  /// that contains it) on that artboard, then offers "Reset overrides on
  /// (breakpoint)" for the breakpoint in effect there (T1.10).
  void _contextMenu(PointerDownEvent e) {
    if (_st.tool != EditorTool.move) return;
    final p = e.localPosition;
    final hits = _g.hitTest(p);
    final bp = hits.isEmpty ? _g.artboardAt(p) : hits.first.breakpointId;
    if (bp == null) return;
    _ctl.setEditingBreakpoint(bp);
    final target = _targetOf(hits, _modifiers().deep);
    if (target != null && !_st.selection.contains(target)) {
      _ctl.click([
        for (final h in hits) h.nodeId,
      ], (shift: false, deep: _modifiers().deep, alt: false).sel);
    }
    final st = _st;
    if (st.selection.isEmpty) return;
    final effective = st.breakpointId;
    final name = breakpointName(st.document, effective);
    final ids = st.selection.toList();
    showSsContextMenu(
      context,
      position: e.position,
      entries: [
        SsMenuItem(
          label: 'Reset overrides on $name',
          icon: SsIcons.rotateCcw,
          enabled: hasOverridesOn(st.document, ids, effective),
          onSelected: () => _ctl.execute(ResetBreakpointOverrides(ids)),
        ),
      ],
    );
  }

  void _doubleClick(Offset p) {
    final hits = _g.hitTest(p);
    if (hits.isEmpty) return;
    _ctl
      ..setEditingBreakpoint(hits.first.breakpointId)
      ..doubleClick([for (final h in hits) h.nodeId]);
  }

  void _onMove(PointerMoveEvent e) {
    _pointer = e.localPosition;
    final s = _session;
    if (s != null) {
      s.update(e.localPosition, _modifiers());
      return;
    }
    final press = _press;
    if (press == null) return;
    if ((e.localPosition - press.at).distance < kDragSlop) return;
    _press = null;
    _lastDown = null; // a drag is not the first click of a double-click
    _ctl.hover(null);
    final session = _start(press);
    if (session == null) return;
    _session = session;
    session.update(e.localPosition, _modifiers());
  }

  void _onUp(PointerUpEvent e) {
    final s = _session;
    if (s != null) {
      _session = null;
      s.end();
      _hover(e.localPosition);
      return;
    }
    final press = _press;
    _press = null;
    if (press != null && press.clickOnUp) {
      final m = press.mods;
      _ctl.click(press.hits, (shift: m.shift, deep: m.deep, alt: m.alt).sel);
    }
  }

  void _onCancel(PointerCancelEvent e) {
    _press = null;
    final s = _session;
    if (s != null) {
      _session = null;
      s.cancel();
    }
  }

  _Session? _start(_Press press) {
    final bp = press.breakpointId;
    final key = 'gesture:${identityHashCode(this)}:${++_serial}';
    switch (press.zone) {
      case ResizeZone(:final handle):
        if (bp == null) return null;
        return _ResizeSession.begin(this, bp, press, handle, key);
      case RotateZone():
        if (bp == null) return null;
        return _RotateSession.begin(this, bp, press, key);
      case null:
        if (press.marquee) return _MarqueeSession(this, press);
        if (press.move && bp != null) {
          return _MoveSession.begin(this, bp, press, key);
        }
        return null;
    }
  }

  // ---- Gradient handles (T1.7b) ------------------------------------------

  /// What a press at [p] hits of the gradient being edited, on the artboard
  /// under it: a handle, a colour stop, or (with [onLine]) the start → end
  /// line. Null when gradient editing is off or nothing is hit.
  ({
    String breakpointId,
    OverlayRect rect,
    ir.GradientPaint paint,
    GradientHandleKind? handle,
    int? stop,
    double? linePosition,
  })?
  _gradientHit(Offset p) {
    final target = _c.gradientEdit.value;
    if (target == null || !_st.selection.contains(target.nodeId)) return null;
    final bp = _g.artboardAt(p);
    if (bp == null) return null;
    final box = _c.artboards[bp]?.registry[target.nodeId];
    final o = _g.rectFor(target.nodeId, bp);
    if (box == null || o == null) return null;
    final paint = gradientPaintOf(box.node, target.path);
    if (paint == null) return null;
    final pts = GradientHandlePoints.of(paint.handles, o.size);
    const slop = OverlayPainter.gradientHandleRadius + 3;
    final handles = [
      (GradientHandleKind.end, pts.end),
      (GradientHandleKind.start, pts.start),
      if (hasWidthHandle(paint.kind)) (GradientHandleKind.width, pts.width),
    ];
    for (final (kind, at) in handles) {
      if ((o.toScreen(at) - p).distance <= slop) {
        return (
          breakpointId: bp,
          rect: o,
          paint: paint,
          handle: kind,
          stop: null,
          linePosition: null,
        );
      }
    }
    for (var i = paint.stops.length - 1; i >= 0; i--) {
      final at = o.toScreen(pts.stopPoint(paint.stops[i].position));
      if ((at - p).distance <= 7) {
        return (
          breakpointId: bp,
          rect: o,
          paint: paint,
          handle: null,
          stop: i,
          linePosition: null,
        );
      }
    }
    final inv = Matrix4.tryInvert(o.transform);
    if (inv == null) return null;
    final local = MatrixUtils.transformPoint(inv, p);
    final t = pts.positionAt(local);
    if ((o.toScreen(pts.stopPoint(t)) - p).distance <= 4) {
      return (
        breakpointId: bp,
        rect: o,
        paint: paint,
        handle: null,
        stop: null,
        linePosition: t,
      );
    }
    return null;
  }

  /// Starts a handle or stop drag, or (Alt-click on the line) adds a stop.
  /// Returns whether the press was the gradient editor's.
  bool _gradientPress(Offset p, CanvasModifiers mods) {
    final hit = _gradientHit(p);
    if (hit == null) return false;
    final target = _c.gradientEdit.value!;
    _ctl.setEditingBreakpoint(hit.breakpointId);
    final t = hit.linePosition;
    if (t != null) {
      if (!mods.alt) return false;
      _ctl.execute(
        SetProperty(
          [target.nodeId],
          target.path,
          ir.IrValue.paint(gradientWithStopAt(hit.paint, t)),
        ),
      );
      return true;
    }
    final key = 'gradient:${identityHashCode(this)}:${++_serial}';
    _session = _GradientSession(
      this,
      hit.breakpointId,
      key,
      target,
      hit.rect,
      hit.paint,
      handle: hit.handle,
      stop: hit.stop,
      pressAt: p,
    );
    return true;
  }

  // ---- Shared helpers ---------------------------------------------------

  Offset _world(Offset screen) => _c.camera.value.toWorld(screen);

  double get _zoom => _c.camera.value.zoom;

  /// Snap threshold in world units at the current zoom.
  double get _threshold => kSnapThresholdPx / _zoom;

  /// The selected nodes that can be transformed on [bp]: laid out there,
  /// not a scene root, not locked, and not inside another selected node.
  List<String> _transformable(String bp) {
    final sel = _st.selection;
    final reg = _c.artboards[bp]?.registry;
    if (reg == null) return const [];
    final out = <String>[];
    for (final id in sel) {
      final box = reg[id];
      if (box == null || box.common.locked) continue;
      if (placementOf(_g, id, bp) == null) continue;
      var p = box.parent;
      var nested = false;
      while (p is RenderStageBox) {
        if (sel.contains(p.nodeId)) nested = true;
        p = p.parent;
      }
      if (!nested) out.add(id);
    }
    return out;
  }

  /// Candidate boxes for snapping inside [parentId] on [bp], without
  /// [exclude] (precomputed once per gesture and parent).
  SnapIndex _snapIndex(String bp, String? parentId, Set<String> exclude) {
    final siblings = <Rect>[];
    final reg = _c.artboards[bp]?.registry;
    final parent = parentId == null ? null : reg?[parentId];
    parent?.visitChildren((k) {
      if (k is! RenderStageBox || !k.common.visible) return;
      if (exclude.contains(k.nodeId)) return;
      final r = _g.worldRectFor(k.nodeId, bp);
      if (r != null) siblings.add(r);
    });
    final pr = parentId == null ? null : _g.worldRectFor(parentId, bp);
    final art = _c.artboards[bp]?.worldRect;
    return SnapIndex(siblings: siblings, parent: pr, artboard: art);
  }

  void _execute(GestureStep step) => _ctl.execute(step);

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      onPointerHover: _onHover,
      child: MouseRegion(
        cursor: _cursor,
        opaque: false,
        onExit: _onExit,
        child: const SizedBox.expand(),
      ),
    );
  }
}

extension on ({bool shift, bool deep, bool alt}) {
  SelectionModifiers get sel =>
      SelectionModifiers(shift: shift, deep: deep, alt: alt);
}

/// A primary press that has not become a drag yet.
class _Press {
  _Press(
    this.at,
    this.breakpointId,
    this.mods, {
    this.hits = const [],
    this.zone,
    this.frame,
    this.clickOnUp = false,
    this.move = false,
    this.marquee = false,
  });

  final Offset at;
  final String? breakpointId;
  final CanvasModifiers mods;
  final List<String> hits;
  final FrameZone? zone;
  final SelectionFrame? frame;
  final bool clickOnUp, move, marquee;
}

abstract class _Session {
  void update(Offset screen, CanvasModifiers mods);

  /// Commits the gesture (one undo entry).
  void end();

  /// Reverts the gesture (no undo entry).
  void cancel();
}

/// Common gesture plumbing: the starting document, one coalescing key, and
/// steps recomputed from the base.
abstract class _Transform extends _Session {
  _Transform(this.s, this.bp, this.key, {required this.label})
    : startDoc = s._st.document,
      startSelection = s._st.selection {
    base = startDoc;
    s._ctl.beginGesture();
  }

  final CanvasInteractionState s;
  final String bp;
  final String key;
  final String label;
  final ir.StageDocument startDoc;
  final Set<String> startSelection;
  late ir.StageDocument base;

  void apply(
    ir.EditResult Function(EditorState st) edit, {
    Set<String>? selection,
    ir.StageDocument? from,
  }) => s._execute(
    GestureStep(
      label: label,
      coalesceKey: key,
      base: from ?? base,
      edit: edit,
      selectionAfter: selection,
    ),
  );

  ir.EditResult writes(EditorState st, Map<String, Map<String, ir.IrValue>> w) {
    final clean = {
      for (final MapEntry(:key, :value) in w.entries)
        if (value.isNotEmpty) key: value,
    };
    if (clean.isEmpty) {
      return ir.EditResult(document: st.document, changed: false);
    }
    return commandEdit(st, SetProperty.values(clean));
  }

  static ir.EditResult unchanged(EditorState st) =>
      ir.EditResult(document: st.document, changed: false);

  @override
  void end() {
    s._ctl.endGesture();
    s._m.clearGesture();
  }

  @override
  void cancel() {
    apply(unchanged, from: startDoc, selection: startSelection);
    s._ctl.endGesture();
    s._m.clearGesture();
  }
}

// ---- Gradient handles -------------------------------------------------------

/// A drag of a gradient handle or colour stop (T1.7b): every move writes
/// the normalised handles (or the stop position) through `SetProperty`,
/// recomputed from the gesture's start (one undo step). Shift snaps the
/// axis angle to 15°.
class _GradientSession extends _Transform {
  _GradientSession(
    super.s,
    super.bp,
    super.key,
    this.target,
    this.rect,
    this.paint, {
    required Offset pressAt,
    this.handle,
    this.stop,
  }) : super(
         label: handle == null ? 'Move gradient stop' : 'Move gradient handle',
       ) {
    s._m.update((m) => m.breakpointId = bp);
    // Keep the grab point under the pointer (no jump to the handle centre).
    final h = handle;
    final inv = Matrix4.tryInvert(rect.transform);
    if (h != null && inv != null) {
      final pts = GradientHandlePoints.of(paint.handles, rect.size);
      final at = switch (h) {
        GradientHandleKind.start => pts.start,
        GradientHandleKind.end => pts.end,
        GradientHandleKind.width => pts.width,
      };
      _grab = at - MatrixUtils.transformPoint(inv, pressAt);
    }
  }

  Offset _grab = Offset.zero;
  final GradientEditTarget target;
  final OverlayRect rect;
  final ir.GradientPaint paint;
  final GradientHandleKind? handle;
  final int? stop;

  @override
  void update(Offset screen, CanvasModifiers mods) {
    final inv = Matrix4.tryInvert(rect.transform);
    if (inv == null) return;
    final local = MatrixUtils.transformPoint(inv, screen) + _grab;
    final path = target.path;
    final w = <String, ir.IrValue>{};
    final h = handle;
    if (h != null) {
      final next = dragGradientHandle(
        paint.handles,
        paint.kind,
        rect.size,
        h,
        local,
        snap: mods.shift,
      );
      for (final f in gradientDragFields(paint.handles, paint.kind, h)) {
        final v = switch (f) {
          GradientHandleKind.start => next.start,
          GradientHandleKind.end => next.end,
          GradientHandleKind.width => next.width,
        };
        w['$path.handles.${f.name}'] = ir.IrValue.point(v);
      }
    } else if (stop != null) {
      final pts = GradientHandlePoints.of(paint.handles, rect.size);
      w['$path.stops.$stop.position'] = ir.IrValue.number(
        clampStopPosition(paint.stops, stop!, pts.positionAt(local)),
      );
    }
    apply((st) => writes(st, {target.nodeId: w}));
  }
}

// ---- Move -----------------------------------------------------------------

class _MoveSession extends _Transform {
  _MoveSession._(super.s, super.bp, super.key, this.originals, this.startWorld)
    : super(label: 'Move ${layers(originals.length)}');

  static _MoveSession? begin(
    CanvasInteractionState s,
    String bp,
    _Press press,
    String key,
  ) {
    final ids = s._transformable(bp);
    if (ids.isEmpty) return null;
    final m = _MoveSession._(s, bp, key, ids, s._world(press.at));
    m._init(press.mods);
    return m;
  }

  /// The selected nodes as the gesture began.
  final List<String> originals;
  final Offset startWorld;

  /// Original id → the id that moves (a copy after Alt-duplicate).
  final Map<String, String> moving = {};
  final Map<String, Placement> placements = {};
  final Map<String, Matrix4> parentToWorld = {};
  final Map<String, Rect> rootBoxes = {};
  final Map<String, List<Offset>> quads = {};
  late Rect union;
  String? parentId; // shared parent, else null
  late bool canReparent;
  late bool allInFlow;
  Matrix4? rootToWorld;
  String? rootId;

  /// The shared parent's world bounds at the start.
  Rect? parentWorldRect;
  final Map<String?, SnapIndex> _indexes = {};
  final Map<String, Rect> _targetRootBoxes = {};

  /// The auto-layout slot a drop would land in.
  ({String parentId, int index})? slot;

  void _init(CanvasModifiers mods) {
    final g = s._g;
    final parents = <String?>{};
    for (final id in originals) {
      placements[id] = placementOf(g, id, bp)!;
      parentToWorld[id] =
          parentWorldTransformOf(g, id, bp) ?? Matrix4.identity();
      rootBoxes[id] = rootSpaceBoxOf(g, id, bp) ?? Rect.zero;
      final o = g.rectFor(id, bp);
      final cam = s._c.camera.value;
      quads[id] = o == null
          ? const []
          : [for (final c in o.corners) cam.toWorld(c)];
      parents.add(parentIdOf(g, id, bp));
      final w = g.worldRectFor(id, bp)!;
      union = moving.isEmpty ? w : union.expandToInclude(w);
      moving[id] = id;
    }
    parentId = parents.length == 1 ? parents.single : null;
    parentWorldRect = parentId == null ? null : g.worldRectFor(parentId!, bp);
    rootId = s._c.artboards[bp]?.scene?.root.id;
    rootToWorld = rootId == null ? null : g.worldTransformFor(rootId!, bp);
    canReparent =
        parentId != null &&
        rootToWorld != null &&
        originals.every((id) => !id.contains('/'));
    allInFlow = placements.values.every((p) => p.inFlow);
    if (mods.alt && originals.every((id) => !id.contains('/'))) _duplicate();
  }

  /// Alt-drag: duplicates first; the copies move and the originals stay.
  void _duplicate() {
    Map<String, String> idMap = const {};
    apply((st) {
      final r = ir.duplicateNodes(
        st.document,
        originals,
        ir.IdGenerator.forDocument(st.document),
      );
      idMap = r.idMap;
      return r;
    }, from: startDoc);
    final copies = {for (final id in originals) id: ?idMap[id]};
    if (copies.length != originals.length) return;
    moving.addAll(copies);
    base = s._st.document;
    s._ctl.select(copies.values.toSet());
  }

  Set<String> get movingIds => moving.values.toSet();

  SnapIndex _index(String? parent) => _indexes[parent] ??= s._snapIndex(
    bp,
    parent,
    {...originals, ...movingIds},
  );

  /// The frame a drop at [screen] lands in (Figma: the deepest frame under
  /// the pointer that is not being moved), the scene root when none, or
  /// the current parent with Cmd/Ctrl.
  String? _dropTarget(Offset screen, CanvasModifiers mods) {
    if (!canReparent || mods.deep) return parentId;
    // Reordering wins inside the auto-layout parent: siblings (frames too)
    // are not drop targets while the pointer stays within it (Figma).
    final pr = parentWorldRect;
    if (allInFlow && pr != null && pr.contains(s._world(screen))) {
      return parentId;
    }
    final hits = s._g.hitTest(screen);
    final index = ir.DocumentIndex.of(base);
    final movingSet = movingIds;
    for (final h in hits) {
      if (h.breakpointId != bp) return parentId;
      final id = h.nodeId;
      if (id.contains('/') || movingSet.contains(id)) continue;
      final loc = index.locate(id);
      if (loc == null || loc.ancestorIds.any(movingSet.contains)) continue;
      if (index.node(id) is ir.FrameNode) return id;
    }
    return hits.isEmpty ? parentId : rootId;
  }

  @override
  void update(Offset screen, CanvasModifiers mods) {
    var d = s._world(screen) - startWorld;
    if (mods.shift) {
      d = d.dx.abs() >= d.dy.abs() ? Offset(d.dx, 0) : Offset(0, d.dy);
    }
    final target = _dropTarget(screen, mods);
    final targetNode = target == null
        ? null
        : ir.DocumentIndex.of(base).node(target);
    final targetAutoLayout =
        targetNode is ir.FrameNode &&
        targetNode.grid == null &&
        targetNode.autoLayout != null;
    if (target != null &&
        targetAutoLayout &&
        (target != parentId || allInFlow)) {
      _toSlot(target, targetNode, s._world(screen), d);
      return;
    }
    slot = null;
    _free(target ?? parentId, d, mods);
  }

  /// Free move (and live reparent into free frame [target]).
  void _free(String? target, Offset delta, CanvasModifiers mods) {
    var d = delta;
    final idx = _index(target);
    var snap = SnapResult.none;
    final zoom = s._zoom;
    if (!mods.deep) {
      snap = idx.snap(
        union.shift(d),
        s._threshold,
        pixelGrid: zoom >= kPixelGridZoom,
      );
      d += snap.offset;
    }
    if (zoom < kPixelGridZoom) {
      d = Offset(
        snap.snappedX ? d.dx : d.dx.roundToDouble(),
        snap.snappedY ? d.dy : d.dy.roundToDouble(),
      );
    }
    final reparent = target != null && target != parentId && canReparent;
    final ids = [for (final id in originals) moving[id]!];
    if (reparent) {
      final toRoot = rootToWorld!;
      final rd = vectorToLocal(toRoot, d);
      final tBox = _targetRootBoxes[target] ??=
          rootSpaceBoxOf(s._g, target, bp) ?? Rect.zero;
      final boxes = <String, ir.StageRect>{
        for (final id in originals)
          moving[id]!: _stage(rootBoxes[id]!.shift(rd)),
        target: _stage(tBox),
      };
      final count = (ir.DocumentIndex.of(base).node(target)! as ir.FrameNode)
          .children
          .length;
      apply(
        (st) => commandEdit(st, MoveNodes(ids, target, count, boxes: boxes)),
        selection: ids.toSet(),
      );
    } else {
      final w = <String, Map<String, ir.IrValue>>{};
      for (final id in originals) {
        final p = placements[id]!;
        if (p.inFlow) continue;
        final pd = vectorToLocal(parentToWorld[id]!, d);
        w[moving[id]!] = geometryWrites(
          p,
          p.box.shift(pd),
          moveX: pd.dx != 0,
          moveY: pd.dy != 0,
        );
      }
      apply((st) => writes(st, w), selection: ids.toSet());
    }
    s._m.update((m) {
      m
        ..gesture = CanvasGestureKind.move
        ..breakpointId = bp
        ..guides = snap.guides
        ..gaps = snap.gaps
        ..insertion = null
        ..ghosts = const []
        ..dropTargetId = reparent ? target : null;
    });
  }

  static ir.StageRect _stage(Rect r) =>
      ir.StageRect(x: r.left, y: r.top, width: r.width, height: r.height);

  /// Dragging into an auto-layout frame (or reordering inside one): the
  /// document stays as it was; the indicator shows the slot.
  void _toSlot(String target, ir.FrameNode frame, Offset world, Offset d) {
    final g = s._g;
    final toWorld = g.worldTransformFor(target, bp);
    final box = s._c.artboards[bp]?.registry[target];
    if (toWorld == null || box is! RenderStageFrame) return;
    final inv = Matrix4.tryInvert(toWorld);
    if (inv == null) return;
    final local = MatrixUtils.transformPoint(inv, world);
    final movingSet = {...movingIds, ...originals};
    final order = {for (final (i, c) in frame.children.indexed) c.id: i};
    final siblings = <FlowSibling>[];
    box.visitChildren((k) {
      if (k is! RenderStageBox) return;
      final c = k.common;
      if (!c.visible ||
          c.layoutChild.positioning != ir.Positioning.auto ||
          movingSet.contains(k.nodeId)) {
        return;
      }
      final i = order[k.nodeId];
      if (i == null) return;
      siblings.add((
        index: i,
        box: (k.parentData! as BoxParentData).offset & k.size,
      ));
    });
    siblings.sort((a, b) => a.index.compareTo(b.index));
    final al = frame.autoLayout!;
    final pad = al.padding;
    final sz = box.size;
    final fs = flowSlot(
      siblings: siblings,
      pointer: local,
      horizontal: al.direction == ir.LayoutDirection.horizontal,
      wrap: al.wrap,
      content: Rect.fromLTRB(
        pad.left,
        pad.top,
        sz.width - pad.right,
        sz.height - pad.bottom,
      ),
      childCount: frame.children.length,
    );
    slot = (parentId: target, index: fs.index);
    apply(_Transform.unchanged); // back to the base if a free move preceded
    s._m.update((m) {
      m
        ..gesture = CanvasGestureKind.reorder
        ..breakpointId = bp
        ..guides = const []
        ..gaps = const []
        ..insertion = (
          MatrixUtils.transformPoint(toWorld, fs.a),
          MatrixUtils.transformPoint(toWorld, fs.b),
        )
        ..ghosts = [
          for (final id in originals) [for (final c in quads[id]!) c + d],
        ]
        ..dropTargetId = target == parentId ? null : target;
    });
  }

  @override
  void end() {
    final sl = slot;
    if (sl != null) {
      final ids = [for (final id in originals) moving[id]!];
      apply(
        (st) => chainEdits(st, [
          (st) => commandEdit(
            st,
            MoveNodes(ids, sl.parentId, sl.index, preservePosition: false),
          ),
          // Dropped into a flow: absolute nodes join it.
          (st) {
            var doc = st.document;
            for (final id in ids) {
              final r = ir.updateNode(doc, id, (n) {
                final lc = n.common.layoutChild;
                if (lc.positioning == ir.Positioning.auto) return n;
                return n.copyWith(
                  common: n.common.copyWith(
                    layoutChild: lc.copyWith(positioning: ir.Positioning.auto),
                  ),
                );
              });
              if (r.ok) doc = r.document;
            }
            return ir.EditResult(
              document: doc,
              changed: !identical(doc, st.document),
            );
          },
        ]),
        selection: ids.toSet(),
      );
    }
    super.end();
  }
}

// ---- Resize ----------------------------------------------------------------

class _ResizeSession extends _Transform {
  _ResizeSession._(super.s, super.bp, super.key, this.handle, this.startWorld)
    : super(label: 'Resize');

  static _ResizeSession? begin(
    CanvasInteractionState s,
    String bp,
    _Press press,
    ResizeHandle handle,
    String key,
  ) {
    final ids = s._transformable(bp);
    if (ids.isEmpty) return null;
    final r = _ResizeSession._(s, bp, key, handle, s._world(press.at));
    r._init(ids);
    return r;
  }

  final ResizeHandle handle;
  final Offset startWorld;
  final List<String> ids = [];
  final Map<String, Placement> placements = {};
  final Map<String, Matrix4> parentToWorld = {};
  late Rect union;
  late SnapIndex index;
  late bool single;

  void _init(List<String> list) {
    final g = s._g;
    ids.addAll(list);
    single = ids.length == 1;
    final parents = <String?>{};
    for (final id in ids) {
      placements[id] = placementOf(g, id, bp)!;
      parentToWorld[id] =
          parentWorldTransformOf(g, id, bp) ?? Matrix4.identity();
      parents.add(parentIdOf(g, id, bp));
      final w = g.worldRectFor(id, bp)!;
      union = id == ids.first ? w : union.expandToInclude(w);
    }
    index = s._snapIndex(bp, parents.length == 1 ? parents.single : null, {
      ...ids,
    });
  }

  MovingEdges get _edges => MovingEdges(
    left: handle.hx == -1,
    right: handle.hx == 1,
    top: handle.hy == -1,
    bottom: handle.hy == 1,
  );

  @override
  void update(Offset screen, CanvasModifiers mods) {
    final d = s._world(screen) - startWorld;
    final zoom = s._zoom;
    var snap = SnapResult.none;
    if (single) {
      final id = ids.single;
      final p = placements[id]!;
      final m = parentToWorld[id]!;
      final lc = p.layoutChild;
      final upright = p.rotation % 360 == 0;
      ResizeResult resize(Offset pd) => resizeBox(
        box: p.box,
        handle: handle,
        delta: pd,
        rotation: p.rotation,
        keepAspect: mods.shift,
        fromCenter: mods.alt,
        minWidth: lc.minWidth,
        maxWidth: lc.maxWidth,
        minHeight: lc.minHeight,
        maxHeight: lc.maxHeight,
      );
      var pd = vectorToLocal(m, d);
      if (upright && zoom < kPixelGridZoom) {
        pd = Offset(pd.dx.roundToDouble(), pd.dy.roundToDouble());
      }
      var res = resize(pd);
      if (upright && !mods.deep) {
        snap = index.snap(
          MatrixUtils.transformRect(m, res.box),
          s._threshold,
          edges: _edges,
          pixelGrid: zoom >= kPixelGridZoom,
        );
        if (snap.offset != Offset.zero) {
          res = resize(pd + vectorToLocal(m, snap.offset));
        }
      }
      final w = geometryWrites(
        p,
        res.box,
        moveX: (res.box.left - p.box.left).abs() > 1e-9,
        moveY: (res.box.top - p.box.top).abs() > 1e-9,
        sizeX: res.widthChanged,
        sizeY: res.heightChanged,
      );
      apply((st) => writes(st, {id: w}));
    } else {
      var dd = d;
      if (zoom < kPixelGridZoom) {
        dd = Offset(dd.dx.roundToDouble(), dd.dy.roundToDouble());
      }
      ResizeResult resize(Offset delta) => resizeBox(
        box: union,
        handle: handle,
        delta: delta,
        keepAspect: mods.shift,
        fromCenter: mods.alt,
      );
      var res = resize(dd);
      if (!mods.deep) {
        snap = index.snap(
          res.box,
          s._threshold,
          edges: _edges,
          pixelGrid: zoom >= kPixelGridZoom,
        );
        if (snap.offset != Offset.zero) res = resize(dd + snap.offset);
      }
      final w = <String, Map<String, ir.IrValue>>{};
      for (final id in ids) {
        final p = placements[id]!;
        final m = parentToWorld[id]!;
        final inv = Matrix4.tryInvert(m) ?? Matrix4.identity();
        final from = MatrixUtils.transformRect(m, p.box);
        final to = mapRectProportionally(from, union, res.box);
        final box = MatrixUtils.transformRect(inv, to);
        w[id] = geometryWrites(
          p,
          box,
          moveX: true,
          moveY: true,
          sizeX: res.widthChanged,
          sizeY: res.heightChanged,
        );
      }
      apply((st) => writes(st, w));
    }
    s._m.update((m) {
      m
        ..gesture = CanvasGestureKind.resize
        ..breakpointId = bp
        ..guides = snap.guides
        ..gaps = const [];
    });
  }
}

// ---- Rotate ----------------------------------------------------------------

class _RotateSession extends _Transform {
  _RotateSession._(super.s, super.bp, super.key, this.startWorld, this.angle0)
    : super(label: 'Rotate');

  static _RotateSession? begin(
    CanvasInteractionState s,
    String bp,
    _Press press,
    String key,
  ) {
    final ids = s._transformable(bp);
    if (ids.isEmpty) return null;
    final zone = press.zone! as RotateZone;
    final r = _RotateSession._(
      s,
      bp,
      key,
      s._world(press.at),
      zone.screenAngle,
    );
    r._init(ids);
    return r;
  }

  final Offset startWorld;
  final double angle0;
  final List<String> ids = [];
  final Map<String, Placement> placements = {};
  final Map<String, Matrix4> parentToWorld = {};
  late Offset centre;

  void _init(List<String> list) {
    final g = s._g;
    ids.addAll(list);
    Rect? u;
    for (final id in ids) {
      placements[id] = placementOf(g, id, bp)!;
      parentToWorld[id] =
          parentWorldTransformOf(g, id, bp) ?? Matrix4.identity();
      final w = g.worldRectFor(id, bp)!;
      u = u == null ? w : u.expandToInclude(w);
    }
    if (ids.length == 1) {
      final p = placements[ids.single]!;
      centre = MatrixUtils.transformPoint(
        parentToWorld[ids.single]!,
        p.box.center,
      );
    } else {
      centre = u!.center;
    }
  }

  @override
  void update(Offset screen, CanvasModifiers mods) {
    final world = s._world(screen);
    final w = <String, Map<String, ir.IrValue>>{};
    double delta;
    if (ids.length == 1) {
      final id = ids.single;
      final p = placements[id]!;
      final r = dragRotation(
        centre: centre,
        start: startWorld,
        now: world,
        startRotation: p.rotation,
        snap: mods.shift,
      );
      delta = r - p.rotation;
      w[id] = {'rotation': ir.IrValue.number(roundGeometry(r))};
    } else {
      delta = dragRotation(
        centre: centre,
        start: startWorld,
        now: world,
        startRotation: 0,
        snap: mods.shift,
      );
      for (final id in ids) {
        final p = placements[id]!;
        final m = parentToWorld[id]!;
        final c = MatrixUtils.transformPoint(m, p.box.center);
        final moved = rotateAbout(c, centre, delta) - c;
        final pd = vectorToLocal(m, moved);
        w[id] = {
          ...geometryWrites(p, p.box.shift(pd), moveX: true, moveY: true),
          'rotation': ir.IrValue.number(
            roundGeometry(normalizeDegrees(p.rotation + delta)),
          ),
        };
      }
    }
    apply((st) => writes(st, w));
    s._m
      ..update((m) {
        m
          ..gesture = CanvasGestureKind.rotate
          ..breakpointId = bp;
      })
      ..setRotateCursor(screen, angle0 + 135 + delta);
  }

  @override
  void end() {
    s._m.setRotateCursor(null);
    super.end();
  }

  @override
  void cancel() {
    s._m.setRotateCursor(null);
    super.cancel();
  }
}

// ---- Marquee ---------------------------------------------------------------

class _MarqueeSession extends _Session {
  _MarqueeSession(this.s, this.press) {
    // A marquee starts like a click on empty space: the selection clears
    // (Shift keeps it).
    final m = press.mods;
    s._ctl.click(press.hits, (shift: m.shift, deep: m.deep, alt: m.alt).sel);
    base = s._ctl.selectionState;
    startWorld = s._world(press.at);
  }

  final CanvasInteractionState s;
  final _Press press;
  late final SelectionState base;
  late final Offset startWorld;
  final Map<String, Map<String, ir.StageRect>> _boxes = {};

  String? _artboardFor(Rect world) {
    final at = press.breakpointId;
    if (at != null) return at;
    String? best;
    var area = 0.0;
    for (final a in s._c.artboards.values) {
      final i = a.worldRect.intersect(world);
      if (i.width > 0 && i.height > 0 && i.width * i.height > area) {
        area = i.width * i.height;
        best = a.breakpointId;
      }
    }
    return best;
  }

  Map<String, ir.StageRect> _boxesOn(String bp, SelectionTree tree) =>
      _boxes[bp] ??= {
        for (final id in tree.childrenOf(base.context ?? tree.rootId))
          if (s._g.worldRectFor(id, bp) case final r?)
            id: ir.StageRect(
              x: r.left,
              y: r.top,
              width: r.width,
              height: r.height,
            ),
      };

  @override
  void update(Offset screen, CanvasModifiers mods) {
    final rect = Rect.fromPoints(press.at, screen);
    final world = Rect.fromPoints(startWorld, s._world(screen));
    s._m.update((m) {
      m
        ..gesture = CanvasGestureKind.marquee
        ..marquee = rect;
    });
    final bp = _artboardFor(world);
    if (bp == null) return;
    s._ctl.setEditingBreakpoint(bp);
    final tree = s._ctl.selectionTree(bp);
    if (tree == null) return;
    final next = marqueeSelect(
      tree,
      ir.StageRect(
        x: world.left,
        y: world.top,
        width: world.width,
        height: world.height,
      ),
      _boxesOn(bp, tree),
      SelectionModifiers(shift: press.mods.shift),
      base,
    );
    if (!_sameSelection(next, s._ctl.selectionState)) {
      s._ctl.applySelection(next);
    }
  }

  static bool _sameSelection(SelectionState a, SelectionState b) =>
      a.context == b.context &&
      a.selection.length == b.selection.length &&
      a.selection.containsAll(b.selection);

  @override
  void end() => s._m.clearGesture();

  @override
  void cancel() {
    s._ctl.applySelection(base);
    s._m.clearGesture();
  }
}

/// Exposed for tests: the cursor a resize zone at [screenAngle] shows.
MouseCursor resizeCursorFor(double screenAngle) =>
    CanvasInteractionState.resizeCursor(screenAngle);
