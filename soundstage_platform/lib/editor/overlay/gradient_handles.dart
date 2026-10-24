import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/src/paint/gradient.dart'
    show gradientBasis;

import '../inspector/sections/paint_gradient_editor.dart'
    show gradientColorAt, sortStops;

// On-canvas gradient handles (T1.7b), as pure geometry.
//
// Handles are stored normalised to the node box (architecture §5): `start`
// is the origin, `end - start` the gradient axis, `width - start` the second
// axis of radial / angular / diamond gradients (unset = `(0, 0)`, which the
// runtime reads as the axis turned 90° clockwise in pixels, a circle).
// Everything here works in node-local *pixels* (the box `Offset.zero &
// size`) and converts at the edges, so drags behave the same on any box
// shape and the written values are exactly what the runtime paints
// (`gradientBasis`).

/// Which gradient handle a drag holds.
enum GradientHandleKind { start, end, width }

/// The angle step of Shift-snapped gradient axes, in degrees.
const double kGradientSnapDegrees = 15;

/// Whether [kind] has a width handle (every kind but linear).
bool hasWidthHandle(ir.GradientKind kind) => kind != ir.GradientKind.linear;

double _r6(double v) => (v * 1e6).roundToDouble() / 1e6;

/// The handles of a gradient on a node box, in node-local pixels.
@immutable
class GradientHandlePoints {
  const GradientHandlePoints(this.start, this.end, this.width);

  /// The handles of [h] on a box of [size]: `width` is where the runtime's
  /// second axis ends (the derived perpendicular when unset).
  factory GradientHandlePoints.of(ir.GradientHandles h, Size size) {
    final b = gradientBasis(h, size);
    return GradientHandlePoints(b.origin, b.origin + b.u, b.origin + b.v);
  }

  final Offset start, end, width;

  /// The point of colour stop [position] on the start → end line.
  Offset stopPoint(double position) => Offset.lerp(start, end, position)!;

  /// The stop position (0–1) of the point on the start → end line nearest
  /// [p].
  double positionAt(Offset p) {
    final u = end - start;
    final len2 = u.dx * u.dx + u.dy * u.dy;
    if (len2 == 0) return 0;
    final d = p - start;
    return ((d.dx * u.dx + d.dy * u.dy) / len2).clamp(0.0, 1.0);
  }

  /// The distance from [p] to the start → end segment.
  double distanceToLine(Offset p) => (p - stopPoint(positionAt(p))).distance;
}

/// [p] in node pixels as a normalised point on a box of [size].
ir.StagePoint normalizedPoint(Offset p, Size size) => ir.StagePoint(
  x: _r6(size.width == 0 ? 0 : p.dx / size.width),
  y: _r6(size.height == 0 ? 0 : p.dy / size.height),
);

/// [to] turned about [from] so the direction from → to is a multiple of
/// [stepDegrees] (keeping the distance).
Offset snapAngle(
  Offset from,
  Offset to, {
  double stepDegrees = kGradientSnapDegrees,
}) {
  final d = to - from;
  final len = d.distance;
  if (len == 0) return to;
  final step = stepDegrees * math.pi / 180;
  final a = (math.atan2(d.dy, d.dx) / step).roundToDouble() * step;
  // Exact axes at 0/90/180/270 (no float drift from cos/sin).
  double clean(double v) => v.abs() < 1e-9 ? 0 : v;
  return from + Offset(clean(math.cos(a)) * len, clean(math.sin(a)) * len);
}

