import 'dart:math' as math;
import 'dart:ui' show Offset, Path, Radius, Rect;

import 'package:soundstage_platform/ir/ir.dart' as ir;

/// Figma corner smoothing ("squircles").
///
/// This is a Dart reimplementation of the construction published in Figma's
/// article "Desperately seeking squircles"
/// (https://www.figma.com/blog/desperately-seeking-squircles/), as
/// reproduced by the MIT-licensed `figma-squircle` package
/// (https://github.com/phamfoo/figma-squircle, `src/draw.ts` and
/// `src/distribute.ts`, itself derived from MartinRGB's
/// `Figma_Squircles_Approximation`). The package's default behaviour
/// (`preserveSmoothing: false`, which is what Figma does) is used: when a
/// corner has too little room, its smoothing is reduced rather than the
/// curve being distorted.
///
/// Each corner is a cubic Bezier, a circular arc, and a second cubic
/// Bezier. The curve starts [CornerPathParams.p] away from the corner along
/// each adjacent side, where `p = (1 + smoothing) * radius`, limited to the
/// corner's share of the side (its "rounding and smoothing budget").

/// The construction parameters of one corner (figure 11.1 in the article).
class CornerPathParams {
  const CornerPathParams({
    required this.a,
    required this.b,
    required this.c,
    required this.d,
    required this.p,
    required this.radius,
    required this.arcSectionLength,
  });

  /// A corner with no rounding.
  static const CornerPathParams square = CornerPathParams(
    a: 0,
    b: 0,
    c: 0,
    d: 0,
    p: 0,
    radius: 0,
    arcSectionLength: 0,
  );

  final double a, b, c, d;

  /// How far the curve starts from the corner along each side.
  final double p;
  final double radius;

  /// The chord of the circular arc in the middle of the corner.
  final double arcSectionLength;
}

double _rad(double degrees) => degrees * math.pi / 180;

/// The parameters for a corner of [radius] and [smoothing] (0–1) given the
/// [budget] of side length it may use.
CornerPathParams cornerPathParams({
  required double radius,
  required double smoothing,
  required double budget,
}) {
  if (radius <= 0) return CornerPathParams.square;
  var s = smoothing.clamp(0.0, 1.0);
  var p = (1 + s) * radius;
  // Figma limits the smoothing so that p fits the budget.
  s = math.min(s, budget / radius - 1);
  p = math.min(p, budget);
  s = math.max(s, 0);

  final arcMeasure = 90 * (1 - s);
  final arcSectionLength = math.sin(_rad(arcMeasure / 2)) * radius * math.sqrt2;
  final angleAlpha = (90 - arcMeasure) / 2;
  final p3ToP4 = radius * math.tan(_rad(angleAlpha / 2));
  final angleBeta = 45 * s;
  final c = p3ToP4 * math.cos(_rad(angleBeta));
  final d = c * math.tan(_rad(angleBeta));
  final b = (p - arcSectionLength - c - d) / 3;
  final a = 2 * b;
  return CornerPathParams(
    a: a,
    b: b,
    c: c,
    d: d,
    p: p,
    radius: radius,
    arcSectionLength: arcSectionLength,
  );
}

/// The corner radii after Figma's clamping, with each corner's budget.
class DistributedCorners {
  const DistributedCorners(this.radii, this.budgets);

  /// In the order top-left, top-right, bottom-right, bottom-left.
  final List<double> radii;
  final List<double> budgets;
}

/// Clamps and distributes corner radii so neighbours do not overlap: bigger
/// corners choose their share of each side first
/// (`distributeAndNormalize` in figma-squircle).
DistributedCorners distributeCorners({
  required double tl,
  required double tr,
  required double br,
  required double bl,
  required double width,
  required double height,
}) {
  // Indices: 0 tl, 1 tr, 2 br, 3 bl.
  final radii = [tl, tr, br, bl];
  final budgets = [-1.0, -1.0, -1.0, -1.0];
  // (adjacent corner, side length) for each corner.
  final adjacents = <int, List<(int, double)>>{
    0: [(1, width), (3, height)],
    1: [(0, width), (2, height)],
    2: [(3, width), (1, height)],
    3: [(2, width), (0, height)],
  };
  final order = [0, 1, 2, 3]
    ..sort((x, y) {
      final cmp = radii[y].compareTo(radii[x]);
      return cmp != 0 ? cmp : x.compareTo(y);
    });
  for (final corner in order) {
    final radius = radii[corner];
    var budget = double.infinity;
    for (final (adj, side) in adjacents[corner]!) {
      final adjRadius = radii[adj];
      double share;
      if (radius == 0 && adjRadius == 0) {
        share = 0;
      } else if (budgets[adj] >= 0) {
        share = side - budgets[adj];
      } else {
        share = (radius / (radius + adjRadius)) * side;
      }
      budget = math.min(budget, share);
    }
    budgets[corner] = budget;
    radii[corner] = math.min(radius, budget);
  }
  return DistributedCorners(radii, budgets);
}

