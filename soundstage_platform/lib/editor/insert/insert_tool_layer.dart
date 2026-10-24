import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../canvas/canvas_controller.dart';
import '../core/core.dart';
import '../interaction/canvas_interaction.dart' show kDragSlop;
import '../interaction/geometry_writes.dart' show roundGeometry;
import '../interaction/snapping.dart';
import '../overlay/interaction_model.dart';
import 'asset_service.dart';
import 'insert_actions.dart';
import 'insert_nodes.dart';
import 'insert_placement.dart';

/// The canvas's insert tools (T1.9): frame, text, rectangle, ellipse and
/// line. It takes over the canvas pointer while one of those tools is
/// active, and is inert otherwise (the move tool's `CanvasInteraction`
/// sits beside it and ignores insert tools in turn).
///
/// - **Click** places a default-size node (100 x 100; a 100 px line; text
///   that hugs what is typed) with its top-left at the pointer. Alt centres
///   it on the pointer.
/// - **Drag** draws it from the press to the pointer, snapping like a move
///   does (siblings, the parent, the artboard; Cmd/Ctrl turns snapping
///   off). Shift makes a square (a line snaps to 15 degree steps), Alt draws
///   from the centre.
/// - The node goes into the **frame under the press**: the deepest visible,
///   unlocked frame, else the scene root. In an auto-layout frame it joins
///   the flow at the index under the pointer; elsewhere it is placed by
///   constraints (left/top) with its geometry in that frame's space.
/// - Roles: text is a `paragraph`. (Image frames get role `figure` from the
///   Image tool and drops, see `InsertActions`.)
/// - One insert is one undo step. The tool then **returns to Move**
///   (Figma's default; there is no sticky tool mode).
/// - A new text node starts text editing straight away
///   (`EditorEvents.textEditRequests`, handled by T1.8).
///
/// Esc during a drag cancels it.
class InsertToolLayer extends ConsumerStatefulWidget {
  const InsertToolLayer({
    required this.controller,
    required this.pansWith,
    super.key,
  });

  final CanvasController controller;

  /// Whether a press belongs to the camera (Space, middle button).
  final bool Function(PointerDownEvent e) pansWith;

  @override
  ConsumerState<InsertToolLayer> createState() => InsertToolLayerState();
}

class _Draw {
  _Draw(this.target, this.startScreen, this.startWorld, this.placement);

  final InsertTarget target;
  final InsertPlacement placement;
  final Offset startScreen;
  final Offset startWorld;
  bool dragging = false;
  Offset endWorld = Offset.zero;
  SnapIndex? snap;
}

/// The state of [InsertToolLayer]; public for tests.
class InsertToolLayerState extends ConsumerState<InsertToolLayer> {
  _Draw? _draw;
  final ValueNotifier<List<Offset>?> _preview = ValueNotifier(null);

