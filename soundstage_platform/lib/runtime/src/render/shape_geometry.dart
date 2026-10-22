import 'dart:math' as math;
import 'dart:ui';

import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../paint/appearance_painter.dart';

/// The outline of a shape of [size] (architecture §4.1).
///
/// - `rectangle`: the box with [cornerRadius].
/// - `ellipse`: the inscribed oval. Arcs run clockwise from `arcStart` to
///   `arcEnd` (degrees, 0 = 3 o'clock); a partial arc is a pie slice, and
///   `innerRadius` (0–1 of the outer radius) cuts a ring or ring segment.
/// - `line`: a horizontal open path through the box's vertical centre (a
///   zero-height box draws on its top edge). Lines only take strokes.
/// - `polygon` / `star`: regular, first point at the top, scaled to fill
///   the box (as in Figma). A star alternates outer points with inner ones
///   at `innerRatio` of the radius.
StageOutline shapeOutline(
  ir.ShapeGeometry geometry,
  Size size, {
  ir.CornerRadius cornerRadius = const ir.CornerRadius.uniform(),
  double cornerSmoothing = 0,
}) {
  final bounds = Offset.zero & size;
  return switch (geometry) {
    ir.RectangleGeometry() => StageOutline.box(
      size,
      cornerRadius,
      smoothing: cornerSmoothing,
    ),
    ir.EllipseGeometry() => StageOutline.path(
      ellipsePath(geometry, bounds),
      bounds: bounds,
    ),
    ir.LineGeometry() => StageOutline.path(
      Path()
        ..moveTo(0, size.height / 2)
        ..lineTo(size.width, size.height / 2),
      bounds: bounds,
      closed: false,
    ),
    ir.PolygonGeometry(:final pointCount) => StageOutline.path(
      _fitted(_regularPoints(math.max(3, pointCount), 1), bounds),
      bounds: bounds,
    ),
    ir.StarGeometry(:final pointCount, :final innerRatio) => StageOutline.path(
      _fitted(
        _regularPoints(math.max(3, pointCount), innerRatio.clamp(0.0, 1.0)),
        bounds,
      ),
      bounds: bounds,
    ),
  };
}

/// The path of an ellipse (with arc and inner radius) inscribed in [rect].
Path ellipsePath(ir.EllipseGeometry g, Rect rect) {
  final inner = g.innerRadius.clamp(0.0, 1.0);
  final innerRect = Rect.fromCenter(
    center: rect.center,
    width: rect.width * inner,
    height: rect.height * inner,
  );
  final raw = g.arcEnd - g.arcStart;
  if (raw.abs() >= 360) {
    final p = Path()..addOval(rect);
    if (inner > 0) {
      p
        ..addOval(innerRect)
        ..fillType = PathFillType.evenOdd;
    }
    return p;
  }
  final sweepDeg = raw % 360;
  if (sweepDeg == 0) return Path();
  final start = g.arcStart * math.pi / 180;
  final sweep = sweepDeg * math.pi / 180;
  final p = Path();
  if (inner == 0) {
    p
      ..moveTo(rect.center.dx, rect.center.dy)
      ..arcTo(rect, start, sweep, false)
      ..close();
  } else {
    p
      ..arcTo(rect, start, sweep, true)
      ..arcTo(innerRect, start + sweep, -sweep, false)
      ..close();
  }
  return p;
}

/// Points of a regular polygon (innerRatio 1) or star on a unit circle,
/// first point at the top, clockwise.
List<Offset> _regularPoints(int n, double innerRatio) {
  final star = innerRatio < 1;
  final count = star ? n * 2 : n;
  return [
    for (var i = 0; i < count; i++)
      () {
        final a = -math.pi / 2 + i * 2 * math.pi / count;
        final r = star && i.isOdd ? innerRatio : 1.0;
        return Offset(math.cos(a) * r, math.sin(a) * r);
      }(),
  ];
}

/// A closed path through [points], scaled so their bounds fill [rect].
Path _fitted(List<Offset> points, Rect rect) {
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = -double.infinity;
  var maxY = -double.infinity;
  for (final p in points) {
    minX = math.min(minX, p.dx);
    minY = math.min(minY, p.dy);
    maxX = math.max(maxX, p.dx);
    maxY = math.max(maxY, p.dy);
  }
  final sx = maxX > minX ? rect.width / (maxX - minX) : 0.0;
  final sy = maxY > minY ? rect.height / (maxY - minY) : 0.0;
  final path = Path();
  for (var i = 0; i < points.length; i++) {
    final x = rect.left + (points[i].dx - minX) * sx;
    final y = rect.top + (points[i].dy - minY) * sy;
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path..close();
}