/// The outline of [rect] with [radius] corners and Figma [smoothing] (0–1).
///
/// The path is built in the same winding as Figma's: it starts on the top
/// edge, goes clockwise, and stays inside [rect]. Radii are clamped as
/// Figma does when the box is small.
Path smoothedRectPath(Rect rect, ir.CornerRadius radius, double smoothing) {
  final (tl, tr, br, bl) = switch (radius) {
    ir.UniformCornerRadius(:final radius) => (radius, radius, radius, radius),
    ir.CornerRadii(:final tl, :final tr, :final br, :final bl) => (
      tl,
      tr,
      br,
      bl,
    ),
  };
  return smoothedRectPathRadii(rect, tl, tr, br, bl, smoothing);
}

/// [smoothedRectPath] with explicit per-corner radii.
Path smoothedRectPathRadii(
  Rect rect,
  double tl,
  double tr,
  double br,
  double bl,
  double smoothing,
) {
  final w = rect.width, h = rect.height;
  final s = smoothing.clamp(0.0, 1.0);
  final d = distributeCorners(
    tl: math.max(0, tl),
    tr: math.max(0, tr),
    br: math.max(0, br),
    bl: math.max(0, bl),
    width: w,
    height: h,
  );
  CornerPathParams params(int i) =>
      cornerPathParams(radius: d.radii[i], smoothing: s, budget: d.budgets[i]);
  final ptl = params(0), ptr = params(1), pbr = params(2), pbl = params(3);

  final path = Path()..moveTo(rect.left + w - ptr.p, rect.top);
  _corner(path, ptr, _Corner.topRight);
  path.lineTo(rect.right, rect.bottom - pbr.p);
  _corner(path, pbr, _Corner.bottomRight);
  path.lineTo(rect.left + pbl.p, rect.bottom);
  _corner(path, pbl, _Corner.bottomLeft);
  path.lineTo(rect.left, rect.top + ptl.p);
  _corner(path, ptl, _Corner.topLeft);
  return path..close();
}

enum _Corner { topRight, bottomRight, bottomLeft, topLeft }

/// Appends one corner, using the relative commands of figma-squircle's
/// `drawTopRightPath` and friends.
void _corner(Path path, CornerPathParams q, _Corner corner) {
  if (q.radius <= 0) {
    // A square corner: the side runs straight into the next one.
    return;
  }
  final a = q.a, b = q.b, c = q.c, d = q.d, l = q.arcSectionLength;
  final ab = a + b, bc = b + c, abc = a + b + c;
  final r = Radius.circular(q.radius);
  switch (corner) {
    case _Corner.topRight:
      path
        ..relativeCubicTo(a, 0, ab, 0, abc, d)
        ..relativeArcToPoint(Offset(l, l), radius: r)
        ..relativeCubicTo(d, c, d, bc, d, abc);
    case _Corner.bottomRight:
      path
        ..relativeCubicTo(0, a, 0, ab, -d, abc)
        ..relativeArcToPoint(Offset(-l, l), radius: r)
        ..relativeCubicTo(-c, d, -bc, d, -abc, d);
    case _Corner.bottomLeft:
      path
        ..relativeCubicTo(-a, 0, -ab, 0, -abc, -d)
        ..relativeArcToPoint(Offset(-l, -l), radius: r)
        ..relativeCubicTo(-d, -c, -d, -bc, -d, -abc);
    case _Corner.topLeft:
      path
        ..relativeCubicTo(0, -a, 0, -ab, d, -abc)
        ..relativeArcToPoint(Offset(l, -l), radius: r)
        ..relativeCubicTo(c, -d, bc, -d, abc, -d);
  }
}
