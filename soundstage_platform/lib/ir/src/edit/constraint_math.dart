// The inverse of the §4.3 constraint math on plain doubles, for edits that
// keep a node's visual position (`moveNodes`). The IR can't import the
// runtime (or `dart:ui`), so this mirrors `inverseResolveAxisConstraint` in
// `lib/runtime/src/render/layout/constraints.dart`;
// `test/ir/constraint_math_test.dart` checks the two agree.

import '../nodes/node_common.dart';

/// One axis of a constraint: `start` = left/top, `end` = right/bottom,
/// `stretch` = leftRight/topBottom.
enum EditAxisConstraint { start, end, stretch, center, scale }

EditAxisConstraint horizontalEditConstraint(HorizontalConstraint h) =>
    switch (h) {
      HorizontalConstraint.left => EditAxisConstraint.start,
      HorizontalConstraint.right => EditAxisConstraint.end,
      HorizontalConstraint.leftRight => EditAxisConstraint.stretch,
      HorizontalConstraint.center => EditAxisConstraint.center,
      HorizontalConstraint.scale => EditAxisConstraint.scale,
    };

EditAxisConstraint verticalEditConstraint(VerticalConstraint v) => switch (v) {
  VerticalConstraint.top => EditAxisConstraint.start,
  VerticalConstraint.bottom => EditAxisConstraint.end,
  VerticalConstraint.topBottom => EditAxisConstraint.stretch,
  VerticalConstraint.center => EditAxisConstraint.center,
  VerticalConstraint.scale => EditAxisConstraint.scale,
};

/// [v] clamped by nullable [min]/[max] and never negative (`min` wins).
double clampEditSize(double v, double? min, double? max) {
  var r = v;
  if (max != null && r > max) r = max;
  if (min != null && r < min) r = min;
  return r < 0 ? 0 : r;
}

/// The stored position and size along one axis that the forward constraint
/// map resolves to the actual [offset] and [size] in a parent of actual size
/// [parent] whose reference size is [reference]. See the runtime's
/// `inverseResolveAxisConstraint` for the non-invertible cases (clamping,
/// hugging content, scale with a zero parent).
({double position, double size}) inverseAxisConstraint({
  required EditAxisConstraint constraint,
  required double offset,
  required double size,
  required double reference,
  required double parent,
  double? min,
  double? max,
  double? contentSize,
}) {
  final hugs =
      contentSize != null &&
      (constraint == EditAxisConstraint.start ||
          constraint == EditAxisConstraint.end ||
          constraint == EditAxisConstraint.center);
  final s = clampEditSize(hugs ? contentSize : size, min, max);
  switch (constraint) {
    case EditAxisConstraint.start:
      return (position: offset, size: s);
    case EditAxisConstraint.end:
      return (position: reference - parent + offset, size: s);
    case EditAxisConstraint.center:
      return (position: offset + (reference - parent) / 2, size: s);
    case EditAxisConstraint.stretch:
      return (position: offset, size: s + reference - parent);
    case EditAxisConstraint.scale:
      final double k = reference == 0 ? 1.0 : parent / reference;
      if (k == 0) return (position: offset, size: size);
      return (position: offset / k, size: s / k);
  }
}
