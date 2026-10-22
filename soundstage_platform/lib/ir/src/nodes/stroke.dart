import 'package:freezed_annotation/freezed_annotation.dart';

import 'paint.dart';

part 'stroke.freezed.dart';
part 'stroke.g.dart';

@JsonEnum()
enum StrokeAlign { inside, center, outside }

@JsonEnum()
enum StrokeCap { none, round, square }

@JsonEnum()
enum StrokeJoin { miter, bevel, round }

/// Stroke weight: uniform, or per side (frames/rectangles only, as in Figma).
@Freezed(unionKey: 'type')
sealed class StrokeWeight with _$StrokeWeight {
  @FreezedUnionValue('uniform')
  const factory StrokeWeight.uniform([@Default(1) double weight]) =
      UniformStrokeWeight;

  @FreezedUnionValue('perSide')
  const factory StrokeWeight.perSide({
    @Default(0) double top,
    @Default(0) double right,
    @Default(0) double bottom,
    @Default(0) double left,
  }) = PerSideStrokeWeight;

  factory StrokeWeight.fromJson(Map<String, dynamic> json) =>
      _$StrokeWeightFromJson(json);
}

/// A node's stroke (architecture §5): one geometry shared by a stack of
/// paints, as in Figma. No paints = no stroke.
@freezed
abstract class Stroke with _$Stroke {
  const factory Stroke({
    @Default(<Paint>[]) List<Paint> paints,
    @Default(StrokeWeight.uniform()) StrokeWeight weight,
    @Default(StrokeAlign.inside) StrokeAlign align,
    @Default(StrokeCap.none) StrokeCap cap,
    @Default(StrokeJoin.miter) StrokeJoin join,
    @Default(4) double miterLimit,

    /// Alternating dash/gap lengths in pixels. Empty = solid.
    @Default(<double>[]) List<double> dash,
  }) = _Stroke;

  factory Stroke.fromJson(Map<String, dynamic> json) => _$StrokeFromJson(json);
}
