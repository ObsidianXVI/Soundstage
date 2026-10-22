import 'package:freezed_annotation/freezed_annotation.dart';

part 'audio.freezed.dart';
part 'audio.g.dart';

/// Where an audio track plays (architecture §10.4).
@Freezed(unionKey: 'type')
sealed class AudioScope with _$AudioScope {
  /// Across the whole story.
  @FreezedUnionValue('story')
  const factory AudioScope.story() = StoryAudioScope;

  /// Only while scene `sceneId` is on screen.
  @FreezedUnionValue('scene')
  const factory AudioScope.scene(String sceneId) = SceneAudioScope;

  factory AudioScope.fromJson(Map<String, dynamic> json) =>
      _$AudioScopeFromJson(json);
}

/// A timed word inside a lyric line (enhanced LRC). Times in seconds.
@freezed
abstract class LyricWord with _$LyricWord {
  const factory LyricWord({
    required double start,
    required String text,
    double? end,
  }) = _LyricWord;

  factory LyricWord.fromJson(Map<String, dynamic> json) =>
      _$LyricWordFromJson(json);
}

/// A lyric line. Times in seconds; a null `end` ends at the next line.
/// Empty `words` = line-level timing only.
@freezed
abstract class LyricLine with _$LyricLine {
  const factory LyricLine({
    required double start,
    required String text,
    double? end,
    @Default(<LyricWord>[]) List<LyricWord> words,
  }) = _LyricLine;

  factory LyricLine.fromJson(Map<String, dynamic> json) =>
      _$LyricLineFromJson(json);
}

@freezed
abstract class LyricsDoc with _$LyricsDoc {
  const factory LyricsDoc({@Default(<LyricLine>[]) List<LyricLine> lines}) =
      _LyricsDoc;

  factory LyricsDoc.fromJson(Map<String, dynamic> json) =>
      _$LyricsDocFromJson(json);
}

/// An audio track (architecture §10.4). `volume` is 0–1; fades are seconds.
@freezed
abstract class AudioTrack with _$AudioTrack {
  const factory AudioTrack({
    required String id,
    required String assetId,
    @Default(AudioScope.story()) AudioScope scope,
    @Default(false) bool autoplay,
    @Default(false) bool loop,
    @Default(1) double volume,
    @Default(0) double fadeIn,
    @Default(0) double fadeOut,
    LyricsDoc? lyrics,
  }) = _AudioTrack;

  factory AudioTrack.fromJson(Map<String, dynamic> json) =>
      _$AudioTrackFromJson(json);
}
