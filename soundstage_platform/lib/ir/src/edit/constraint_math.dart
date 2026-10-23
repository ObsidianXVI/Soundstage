// The §4.3 constraint math on plain doubles: the one implementation, used by
// the runtime's layout (`lib/runtime/src/render/layout/constraints.dart`
// re-exports it and adds the `Rect` forms) and by edits that keep a node's
// visual position (`moveNodes`). Pure Dart: no `dart:ui`.

import '../nodes/node_common.dart';

/// One axis of a §4.3 constraint, with the horizontal and vertical enums
/// folded together: `start` = left/top, `end` = right/bottom, `stretch` =
/// leftRight/topBottom.
enum AxisConstraint { start, end, stretch, center, scale }

/// [h] as an [AxisConstraint].
AxisConstraint horizontalAxisConstraint(HorizontalConstraint h) => switch (h) {
  HorizontalConstraint.left => AxisConstraint.start,
  HorizontalConstraint.right => AxisConstraint.end,
  HorizontalConstraint.leftRight => AxisConstraint.stretch,
  HorizontalConstraint.center => AxisConstraint.center,
  HorizontalConstraint.scale => AxisConstraint.scale,
};

/// [v] as an [AxisConstraint].
AxisConstraint verticalAxisConstraint(VerticalConstraint v) => switch (v) {
  VerticalConstraint.top => AxisConstraint.start,
  VerticalConstraint.bottom => AxisConstraint.end,
  VerticalConstraint.topBottom => AxisConstraint.stretch,
  VerticalConstraint.center => AxisConstraint.center,
  VerticalConstraint.scale => AxisConstraint.scale,
};

/// Whether [c] decides the child's size on its axis (so a hugging child
/// takes the constrained size instead of its content size).
bool constraintSetsSize(AxisConstraint c) =>
    c == AxisConstraint.stretch || c == AxisConstraint.scale;

/// [v] clamped by nullable [min]/[max] and never negative. `min` wins over
/// `max` when they conflict (CSS).
double clampSize(double v, double? min, double? max) {
  var r = v;
  if (max != null && r > max) r = max;
  if (min != null && r < min) r = min;
  return r < 0 ? 0 : r;
}

/// The result of [resolveAxisConstraint]: the child's offset and size along
/// one axis, in the parent's frame box.
typedef AxisPlacement = ({double offset, double size});

/// Places a child along one axis (architecture §4.3).
///
/// [position] and [size] are the child's stored geometry, designed against
/// the parent's reference size [reference]. [parent] is the parent's actual
/// size. The result is then clamped by [min]/[max], and the offset is
/// recomputed from the constraint's anchor so the anchored edge (or the
/// centre) stays put.
///
/// [contentSize] is the measured size of a child that hugs this axis (a
/// hug-sized frame or auto-width text). For `start`/`end`/`center` it
/// replaces the stored size while the margins still come from the stored
/// geometry, so right-anchored text grows leftwards and centred text stays
/// centred. `stretch`/`scale` ignore it: the constraint decides the size.
AxisPlacement resolveAxisConstraint({
  required AxisConstraint constraint,
  required double position,
  required double size,
  required double reference,
  required double parent,
  double? min,
  double? max,
  double? contentSize,
}) {
  final endMargin = reference - position - size;
  final double k = reference == 0 ? 1.0 : parent / reference;
  final double raw = switch (constraint) {
    AxisConstraint.start ||
    AxisConstraint.end ||
    AxisConstraint.center => contentSize ?? size,
    AxisConstraint.stretch => parent - position - endMargin,
    AxisConstraint.scale => size * k,
  };
  final s = clampSize(raw, min, max);
  final double offset = switch (constraint) {
    AxisConstraint.start || AxisConstraint.stretch => position,
    AxisConstraint.end => parent - endMargin - s,
    AxisConstraint.center =>
      parent / 2 + (position + size / 2 - reference / 2) - s / 2,
    AxisConstraint.scale => position * k,
  };
  return (offset: offset, size: s);
}

/// The result of [inverseResolveAxisConstraint]: stored geometry along one
/// axis, and whether it reproduces the desired placement exactly.
typedef InverseAxisPlacement = ({double position, double size, bool exact});

/// The inverse of [resolveAxisConstraint] (architecture §4.3): the stored
/// position/size that resolve to the desired actual [offset] and [size]
/// when the parent is [parent] and the reference size is [reference].
///
/// Used by the editor to turn an edit made at a free artboard width back
/// into stored geometry that means the same thing at the design size, and
/// by `moveNodes` to keep a reparented node's visual position.
/// `resolveAxisConstraint(inverse…)` gives back `(offset, size)` up to
/// floating-point rounding, except where the forward map is not
/// invertible; then `exact` is false and the result is the closest
/// achievable placement:
///
/// - **Clamping.** The forward size is `clampSize(raw, min, max)`, so a
///   desired [size] outside `[min, max]` (or negative) cannot be reached.
///   The inverse targets the clamped size at the requested [offset].
///   A size *on* a clamp bound is reachable (the raw size is chosen equal
///   to it), so `exact` stays true.
/// - **Hugging.** With [contentSize] (a hug-sized frame, auto-width text),
///   `start`/`end`/`center` take their size from the content, not the
///   stored size. Only `clampSize(contentSize)` is reachable; the stored
///   size is set to it so the stored box matches the content.
/// - **Scale with a zero parent.** When `parent == 0` (and `reference !=
///   0`) every stored geometry resolves to offset 0 and size
///   `clampSize(0)`; the stored geometry is then the desired one unchanged.
///
/// Stretch can return a negative stored size: a desired size below
/// `parent − reference` needs margins wider than the reference. The round
/// trip still holds; the caller decides whether to accept it.
InverseAxisPlacement inverseResolveAxisConstraint({
  required AxisConstraint constraint,
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
      (constraint == AxisConstraint.start ||
          constraint == AxisConstraint.end ||
          constraint == AxisConstraint.center);
  // The size the forward map will produce.
  final s = clampSize(hugs ? contentSize : size, min, max);
  var exact = s == size;
  switch (constraint) {
    case AxisConstraint.start:
      return (position: offset, size: s, exact: exact);
    case AxisConstraint.end:
      // Keep the right margin: P − o − s = R − x − w with w = s.
      return (position: reference - parent + offset, size: s, exact: exact);
    case AxisConstraint.center:
      // Keep the centre offset: o + s/2 − P/2 = x + w/2 − R/2 with w = s.
      return (
        position: offset + (reference - parent) / 2,
        size: s,
        exact: exact,
      );
    case AxisConstraint.stretch:
      // Raw size P − R + w must equal s.
      return (position: offset, size: s + reference - parent, exact: exact);
    case AxisConstraint.scale:
      final double k = reference == 0 ? 1.0 : parent / reference;
      if (k == 0) {
        exact = offset == 0 && clampSize(0, min, max) == size;
        return (position: offset, size: size, exact: exact);
      }
      return (position: offset / k, size: s / k, exact: exact);
  }
}
