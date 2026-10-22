import 'package:freezed_annotation/freezed_annotation.dart';

import '../values/geometry.dart';
import '../values/stage_color.dart';
import 'blend_mode.dart';

part 'effect.freezed.dart';
part 'effect.g.dart';

const StageColor _kShadowColor = StageColor(r: 0, g: 0, b: 0, a: 0.25);

/// A node effect (architecture §5). `id` is unique within the node's effect
/// list: effects are addressed by id in property paths.
@Freezed(unionKey: 'type')
sealed class Effect with _$Effect {
  @FreezedUnionValue('dropShadow')
  const factory Effect.dropShadow({
    required String id,
    @Default(_kShadowColor) StageColor color,
    @Default(StagePoint(x: 0, y: 4)) StagePoint offset,
    @Default(4) double blur,
    @Default(0) double spread,
    @Default(BlendMode.normal) BlendMode blendMode,
    @Default(false) bool showBehindTransparentAreas,
    @Default(true) bool visible,
  }) = DropShadow;

  @FreezedUnionValue('innerShadow')
  const factory Effect.innerShadow({
    required String id,
    @Default(_kShadowColor) StageColor color,
    @Default(StagePoint(x: 0, y: 4)) StagePoint offset,
    @Default(4) double blur,
    @Default(0) double spread,
    @Default(BlendMode.normal) BlendMode blendMode,
    @Default(true) bool visible,
  }) = InnerShadow;

  @FreezedUnionValue('layerBlur')
  const factory Effect.layerBlur({
    required String id,
    @Default(4) double radius,
    @Default(true) bool visible,
  }) = LayerBlur;

  @FreezedUnionValue('backgroundBlur')
  const factory Effect.backgroundBlur({
    required String id,
    @Default(4) double radius,
    @Default(true) bool visible,
  }) = BackgroundBlur;

  factory Effect.fromJson(Map<String, dynamic> json) => _$EffectFromJson(json);
}
