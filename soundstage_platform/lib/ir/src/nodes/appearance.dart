import 'package:freezed_annotation/freezed_annotation.dart';

import '../values/geometry.dart';
import 'effect.dart';
import 'paint.dart';
import 'stroke.dart';

part 'appearance.freezed.dart';
part 'appearance.g.dart';

/// Fills, stroke, effects and corners of a frame, shape or video
/// (architecture §4.2, §5). On a video, fills paint behind the video frame
/// (visible in `fit` letterboxing and before the first frame decodes).
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

/// Stroke and effects of a text node (architecture §4.1, §7): text outlines
/// and text shadows. Text fills live in `TextStyle.fills`, and text has no
/// corners, so this is the text-specific subset of [Appearance].
///
/// `strokeStyleId` / `effectStyleId` reference `TokenSystem.paintStyles` /
/// `effectStyles`; when set, the style's stack replaces the local one.
@freezed
abstract class TextAppearance with _$TextAppearance {
  const factory TextAppearance({
    @Default(Stroke()) Stroke strokes,
    @Default(<Effect>[]) List<Effect> effects,
    String? strokeStyleId,
    String? effectStyleId,
  }) = _TextAppearance;

  factory TextAppearance.fromJson(Map<String, dynamic> json) =>
      _$TextAppearanceFromJson(json);
}