  EditorController get _ctl => ref.read(editorControllerProvider.notifier);
  CanvasController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _preview.dispose();
    super.dispose();
  }

  ({bool shift, bool alt, bool deep}) _mods() {
    final k = HardwareKeyboard.instance;
    return (
      shift: k.isShiftPressed,
      alt: k.isAltPressed,
      deep: k.isMetaPressed || k.isControlPressed,
    );
  }

  Offset _pointer = Offset.zero;

  bool _onKey(KeyEvent e) {
    final d = _draw;
    if (!mounted || d == null) return false;
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return true;
    }
    if (d.dragging) _update(_pointer);
    return false;
  }

  void _cancel() {
    _draw = null;
    _preview.value = null;
    _c.interaction.clearGesture();
  }

  void _onDown(PointerDownEvent e) {
    if (_draw != null) return;
    if (e.buttons & kPrimaryButton == 0 || widget.pansWith(e)) return;
    final st = ref.read(editorControllerProvider);
    if (!isInsertTool(st.tool)) return;
    final placement = InsertPlacement(_c, st.document);
    final target = placement.targetAt(e.localPosition);
    if (target == null) return;
    _pointer = e.localPosition;
    _ctl.setEditingBreakpoint(target.breakpointId);
    _draw = _Draw(
      target,
      e.localPosition,
      _c.camera.value.toWorld(e.localPosition),
      placement,
    );
  }

  void _onMove(PointerMoveEvent e) {
    _pointer = e.localPosition;
    final d = _draw;
    if (d == null) return;
    if (!d.dragging && (e.localPosition - d.startScreen).distance < kDragSlop) {
      return;
    }
    d.dragging = true;
    _update(e.localPosition);
  }

  /// The pointer in world space, snapped to siblings, the parent and the
  /// artboard (guides drawn by the overlay).
  Offset _snapped(_Draw d, Offset worldEnd) {
    final mods = _mods();
    if (mods.deep) {
      _c.interaction.update((m) {
        m
          ..guides = const []
          ..gaps = const [];
      });
      return worldEnd;
    }
    final idx = d.snap ??= d.placement.snapIndex(
      d.target.breakpointId,
      d.target.parentId,
    );
    final r = idx.snap(
      Rect.fromPoints(d.startWorld, worldEnd),
      kSnapThresholdPx / _c.camera.value.zoom,
      edges: MovingEdges(
        left: worldEnd.dx < d.startWorld.dx,
        right: worldEnd.dx >= d.startWorld.dx,
        top: worldEnd.dy < d.startWorld.dy,
        bottom: worldEnd.dy >= d.startWorld.dy,
      ),
    );
    _c.interaction.update((m) {
      m
        ..gesture = CanvasGestureKind.resize
        ..breakpointId = d.target.breakpointId
        ..guides = r.guides
        ..gaps = r.gaps;
    });
    return worldEnd + r.offset;
  }

  /// The box a drag to [screen] draws in the parent's space, and its line
  /// rotation.
  DragShape _shape(_Draw d, EditorTool tool) {
    final mods = _mods();
    final end = d.endWorld;
    return dragShape(
      tool,
      d.target.local(d.startWorld),
      d.target.local(end),
      square: mods.shift,
      fromCenter: mods.alt,
    );
  }

  void _update(Offset screen) {
    final d = _draw;
    if (d == null) return;
    d.endWorld = _snapped(d, _c.camera.value.toWorld(screen));
    final tool = ref.read(editorControllerProvider).tool;
    final s = _shape(d, tool);
    final toWorld = Matrix4.tryInvert(d.target.toParent);
    if (toWorld == null) return;
    final cam = _c.camera.value;
    final centre = s.box.center;
    final rot = s.rotation * math.pi / 180;
    Offset corner(Offset p) {
      final v = p - centre;
      final rotated = Offset(
        v.dx * math.cos(rot) - v.dy * math.sin(rot),
        v.dx * math.sin(rot) + v.dy * math.cos(rot),
      );
      return cam.toScreen(
        MatrixUtils.transformPoint(toWorld, centre + rotated),
      );
    }

    _preview.value = [
      corner(s.box.topLeft),
      corner(s.box.topRight),
      corner(s.box.bottomRight),
      corner(s.box.bottomLeft),
    ];
  }

  void _onUp(PointerUpEvent e) {
    final d = _draw;
    if (d == null) return;
    _pointer = e.localPosition;
    if (d.dragging) _update(e.localPosition);
    _cancel();
    _commit(d);
  }

  void _onCancel(PointerCancelEvent e) {
    if (_draw != null) _cancel();
  }

  void _commit(_Draw d) {
    final st = ref.read(editorControllerProvider);
    final tool = st.tool;
    final mods = _mods();
    final t = d.target;
    final a = t.local(d.startWorld);
    Rect box;
    var rotation = 0.0;
    if (d.dragging) {
      final s = _shape(d, tool);
      box = s.box;
      rotation = s.rotation;
      if (tool != EditorTool.line && (box.width < 1 || box.height < 1)) {
        box = Rect.fromLTWH(
          box.left,
          box.top,
          math.max(box.width, 1),
          math.max(box.height, 1),
        );
      }
    } else {
      final size = switch (tool) {
        EditorTool.line => const Size(kDefaultLineLength, 0),
        EditorTool.text => Size.zero,
        _ => kDefaultInsertSize,
      };
      box = mods.alt
          ? Rect.fromCenter(center: a, width: size.width, height: size.height)
          : Rect.fromLTWH(a.dx, a.dy, size.width, size.height);
    }
    double r(double v) => roundGeometry(v.roundToDouble());
    box = Rect.fromLTWH(r(box.left), r(box.top), r(box.width), r(box.height));
    final id = ir.IdGenerator.forDocument(st.document).next();
    var node = buildInsertNode(
      tool,
      id,
      box,
      inFlow: t.inFlow,
      drawn: d.dragging,
    );
    if (node == null) return;
    if (rotation != 0) {
      node = node.copyWith(
        common: node.common.copyWith(rotation: roundGeometry(rotation)),
      );
    }
    final result = _ctl.execute(
      InsertNodes(t.parentId, [node], index: t.flowIndex),
    );
    if (!result.ok) return;
    _ctl.setTool(EditorTool.move);
    if (tool == EditorTool.text) {
      _ctl.applySelection(
        SelectionState(selection: {id}, context: t.parentId, textEditId: id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tool = ref.watch(editorControllerProvider.select((s) => s.tool));
    // The Image tool opens the file picker as soon as it is chosen (the
    // button press or key press is the user gesture the browser wants).
    ref.listen(editorControllerProvider.select((s) => s.tool), (prev, next) {
      if (next == EditorTool.image && prev != next) {
        unawaited(
          ref
              .read(insertActionsProvider)
              .pickAndInsertImages(ref.read(editorFilePickerProvider)),
        );
      }
    });
    if (!isInsertTool(tool)) return const SizedBox.shrink();
    final accent = context.ss.colors.accent;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onCancel,
      child: MouseRegion(
        cursor: SystemMouseCursors.precise,
        opaque: false,
        child: IgnorePointer(
          child: ValueListenableBuilder<List<Offset>?>(
            valueListenable: _preview,
            builder: (_, corners, _) => CustomPaint(
              size: Size.infinite,
              painter: _PreviewPainter(corners, accent),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.corners, this.color);

  final List<Offset>? corners;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = corners;
    if (c == null) return;
    final path = Path()..addPolygon(c, true);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.08),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.corners != corners || old.color != color;
}
