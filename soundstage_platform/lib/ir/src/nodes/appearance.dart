import 'package:freezed_annotation/freezed_annotation.dart';

import '../values/geometry.dart';
import 'effect.dart';
import 'paint.dart';
import 'stroke.dart';

part 'appearance.freezed.dart';
part 'appearance.g.dart';

/// Fills, stroke, effects and corners of a frame or shape (architecture §4.2,
/// §5).
///
/// `fillStyleId` / `strokeStyleId` / `effectStyleId` reference
/// `TokenSystem.paintStyles` / `effectStyles` (§8). When set, the style's
/// stack is used and the local list is ignored, as in Figma.
@freezed
abstract class Appearance with _$Appearance {
  const factory Appearance({
    @Default(<Paint>[]) List<Paint> fills,
    @Default(Stroke()) Stroke strokes,
    @Default(<Effect>[]) List<Effect> effects,
    @Default(CornerRadius.uniform()) CornerRadius cornerRadius,

    /// Figma corner smoothing, 0–1.
    @Default(0) double cornerSmoothing,
    String? fillStyleId,
    String? strokeStyleId,
    String? effectStyleId,
  }) = _Appearance;

  factory Appearance.fromJson(Map<String, dynamic> json) =>
      _$AppearanceFromJson(json);
}
