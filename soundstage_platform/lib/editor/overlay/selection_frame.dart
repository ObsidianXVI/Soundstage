import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../interaction/geometry_writes.dart';
import '../interaction/transform_math.dart';
import 'overlay_geometry.dart';

/// Handle square size on screen.
const double kHandleSize = 7;

/// Grab radius of a handle (screen px).
const double kHandleGrab = 6;

/// Grab distance of an edge (screen px).
const double kEdgeGrab = 4;

/// How far outside a corner the rotation zone reaches (screen px).
const double kRotateZone = 18;

/// Edge handles are drawn only on edges at least this long (screen px).
const double kEdgeHandleMinLength = 32;

/// What the pointer is over on a selection frame.
sealed class FrameZone {
  const FrameZone();
}

/// A resize handle (corner) or edge. [handle] is in the node's own
/// (rotated, unflipped) frame; [screenAngle] is the direction from the
/// box centre to the handle on screen, for the cursor.
class ResizeZone extends FrameZone {
  const ResizeZone(this.handle, this.screenAngle);

  final ResizeHandle handle;
  final double screenAngle;
}

/// The rotation zone just outside corner [corner] (0 = top-left,
/// clockwise).
class RotateZone extends FrameZone {
  const RotateZone(this.corner, this.screenAngle);

  final int corner;
  final double screenAngle;
}

/// The selection's transform frame on one artboard, in screen space: one
/// node's (rotated) box, or the axis-aligned union of several.
class SelectionFrame {
  SelectionFrame._(this.corners, this.single, this.flipX, this.flipY);

  /// Top-left, top-right, bottom-right, bottom-left (screen).
  final List<Offset> corners;

  /// One node (rotated frame) rather than a union.
  final bool single;
  final bool flipX, flipY;

  /// The frame of [ids] on artboard [breakpointId], or null when none is
  /// laid out there.
  static SelectionFrame? of(
    OverlayGeometry g,
    Iterable<String> ids,
    String breakpointId,
  ) {
    final list = ids.toList();
    if (list.length == 1) {
      final o = g.rectFor(list.single, breakpointId);
      if (o == null) return null;
      final n = g.canvas.artboards[breakpointId]?.registry[list.single];
      final c = n?.common;
      return SelectionFrame._(
        o.corners,
        true,
        c?.flipX ?? false,
        c?.flipY ?? false,
      );
    }
    Rect? u;
    for (final id in list) {
      final o = g.rectFor(id, breakpointId);
      if (o == null) continue;
      u = u == null ? o.bounds : u.expandToInclude(o.bounds);
    }
    if (u == null) return null;
    return SelectionFrame._(
      [u.topLeft, u.topRight, u.bottomRight, u.bottomLeft],
      false,
      false,
      false,
    );
  }

  Offset get centre => (corners[0] + corners[2]) / 2;

  /// Screen rotation of the frame's x axis (degrees).
  double get angle {
    final d = corners[1] - corners[0];
    return d.distanceSquared == 0 ? 0 : d.direction * 180 / math.pi;
  }

  /// The axis-aligned screen bounds.
  Rect get bounds {
    var r = Rect.fromPoints(corners[0], corners[2]);
    r = r.expandToInclude(Rect.fromPoints(corners[1], corners[3]));
    return r;
  }

  Offset _lerp(Offset a, Offset b, double t) => a + (b - a) * t;

  /// The screen point of local handle [h] (local frame: corners[0] is the
  /// local top-left).
  Offset pointOf(ResizeHandle h) {
    final u = (h.hx + 1) / 2, v = (h.hy + 1) / 2;
    final top = _lerp(corners[0], corners[1], u);
    final bottom = _lerp(corners[3], corners[2], u);
    return _lerp(top, bottom, v);
  }

  /// Local handle [h] as the handle of the rotated, unflipped frame
  /// `resizeBox` works in.
  ResizeHandle unflipped(ResizeHandle h) {
    final hx = flipX ? -h.hx : h.hx, hy = flipY ? -h.hy : h.hy;
    return ResizeHandle.values.firstWhere((e) => e.hx == hx && e.hy == hy);
  }

  double get width => (corners[1] - corners[0]).distance;
  double get height => (corners[3] - corners[0]).distance;

  /// Whether edge handles are drawn (and grabbable as squares).
  bool showsEdgeHandle(ResizeHandle h) =>
      (h.hx == 0 ? width : height) >= kEdgeHandleMinLength;

