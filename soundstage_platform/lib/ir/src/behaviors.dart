import 'package:freezed_annotation/freezed_annotation.dart';

import 'nodes/layout.dart';
import 'nodes/text.dart';

part 'behaviors.freezed.dart';
part 'behaviors.g.dart';

@JsonEnum()
enum CarouselPhysics {
  /// One page per swipe.
  paged,

  /// Free scrolling with momentum (snapping still applies when `snap`).
  free,
}

@JsonEnum()
enum MarqueeDirection { left, right, up, down }

@JsonEnum()
enum TextRevealUnit { char, word, line }

/// How a lyrics frame keeps the active line in view.
@JsonEnum()
enum LyricsScrollMode {
  /// No scrolling; lines only restyle.
  none,

  /// The active line is scrolled to the frame's vertical centre.
  center,

  /// The active line is scrolled to the frame's top.
  top,
}

/// A sub-range of a clock's value, e.g. the part of a scroll clock over
/// which a text reveal runs.
@freezed
abstract class ClockRange with _$ClockRange {
  const factory ClockRange({@Default(0) double start, @Default(1) double end}) =
      _ClockRange;

  factory ClockRange.fromJson(Map<String, dynamic> json) =>
      _$ClockRangeFromJson(json);
}

/// Interactive behaviour attached to a frame (architecture §9). The frame's
/// children stay ordinary nodes; the behaviour adds interaction on top.
@Freezed(unionKey: 'type')
sealed class Behavior with _$Behavior {
  /// `autoplay`: seconds per slide; 0 = off. `peek`: pixels of the
  /// neighbouring slides left visible.
  @FreezedUnionValue('carousel')
  const factory Behavior.carousel({
    @Default(LayoutDirection.horizontal) LayoutDirection axis,
    @Default(true) bool snap,
    @Default(false) bool loop,
    @Default(0) double autoplay,
    @Default(0) double peek,
    @Default(CarouselPhysics.paged) CarouselPhysics physics,
  }) = CarouselBehavior;

  @FreezedUnionValue('lightbox')
  const factory Behavior.lightbox() = LightboxBehavior;

  /// `speed`: pixels per second.
  @FreezedUnionValue('marquee')
  const factory Behavior.marquee({
    @Default(50) double speed,
    @Default(MarqueeDirection.left) MarqueeDirection direction,
  }) = MarqueeBehavior;

  /// `stagger`: fraction of `range` between successive units.
  @FreezedUnionValue('textReveal')
  const factory Behavior.textReveal({
    required String clockId,
    @Default(TextRevealUnit.word) TextRevealUnit unit,
    @Default(0.05) double stagger,
    @Default(ClockRange()) ClockRange range,
  }) = TextRevealBehavior;

  @FreezedUnionValue('lyrics')
  const factory Behavior.lyrics({
    required String audioTrackId,
    @Default(TextStyleOverride()) TextStyleOverride activeStyle,
    @Default(TextStyleOverride()) TextStyleOverride inactiveStyle,
    @Default(LyricsScrollMode.center) LyricsScrollMode scrollMode,
  }) = LyricsBehavior;

  @FreezedUnionValue('audioControls')
  const factory Behavior.audioControls({required String audioTrackId}) =
      AudioControlsBehavior;

  factory Behavior.fromJson(Map<String, dynamic> json) =>
      _$BehaviorFromJson(json);
}
