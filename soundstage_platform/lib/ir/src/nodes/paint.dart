import 'package:freezed_annotation/freezed_annotation.dart';

import '../values/geometry.dart';
import '../values/stage_color.dart';
import 'blend_mode.dart';

part 'paint.freezed.dart';
part 'paint.g.dart';

/// Gradient geometry kinds (architecture §5).
@JsonEnum()
enum GradientKind { linear, radial, angular, diamond }

/// Image scale modes (architecture §6). Also used by video and embeds.
@JsonEnum()
enum ImageScaleMode { fill, fit, crop, tile }

/// One stop of a gradient.
@freezed
abstract class ColorStop with _$ColorStop {
  const factory ColorStop({
    required double position,
    required StageColor color,
  }) = _ColorStop;

  factory ColorStop.fromJson(Map<String, dynamic> json) =>
      _$ColorStopFromJson(json);
}

/// Figma-style gradient handles in normalised node coordinates (0–1), so the
/// gradient scales with the node. `width` is the third handle that sets the
/// gradient's perpendicular extent (radial/angular/diamond).
@freezed
abstract class GradientHandles with _$GradientHandles {
  const factory GradientHandles({
    @Default(StagePoint(x: 0.5, y: 0)) StagePoint start,
    @Default(StagePoint(x: 0.5, y: 1)) StagePoint end,
    @Default(StagePoint(x: 0, y: 0)) StagePoint width,
  }) = _GradientHandles;

  factory GradientHandles.fromJson(Map<String, dynamic> json) =>
      _$GradientHandlesFromJson(json);
}

/// Image adjustments (architecture §6). Each is in −1…1, 0 = unchanged, as in
/// Figma's image adjustments.
@freezed
abstract class ImageFilters with _$ImageFilters {
  const factory ImageFilters({
    @Default(0) double exposure,
    @Default(0) double contrast,
    @Default(0) double saturation,
    @Default(0) double temperature,
    @Default(0) double tint,
    @Default(0) double highlights,
    @Default(0) double shadows,
  }) = _ImageFilters;

  factory ImageFilters.fromJson(Map<String, dynamic> json) =>
      _$ImageFiltersFromJson(json);
}

/// One entry in a paint stack (fills, stroke paints, text fills, scene
/// backgrounds). Stacks are ordered bottom → top.
///
/// `id` must be unique within its stack: paints are addressed by id in
/// property paths (`fills.<paintId>.color`), never by index.
@Freezed(unionKey: 'type')
sealed class Paint with _$Paint {
  @FreezedUnionValue('solid')
  const factory Paint.solid({
    required String id,
    required StageColor color,
    @Default(true) bool visible,
    @Default(1) double opacity,
    @Default(BlendMode.normal) BlendMode blendMode,
  }) = SolidPaint;

  @FreezedUnionValue('gradient')
  const factory Paint.gradient({
    required String id,
    required List<ColorStop> stops,
    @Default(GradientKind.linear) GradientKind kind,
    @Default(GradientHandles()) GradientHandles handles,
    @Default(true) bool visible,
    @Default(1) double opacity,
    @Default(BlendMode.normal) BlendMode blendMode,
  }) = GradientPaint;

  /// An image fill (architecture §6).
  ///
  /// - `focalPoint`: normalised in the image; kept as close to the node
  ///   centre as bounds allow (`fill`), or the letterbox alignment (`fit`).
  /// - `cropRect`: normalised in the image; used by `crop` only.
  /// - `rotation`: quarter turns in degrees — one of 0, 90, 180, 270.
  @FreezedUnionValue('image')
  const factory Paint.image({
    required String id,
    required String assetId,
    @Default(ImageScaleMode.fill) ImageScaleMode scaleMode,
    @Default(StagePoint(x: 0.5, y: 0.5)) StagePoint focalPoint,
    StageRect? cropRect,
    @Default(1) double tileScale,
    @Default(0) int rotation,
    @Default(ImageFilters()) ImageFilters filters,
    @Default(true) bool visible,
    @Default(1) double opacity,
    @Default(BlendMode.normal) BlendMode blendMode,
  }) = ImagePaint;

  factory Paint.fromJson(Map<String, dynamic> json) => _$PaintFromJson(json);
}
