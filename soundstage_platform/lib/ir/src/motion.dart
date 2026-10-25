import 'package:freezed_annotation/freezed_annotation.dart';

import 'values/ir_value.dart';

part 'motion.freezed.dart';
part 'motion.g.dart';

@JsonEnum()
enum TimelineLoop { none, loop, pingPong }

@JsonEnum()
enum TimelineTrigger { sceneEnter, interaction, autoplay }

@JsonEnum()
enum PointerAxis { x, y }

@JsonEnum()
enum StepPosition { jumpStart, jumpEnd }

/// Named easing presets. The curves are defined in T0.3 (`easing.dart`).
@JsonEnum()
enum EasingPreset {
  ease,
  easeIn,
  easeOut,
  easeInOut,
  easeInBack,
  easeOutBack,
  easeInOutBack,
}

/// A source of time-like values that tracks are bound to (architecture
/// §10.1). Every clock has an `id` (referenced by `Track.clockId`,
/// text reveals and `clockReach` triggers) and an optional `smoothing` in
/// seconds: the evaluated value follows the raw value with a critically
/// damped spring. 0 = no smoothing. `name` is an optional label the editor
/// shows (empty: it derives one from the clock's kind and target).
@Freezed(unionKey: 'type')
sealed class Clock with _$Clock {
  /// 0–1 scroll progress through scene `sceneId` (§3.2).
  @FreezedUnionValue('sceneScroll')
  const factory Clock.sceneScroll({
    required String id,
    required String sceneId,
    @Default('') String name,
    @Default(0) double smoothing,
  }) = SceneScrollClock;

  /// Seconds, advanced by playback. `rate`: playback speed multiplier.
  @FreezedUnionValue('timeline')
  const factory Clock.timeline({
    required String id,
    required double duration,
    @Default('') String name,
    @Default(TimelineLoop.none) TimelineLoop loop,
    @Default(1) double rate,
    @Default(TimelineTrigger.sceneEnter) TimelineTrigger trigger,
    @Default(0) double smoothing,
  }) = TimelineClock;

  /// Seconds: the playback position of audio track `audioTrackId`.
  @FreezedUnionValue('audio')
  const factory Clock.audio({
    required String id,
    required String audioTrackId,
    @Default('') String name,
    @Default(0) double smoothing,
  }) = AudioClock;

  /// −1…1: the pointer position over frame `frameId` along `axis`.
  @FreezedUnionValue('pointer')
  const factory Clock.pointer({
    required String id,
    required String frameId,
    @Default(PointerAxis.x) PointerAxis axis,
    @Default('') String name,
    @Default(0) double smoothing,
  }) = PointerClock;

  /// A behaviour-defined value, e.g. a carousel's index (`name: 'index'`).
  @FreezedUnionValue('behavior')
  const factory Clock.behavior({
    required String id,
    required String nodeId,
    required String name,
    @Default(0) double smoothing,
  }) = BehaviorClock;

  factory Clock.fromJson(Map<String, dynamic> json) => _$ClockFromJson(json);
}

/// Easing applied from a keyframe to the next (architecture §10.2).
@Freezed(unionKey: 'type')
sealed class Easing with _$Easing {
  @FreezedUnionValue('linear')
  const factory Easing.linear() = LinearEasing;

  @FreezedUnionValue('cubicBezier')
  const factory Easing.cubicBezier(double x1, double y1, double x2, double y2) =
      CubicBezierEasing;

  @FreezedUnionValue('preset')
  const factory Easing.preset(EasingPreset preset) = PresetEasing;

  /// The analytic step response of a damped spring, normalised to the
  /// segment.
  @FreezedUnionValue('spring')
  const factory Easing.spring({
    @Default(1) double mass,
    @Default(100) double stiffness,
    @Default(15) double damping,
  }) = SpringEasing;

  @FreezedUnionValue('steps')
  const factory Easing.steps(
    int count, {
    @Default(StepPosition.jumpEnd) StepPosition position,
  }) = StepsEasing;

  /// Holds the start value until the next keyframe.
  @FreezedUnionValue('hold')
  const factory Easing.hold() = HoldEasing;

  factory Easing.fromJson(Map<String, dynamic> json) => _$EasingFromJson(json);
}

/// A keyframe. `t` is in the clock's units (0–1 for scroll, seconds for
/// timelines and audio). `easing` applies from this keyframe to the next.
@freezed
abstract class Keyframe with _$Keyframe {
  const factory Keyframe({
    required String id,
    required double t,
    required IrValue value,
    @Default(Easing.linear()) Easing easing,
  }) = _Keyframe;

  factory Keyframe.fromJson(Map<String, dynamic> json) =>
      _$KeyframeFromJson(json);
}

/// Animates one property of one node from a clock (architecture §10.2).
///
/// - `target`: node path (ids joined by `/`; instance children are
///   namespaced `<instanceId>/<innerId>`).
/// - `property`: a `PropertyPath` string.
/// - `breakpoints`: breakpoint ids the track applies at; null = all.
@freezed
abstract class Track with _$Track {
  const factory Track({
    required String id,
    required String target,
    required String property,
    required String clockId,
    @Default(<Keyframe>[]) List<Keyframe> keyframes,
    List<String>? breakpoints,
  }) = _Track;

  factory Track.fromJson(Map<String, dynamic> json) => _$TrackFromJson(json);
}