  bool containsPoint(Offset p) {
    final path = Path()..addPolygon(corners, true);
    return path.contains(p);
  }

  /// What [p] is over: a corner handle, an edge, or a rotation zone (in
  /// that order), or null.
  FrameZone? zoneAt(Offset p) {
    final c = centre;
    double dir(Offset at) => (at - c).direction * 180 / math.pi;
    for (final h in ResizeHandle.values.where((h) => h.isCorner)) {
      final at = pointOf(h);
      if ((p - at).distance <= kHandleGrab) {
        return ResizeZone(unflipped(h), dir(at));
      }
    }
    for (final h in ResizeHandle.values.where((h) => !h.isCorner)) {
      final at = pointOf(h);
      if (showsEdgeHandle(h) && (p - at).distance <= kHandleGrab) {
        return ResizeZone(unflipped(h), dir(at));
      }
    }
    // Edges: within kEdgeGrab of the segment, between the corner grabs.
    const edges = [
      (ResizeHandle.top, 0, 1),
      (ResizeHandle.right, 1, 2),
      (ResizeHandle.bottom, 2, 3),
      (ResizeHandle.left, 3, 0),
    ];
    for (final (h, i, j) in edges) {
      final a = corners[i], b = corners[j];
      final ab = b - a;
      final len2 = ab.distanceSquared;
      if (len2 == 0) continue;
      final t = ((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2;
      if (t <= 0 || t >= 1) continue;
      final foot = a + ab * t;
      if ((p - foot).distance <= kEdgeGrab) {
        return ResizeZone(unflipped(h), dir(pointOf(h)));
      }
    }
    if (!containsPoint(p)) {
      for (var i = 0; i < 4; i++) {
        final at = corners[i];
        if ((p - at).distance <= kRotateZone) return RotateZone(i, dir(at));
      }
    }
    return null;
  }
}

/// The node [id]'s placement on artboard [breakpointId] as laid out (see
/// [Placement]), or null when it isn't there (or is a scene root).
Placement? placementOf(OverlayGeometry g, String id, String breakpointId) {
  final box = g.canvas.artboards[breakpointId]?.registry[id];
  if (box == null || !box.attached || !box.hasSize) return null;
  final parent = box.parent;
  if (parent is! RenderStageFrame) return null;
  final offset = (box.parentData! as BoxParentData).offset;
  final frame = parent.frame;
  final node = box.baseNode;
  final inFlow =
      frame.grid == null &&
      frame.autoLayout != null &&
      node.common.layoutChild.positioning == ir.Positioning.auto;
  return Placement(
    id: id,
    node: node,
    box: offset & box.size,
    parentSize: parent.size,
    reference: parent.referenceSize,
    inFlow: inFlow,
    hugsWidth: box.hugsWidth,
    hugsHeight: box.hugsHeight,
  );
}

/// The id of [id]'s parent stage node on [breakpointId] (null for a root).
String? parentIdOf(OverlayGeometry g, String id, String breakpointId) {
  final p = g.canvas.artboards[breakpointId]?.registry[id]?.parent;
  return p is RenderStageBox ? p.nodeId : null;
}

/// [id]'s unrotated box in its scene root's space (sum of layout offsets;
/// rotated ancestors ignored, as `moveNodes` expects).
Rect? rootSpaceBoxOf(OverlayGeometry g, String id, String breakpointId) {
  final box = g.canvas.artboards[breakpointId]?.registry[id];
  if (box == null || !box.attached || !box.hasSize) return null;
  var o = Offset.zero;
  RenderObject? n = box;
  while (n is RenderStageBox && n.parent is RenderStageBox) {
    o += (n.parentData! as BoxParentData).offset;
    n = n.parent;
  }
  return o & box.size;
}

/// Parent-local → world transform of [id]'s parent on [breakpointId].
Matrix4? parentWorldTransformOf(
  OverlayGeometry g,
  String id,
  String breakpointId,
) {
  final p = parentIdOf(g, id, breakpointId);
  return p == null ? null : g.worldTransformFor(p, breakpointId);
}

/// [world] (a vector, not a point) in the space of [toWorld]'s source.
Offset vectorToLocal(Matrix4 toWorld, Offset world) {
  final inv = Matrix4.tryInvert(toWorld);
  if (inv == null) return world;
  final a = MatrixUtils.transformPoint(inv, Offset.zero);
  final b = MatrixUtils.transformPoint(inv, world);
  return b - a;
}