/// The handles after dragging [handle] to [p] (node pixels) on a box of
/// [size] — the values a drag writes:
///
/// - **start**: a linear gradient moves its start only; the others move as
///   a whole (start, end and an explicit width together), like Figma's
///   centre handle. Shift (linear) snaps the axis angle about the end.
/// - **end**: moves the end; Shift snaps the axis angle to 15° about the
///   start. An explicit width handle turns with the axis, keeping its
///   pixel length and side, so the shape rotates instead of shearing.
/// - **width** (radial, angular, diamond): sets the second axis
///   perpendicular to the first, as long as the pointer's distance from the
///   axis line (at least 1 px), on the pointer's side.
ir.GradientHandles dragGradientHandle(
  ir.GradientHandles handles,
  ir.GradientKind kind,
  Size size,
  GradientHandleKind handle,
  Offset p, {
  bool snap = false,
}) {
  final pts = GradientHandlePoints.of(handles, size);
  final widthSet = handles.width.x != 0 || handles.width.y != 0;
  ir.StagePoint n(Offset o) => normalizedPoint(o, size);
  switch (handle) {
    case GradientHandleKind.start:
      if (kind == ir.GradientKind.linear) {
        final s = snap ? snapAngle(pts.end, p) : p;
        return handles.copyWith(start: n(s));
      }
      final d = p - pts.start;
      return handles.copyWith(
        start: n(pts.start + d),
        end: n(pts.end + d),
        width: widthSet ? n(pts.width + d) : handles.width,
      );
    case GradientHandleKind.end:
      final e = snap ? snapAngle(pts.start, p) : p;
      if (!widthSet || !hasWidthHandle(kind)) {
        return handles.copyWith(end: n(e));
      }
      final uOld = pts.end - pts.start;
      final vOld = pts.width - pts.start;
      final uNew = e - pts.start;
      final side = (uOld.dx * vOld.dy - uOld.dy * vOld.dx) < 0 ? -1.0 : 1.0;
      final len = uNew.distance;
      if (len == 0) return handles.copyWith(end: n(e));
      final perp = Offset(-uNew.dy, uNew.dx) / len * vOld.distance * side;
      return handles.copyWith(end: n(e), width: n(pts.start + perp));
    case GradientHandleKind.width:
      final u = pts.end - pts.start;
      final len = u.distance;
      if (len == 0) return handles.copyWith(width: n(p));
      final perp = Offset(-u.dy, u.dx) / len;
      final rel = p - pts.start;
      var d = rel.dx * perp.dx + rel.dy * perp.dy;
      if (d.abs() < 1) d = d < 0 ? -1 : 1;
      return handles.copyWith(width: n(pts.start + perp * d));
  }
}

/// [stops] with stop [index] moved to [position], kept between its
/// neighbours (so the index-based stop paths stay sorted), rounded to 1e-4.
double clampStopPosition(List<ir.ColorStop> stops, int index, double position) {
  final lo = index > 0 ? stops[index - 1].position : 0.0;
  final hi = index < stops.length - 1 ? stops[index + 1].position : 1.0;
  return (position.clamp(lo, hi) * 1e4).roundToDouble() / 1e4;
}

/// The gradient paint at [path] (`fills.<id>`) of [node], or null when it
/// is not a gradient there.
ir.GradientPaint? gradientPaintOf(ir.Node node, String path) {
  final v = ir.PropertyRegistry.standard.get(node, path);
  return v is ir.PaintValue && v.value is ir.GradientPaint
      ? v.value as ir.GradientPaint
      : null;
}

/// The handle fields a drag of [handle] changes (and so writes; writing an
/// unchanged handle would add needless breakpoint patch keys):
/// start → start (linear) or all set handles (moving the whole gradient);
/// end → end, plus an explicit width (which turns with the axis); width →
/// width.
Set<GradientHandleKind> gradientDragFields(
  ir.GradientHandles handles,
  ir.GradientKind kind,
  GradientHandleKind handle,
) {
  final widthSet = handles.width.x != 0 || handles.width.y != 0;
  final linear = !hasWidthHandle(kind);
  return switch (handle) {
    GradientHandleKind.start =>
      linear
          ? {GradientHandleKind.start}
          : {
              GradientHandleKind.start,
              GradientHandleKind.end,
              if (widthSet) GradientHandleKind.width,
            },
    GradientHandleKind.end => {
      GradientHandleKind.end,
      if (!linear && widthSet) GradientHandleKind.width,
    },
    GradientHandleKind.width => {GradientHandleKind.width},
  };
}

/// [paint] with a new colour stop at [position] (0–1), coloured as the
/// gradient is there, stops kept sorted (Alt-click on the line).
ir.GradientPaint gradientWithStopAt(ir.GradientPaint paint, double position) {
  final pos = (position.clamp(0.0, 1.0) * 1e4).roundToDouble() / 1e4;
  return paint.copyWith(
    stops: sortStops([
      ...paint.stops,
      ir.ColorStop(position: pos, color: gradientColorAt(paint.stops, pos)),
    ]),
  );
}
