import 'package:freezed_annotation/freezed_annotation.dart';

part 'geometry.freezed.dart';
part 'geometry.g.dart';

/// A width/height pair in logical pixels.
@freezed
abstract class StageSize with _$StageSize {
  const factory StageSize({required double width, required double height}) =
      _StageSize;

  factory StageSize.fromJson(Map<String, dynamic> json) =>
      _$StageSizeFromJson(json);
}

/// A 2D point or offset. Units depend on the field (pixels, or 0–1 when the
/// field says it is normalised).
@freezed
abstract class StagePoint with _$StagePoint {
  const factory StagePoint({@Default(0) double x, @Default(0) double y}) =
      _StagePoint;

  factory StagePoint.fromJson(Map<String, dynamic> json) =>
      _$StagePointFromJson(json);
}

/// An axis-aligned rectangle. Units depend on the field (e.g. `cropRect` is
/// normalised in the image, 0–1).
@freezed
abstract class StageRect with _$StageRect {
  const factory StageRect({
    @Default(0) double x,
    @Default(0) double y,
    @Default(1) double width,
    @Default(1) double height,
  }) = _StageRect;

  factory StageRect.fromJson(Map<String, dynamic> json) =>
      _$StageRectFromJson(json);
}

/// Insets on four sides (padding), in logical pixels.
@freezed
abstract class EdgeInsetsValue with _$EdgeInsetsValue {
  const factory EdgeInsetsValue({
    @Default(0) double top,
    @Default(0) double right,
    @Default(0) double bottom,
    @Default(0) double left,
  }) = _EdgeInsetsValue;

  /// The same inset on every side.
  factory EdgeInsetsValue.all(double v) =>
      EdgeInsetsValue(top: v, right: v, bottom: v, left: v);

  factory EdgeInsetsValue.fromJson(Map<String, dynamic> json) =>
      _$EdgeInsetsValueFromJson(json);

  static const EdgeInsetsValue zero = EdgeInsetsValue();
}

/// Corner radius: one radius for all corners, or one per corner
/// (architecture §5).
@Freezed(unionKey: 'type')
sealed class CornerRadius with _$CornerRadius {
  @FreezedUnionValue('uniform')
  const factory CornerRadius.uniform([@Default(0) double radius]) =
      UniformCornerRadius;

  /// Per-corner radii: top-left, top-right, bottom-right, bottom-left.
  @FreezedUnionValue('perCorner')
  const factory CornerRadius.perCorner({
    @Default(0) double tl,
    @Default(0) double tr,
    @Default(0) double br,
    @Default(0) double bl,
  }) = CornerRadii;

  factory CornerRadius.fromJson(Map<String, dynamic> json) =>
      _$CornerRadiusFromJson(json);
}
