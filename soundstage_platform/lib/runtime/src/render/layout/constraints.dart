// The §4.3 constraint math lives in the IR (`lib/ir/src/edit/constraint_math.dart`),
// the single implementation shared with the editor's edit helpers. This file
// re-exports it for the runtime and adds the two-axis `Rect` forms.

import 'dart:ui' show Rect;

import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/ir/src/edit/constraint_math.dart';

export 'package:soundstage_platform/ir/src/edit/constraint_math.dart';

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

/// The result of [inverseResolveConstraints]: the stored box (relative to
/// the parent, at its reference size), and whether both axes are exact.
typedef InverseConstraintsResult = ({Rect stored, bool exact});

/// The inverse of [resolveConstraints]: the stored box that resolves to
/// [desired] (the actual box in the parent's frame box) for both axes. See
/// [inverseResolveAxisConstraint] for the parameters and the cases that are
/// not invertible.
InverseConstraintsResult inverseResolveConstraints({
  required ir.Constraints constraints,
  required Rect desired,
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
  final h = inverseResolveAxisConstraint(
    constraint: horizontalAxisConstraint(constraints.horizontal),
    offset: desired.left,
    size: desired.width,
    reference: referenceWidth,
    parent: parentWidth,
    min: minWidth,
    max: maxWidth,
    contentSize: contentWidth,
  );
  final v = inverseResolveAxisConstraint(
    constraint: verticalAxisConstraint(constraints.vertical),
    offset: desired.top,
    size: desired.height,
    reference: referenceHeight,
    parent: parentHeight,
    min: minHeight,
    max: maxHeight,
    contentSize: contentHeight,
  );
  return (
    stored: Rect.fromLTWH(h.position, v.position, h.size, v.size),
    exact: h.exact && v.exact,
  );
}
