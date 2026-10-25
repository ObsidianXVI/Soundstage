import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'timeline_clock.dart';

/// A source of raw clock values (architecture §10.1). The animator reads
/// [value] each frame, applies the clock's smoothing, and evaluates the
/// clock's tracks when the result changed.
///
/// Sources never call `setState` or touch render objects. A source that
/// moves on its own (a playing timeline, playing audio) reports
/// [isActive] so the player keeps its ticker running; sources driven from
/// outside (scroll, pointer) call the animator instead (see
/// `StageAnimator.notifyClockChanged`).
///
/// **Plug point.** `audio` clocks (T0.7) and `behavior` clocks (M3) are
/// created by [StageClockFactories]; a T0.7 audio source implements this
/// class with [value] = the playback position in seconds and [isActive] =
/// playing.
abstract class StageClockSource {
  /// The raw (unsmoothed) value.
  double get value;

  /// Whether the source changes by itself and needs a ticker.
  bool get isActive => false;

  /// Advances self-driven sources by [dt] seconds of wall time.
  void advance(double dt) {}

  /// Called when the scene the clock belongs to becomes visible or not.
  void sceneVisibilityChanged({required bool visible}) {}

  /// The reader asked for reduced motion (`prefers-reduced-motion`): sources
  /// that play by themselves settle on their end state instead of playing,
  /// and start again when it is switched off. Scroll, pointer and audio
  /// sources are unaffected.
  void reducedMotionChanged({required bool reduced}) {}

  void dispose() {}
}

/// A source with a value set from outside.
class StageValueClockSource extends StageClockSource {
  StageValueClockSource([this.value = 0]);

  @override
  double value;
}

/// `sceneScroll(sceneId)`: 0–1 progress through a scene, published by the
/// scene's sliver during layout (`RenderSliverStageScene`).
class StageSceneScrollSource extends StageValueClockSource {
  StageSceneScrollSource(this.sceneId);

  final String sceneId;
}

/// `pointer(frameId, axis)`: −1…1 over a frame along one axis, from the
/// player's hover listener; 0 when the pointer is outside the frame.
class StagePointerSource extends StageValueClockSource {
  StagePointerSource({required this.frameId, required this.axis});

  final String frameId;
  final ir.PointerAxis axis;
}

/// Creates a source for a clock kind the runtime does not drive itself.
/// Returning null leaves the clock at 0.
typedef StageClockSourceFactory =
    StageClockSource? Function(ir.Clock clock, {required String sceneId});

/// Factories for pluggable clock kinds: `audio` (T0.7) and `behavior` (M3).
/// Without one, such clocks hold 0.
class StageClockFactories {
  const StageClockFactories({this.audio, this.behavior});

  final StageClockSourceFactory? audio;
  final StageClockSourceFactory? behavior;
}

/// The source for [clock] in play mode.
StageClockSource createClockSource(
  ir.Clock clock, {
  required String sceneId,
  StageClockFactories factories = const StageClockFactories(),
}) => switch (clock) {
  ir.SceneScrollClock(:final sceneId) => StageSceneScrollSource(sceneId),
  ir.TimelineClock() => StageTimelineSource(clock),
  ir.PointerClock(:final frameId, :final axis) => StagePointerSource(
    frameId: frameId,
    axis: axis,
  ),
  ir.AudioClock() =>
    factories.audio?.call(clock, sceneId: sceneId) ?? StageValueClockSource(),
  ir.BehaviorClock() =>
    factories.behavior?.call(clock, sceneId: sceneId) ??
        StageValueClockSource(),
};
