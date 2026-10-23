import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../canvas/canvas_controller.dart';

/// A canvas hit: node [nodeId] (a resolved id; instance inner nodes are
/// `<instanceId>/<innerId>`) on the artboard of [breakpointId] (the
/// artboard's primary breakpoint, also while it previews a free width).
typedef OverlayHit = ({String nodeId, String breakpointId});

/// A node's box on screen: its local box (`Offset.zero & size`) mapped by
/// [transform] (node-local → canvas viewport coordinates), which carries
/// every ancestor's offset, rotation, flip and `motion`, the artboard's
/// world position and the camera.
@immutable
class OverlayRect {
  const OverlayRect({required this.size, required this.transform});

  /// The node's laid-out size, in its own (design pixel) coordinates.
  final Size size;

  /// Node-local → screen.
  final Matrix4 transform;

  /// A node-local point on screen.
  Offset toScreen(Offset local) => MatrixUtils.transformPoint(transform, local);

  /// The box's corners on screen: top-left, top-right, bottom-right,
  /// bottom-left (a parallelogram under rotation or skew).
  List<Offset> get corners => [
    toScreen(Offset.zero),
    toScreen(Offset(size.width, 0)),
    toScreen(Offset(size.width, size.height)),
    toScreen(Offset(0, size.height)),
  ];

  /// The axis-aligned screen bounds of [corners].
  Rect get bounds => MatrixUtils.transformRect(transform, Offset.zero & size);

  /// The box outline on screen, for hairline strokes.
  Path get outline {
    final c = corners;
    return Path()
      ..moveTo(c[0].dx, c[0].dy)
      ..lineTo(c[1].dx, c[1].dy)
      ..lineTo(c[2].dx, c[2].dy)
      ..lineTo(c[3].dx, c[3].dy)
      ..close();
  }
}

/// Maps nodes to the screen and the screen to nodes, from the runtime's
/// node registries (one per artboard) and the camera (m1.md: the overlay
/// reads geometry from the node registry and never rebuilds the canvas).
///
/// Queries read the render tree as last laid out, so they are valid in
/// paint, in pointer handlers and after a frame; never during build.
class OverlayGeometry {
  OverlayGeometry(this.canvas);

  final CanvasController canvas;

  RenderStageBox? _box(String nodeId, String breakpointId) {
    final box = canvas.artboards[breakpointId]?.registry[nodeId];
    if (box == null || !box.attached || !box.hasSize) return null;
    return box;
  }

  /// Node-local → screen (the canvas viewport): the artboard canvas's
  /// paint transform includes the camera, so `getTransformTo` carries it.
  Matrix4? screenTransformFor(String nodeId, String breakpointId) {
    final canvasBox = canvas.worldBox;
    final box = _box(nodeId, breakpointId);
    if (canvasBox == null || box == null || !canvasBox.attached) return null;
    return box.getTransformTo(canvasBox);
  }

  /// Node-local → world (design pixels, artboards side by side).
  Matrix4? worldTransformFor(String nodeId, String breakpointId) {
    final m = screenTransformFor(nodeId, breakpointId);
    if (m == null) return null;
    final inv = Matrix4.tryInvert(canvas.camera.value.matrix);
    return inv == null ? null : (inv..multiply(m));
  }

  /// Node [nodeId]'s box on the artboard of [breakpointId], on screen; null
  /// when the node is not laid out there (another scene, removed by a
  /// patch, not yet laid out).
  OverlayRect? rectFor(String nodeId, String breakpointId) {
    final m = screenTransformFor(nodeId, breakpointId);
    if (m == null) return null;
    return OverlayRect(size: _box(nodeId, breakpointId)!.size, transform: m);
  }

  /// The world-space bounds of [nodeId] on the artboard of [breakpointId].
  Rect? worldRectFor(String nodeId, String breakpointId) {
    final m = worldTransformFor(nodeId, breakpointId);
    if (m == null) return null;
    return MatrixUtils.transformRect(
      m,
      Offset.zero & _box(nodeId, breakpointId)!.size,
    );
  }

  /// The artboard (breakpoint id) under [screen], or null.
  String? artboardAt(Offset screen) {
    final w = canvas.camera.value.toWorld(screen);
    for (final a in canvas.artboards.values.toList().reversed) {
      if (a.worldRect.contains(w)) return a.breakpointId;
    }
    return null;
  }

  /// Every node under [screen], topmost first (later siblings and their
  /// descendants before earlier ones, children before their parent), on the
  /// artboard under the point. This is the hit list the selection rules
  /// take (`EditorController.click`).
  ///
  /// - Hidden nodes and their subtrees are skipped.
  /// - Locked nodes and their subtrees are skipped (they can't be picked
  ///   on the canvas; the layers panel still selects them).
  /// - A frame that clips its content hides its children outside its box.
  /// - Rotation, flips and `motion` are respected (the inverse transform).
  /// - The scene root comes last when the point is on the artboard.
  List<OverlayHit> hitTest(Offset screen) {
    final canvasBox = canvas.worldBox;
    if (canvasBox == null || !canvasBox.attached) return const [];
    final w = canvas.camera.value.toWorld(screen);
    for (final a in canvas.artboards.values.toList().reversed) {
      if (!a.worldRect.contains(w)) continue;
      final rootId = a.scene?.root.id;
      final root = rootId == null ? null : _box(rootId, a.breakpointId);
      if (root == null) return const [];
      final out = <OverlayHit>[];
      _hit(root, root.getTransformTo(canvasBox), screen, a.breakpointId, out);
      return out;
    }
    return const [];
  }

  void _hit(
    RenderStageBox box,
    Matrix4 toScreen,
    Offset screen,
    String breakpointId,
    List<OverlayHit> out,
  ) {
    final c = box.common;
    if (!c.visible || c.locked || !box.hasSize) return;
    final inv = Matrix4.tryInvert(toScreen);
    if (inv == null) return;
    final local = MatrixUtils.transformPoint(inv, screen);
    final inside = (Offset.zero & box.size).contains(local);
    final node = box.node;
    if (node is ir.FrameNode && (inside || !node.clipContent)) {
      final kids = <RenderStageBox>[];
      box.visitChildren((k) {
        if (k is RenderStageBox) kids.add(k);
      });
      // Paint order (later on top), then topmost first.
      final painted = node.autoLayout?.reverseZIndex ?? false
          ? kids.reversed.toList()
          : kids;
      for (var i = painted.length - 1; i >= 0; i--) {
        final child = painted[i];
        final m = toScreen.clone();
        box.applyPaintTransform(child, m);
        _hit(child, m, screen, breakpointId, out);
      }
    }
    if (inside) out.add((nodeId: box.nodeId, breakpointId: breakpointId));
  }
}
