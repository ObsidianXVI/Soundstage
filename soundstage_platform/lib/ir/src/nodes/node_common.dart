import 'package:freezed_annotation/freezed_annotation.dart';

import '../interactions.dart';
import '../tokens.dart';
import '../values/ir_value.dart';
import 'blend_mode.dart';

part 'node_common.freezed.dart';
part 'node_common.g.dart';

/// How a child takes part in its parent's auto layout.
@JsonEnum()
enum Positioning {
  auto,

  /// "Ignore auto layout": placed by constraints (§4.3).
  absolute,
}

/// A child's sizing along an axis inside its parent.
@JsonEnum()
enum Sizing { fixed, hug, fill }

@JsonEnum()
enum HorizontalConstraint { left, right, leftRight, center, scale }

@JsonEnum()
enum VerticalConstraint { top, bottom, topBottom, center, scale }

/// Alignment of a child within its grid cell.
@JsonEnum()
enum GridAlign { start, center, end, stretch }

/// Masking (M3): a mask node masks the siblings above it in the same parent.
@JsonEnum()
enum MaskMode { none, alpha, luminance }

/// Paint-only transform, like CSS `transform`; never affects layout
/// (architecture §4.2). Origin is normalised in the node box.
@freezed
abstract class MotionTransform with _$MotionTransform {
  const factory MotionTransform({
    @Default(0) double translateX,
    @Default(0) double translateY,
    @Default(1) double scaleX,
    @Default(1) double scaleY,
    @Default(0) double rotate,
    @Default(0) double skewX,
    @Default(0) double skewY,
    @Default(0.5) double originX,
    @Default(0.5) double originY,
  }) = _MotionTransform;

  factory MotionTransform.fromJson(Map<String, dynamic> json) =>
      _$MotionTransformFromJson(json);
}

/// Constraints used when the node is absolutely positioned (§4.3).
@freezed
abstract class Constraints with _$Constraints {
  const factory Constraints({
    @Default(HorizontalConstraint.left) HorizontalConstraint horizontal,
    @Default(VerticalConstraint.top) VerticalConstraint vertical,
  }) = _Constraints;

  factory Constraints.fromJson(Map<String, dynamic> json) =>
      _$ConstraintsFromJson(json);
}

/// Placement in a grid parent (§4.5). Null `column`/`row` = auto-placed.
/// Indices are 0-based.
@freezed
abstract class GridPlacement with _$GridPlacement {
  const factory GridPlacement({
    int? column,
    int? row,
    @Default(1) int columnSpan,
    @Default(1) int rowSpan,
    @Default(GridAlign.start) GridAlign alignX,
    @Default(GridAlign.start) GridAlign alignY,
  }) = _GridPlacement;

  factory GridPlacement.fromJson(Map<String, dynamic> json) =>
      _$GridPlacementFromJson(json);
}

/// How a node behaves inside its parent (§4.2). Null min/max = unbounded.
@freezed
abstract class LayoutChild with _$LayoutChild {
  const factory LayoutChild({
    @Default(Positioning.auto) Positioning positioning,
    @Default(Sizing.fixed) Sizing horizontalSizing,
    @Default(Sizing.fixed) Sizing verticalSizing,
    double? minWidth,
    double? maxWidth,
    double? minHeight,
    double? maxHeight,
    @Default(Constraints()) Constraints constraints,
    @Default(GridPlacement()) GridPlacement grid,
  }) = _LayoutChild;

  factory LayoutChild.fromJson(Map<String, dynamic> json) =>
      _$LayoutChildFromJson(json);
}

/// Properties shared by every node kind (architecture §4.2).
///
/// - `blendMode`: null means the kind's default — `passThrough` for frames,
///   `normal` for everything else (see `Node.effectiveBlendMode`).
/// - `x, y, width, height`: design-time geometry relative to the parent, at
///   the parent's reference size (§4.3).
/// - `rotation`: degrees; geometric (auto layout measures rotated bounds).
/// - `breakpointOverrides`: `{ breakpointId: Patch }` (§3.1).
/// - `bindings`: `{ PropertyPath: TokenRef }` (§8).
/// - `componentBindings`: `{ PropertyPath: componentPropId }` for nodes
///   inside a component's root (§9).
/// - `interactions`: triggers and actions (§10.3, runtime M3).
@freezed
abstract class NodeCommon with _$NodeCommon {
  const factory NodeCommon({
    required String id,
    @Default('') String name,
    @Default(true) bool visible,

    /// Editor only.
    @Default(false) bool locked,
    @Default(1) double opacity,
    BlendMode? blendMode,
    @Default(0) double x,
    @Default(0) double y,
    @Default(0) double width,
    @Default(0) double height,
    @Default(0) double rotation,
    @Default(false) bool flipX,
    @Default(false) bool flipY,
    @Default(MotionTransform()) MotionTransform motion,
    @Default(LayoutChild()) LayoutChild layoutChild,
    @Default(MaskMode.none) MaskMode mask,
    @Default(<String, Patch>{}) Map<String, Patch> breakpointOverrides,
    @Default(<String, TokenRef>{}) Map<String, TokenRef> bindings,
    @Default(<String, String>{}) Map<String, String> componentBindings,
    @Default(<Interaction>[]) List<Interaction> interactions,
  }) = _NodeCommon;

  factory NodeCommon.fromJson(Map<String, dynamic> json) =>
      _$NodeCommonFromJson(json);
}
