import 'dart:ui' show Rect;

import 'package:soundstage_platform/ir/ir.dart' as ir;

/// One axis of a §4.3 constraint, with the horizontal and vertical enums
/// folded together: `start` = left/top, `end` = right/bottom, `stretch` =
/// leftRight/topBottom.
enum AxisConstraint { start, end, stretch, center, scale }

/// [h] as an [AxisConstraint].
AxisConstraint horizontalAxisConstraint(ir.HorizontalConstraint h) =>
    switch (h) {
      ir.HorizontalConstraint.left => AxisConstraint.start,
      ir.HorizontalConstraint.right => AxisConstraint.end,
      ir.HorizontalConstraint.leftRight => AxisConstraint.stretch,
      ir.HorizontalConstraint.center => AxisConstraint.center,
      ir.HorizontalConstraint.scale => AxisConstraint.scale,
    };

/// [v] as an [AxisConstraint].
AxisConstraint verticalAxisConstraint(ir.VerticalConstraint v) => switch (v) {
  ir.VerticalConstraint.top => AxisConstraint.start,
  ir.VerticalConstraint.bottom => AxisConstraint.end,
  ir.VerticalConstraint.topBottom => AxisConstraint.stretch,
  ir.VerticalConstraint.center => AxisConstraint.center,
  ir.VerticalConstraint.scale => AxisConstraint.scale,
};

/// Whether [c] decides the child's size on its axis (so a hugging child
/// takes the constrained size instead of its content size).
bool constraintSetsSize(AxisConstraint c) =>
    c == AxisConstraint.stretch || c == AxisConstraint.scale;

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

/// The child's box in the parent's frame box, for both axes of [constraints]
/// (architecture §4.3). See [resolveAxisConstraint] for the parameters.
Rect resolveConstraints({
  required ir.Constraints constraints,
  required Rect stored,
  required double referenceWidth,
  required double referenceHeight,
  required double parentWidth,
  required double parentHeight,
  double? minWidth,
  double? maxWidth,
  double? minHeight,
  double? maxHeight,
  double? contentWidth,
  double? contentHeight,
}) {
  final h = resolveAxisConstraint(
    constraint: horizontalAxisConstraint(constraints.horizontal),
    position: stored.left,
    size: stored.width,
    reference: referenceWidth,
    parent: parentWidth,
    min: minWidth,
    max: maxWidth,
    contentSize: contentWidth,
  );
  final v = resolveAxisConstraint(
    constraint: verticalAxisConstraint(constraints.vertical),
    position: stored.top,
    size: stored.height,
    reference: referenceHeight,
    parent: parentHeight,
    min: minHeight,
    max: maxHeight,
    contentSize: contentHeight,
  );
  return Rect.fromLTWH(h.offset, v.offset, h.size, v.size);
}

/// [v] clamped by nullable [min]/[max] and never negative. `min` wins over
/// `max` when they conflict (CSS).
double clampSize(double v, double? min, double? max) {
  var r = v;
  if (max != null && r > max) r = max;
  if (min != null && r < min) r = min;
  return r < 0 ? 0 : r;
}
