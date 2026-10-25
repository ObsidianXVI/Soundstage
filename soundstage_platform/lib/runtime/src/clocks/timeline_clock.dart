import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'clock_source.dart';

/// `timeline(id)`: seconds, advanced by playback (architecture §10.1).
///
/// - `loop: none` plays to the end (or to 0 at a negative rate) and stops.
///   `loop` wraps. `pingPong` runs forward then backward.
/// - `rate` scales wall time (negative plays backward).
/// - `trigger`: `autoplay` plays from the start of the player.
///   `sceneEnter` plays while the clock's scene is visible and pauses when
///   it leaves; re-entering resumes, and a finished `loop: none` timeline
///   restarts from 0. `interaction` (M3) waits for [play].
///
/// [play], [pause] and [seek] are the controls interactions will call (M3).
class StageTimelineSource extends StageClockSource {
  StageTimelineSource(this.clock)
    : _playing = clock.trigger == ir.TimelineTrigger.autoplay;

  final ir.TimelineClock clock;

  double get duration => clock.duration > 0 ? clock.duration : 0;

  /// Unwrapped playhead: seconds of playback since 0 (times rate).
  double _position = 0;
  bool _playing;

  bool get isPlaying => _playing;

  /// The playhead before looping/ping-pong mapping.
  double get position => _position;

  @override
  bool get isActive => _playing;

  @override
  double get value => timelineValue(_position, duration, clock.loop);

  /// 1, or -1 after [reverse]: the direction of playback relative to the
  /// clock's own rate.
  double _dir = 1;
  double get _rate => clock.rate * _dir;

  void play() {
    if (clock.loop == ir.TimelineLoop.none && _finished) {
      _position = _rate >= 0 ? 0 : duration;
    }
    _playing = true;
  }

  /// Plays in the other direction from where the playhead is (an
  /// interaction's "reverse timeline").
  void reverse() {
    _dir = -_dir;
    _playing = true;
  }

  void pause() => _playing = false;

  /// Moves the playhead to [seconds] (unwrapped).
  void seek(double seconds) => _position = seconds;

  bool get _finished => _rate >= 0 ? _position >= duration : _position <= 0;

  @override
  void advance(double dt) {
    if (!_playing) return;
    _position += dt * _rate;
    if (clock.loop == ir.TimelineLoop.none) {
      if (_position >= duration) {
        _position = duration;
        if (_rate >= 0) _playing = false;
      } else if (_position <= 0) {
        _position = 0;
        if (_rate < 0) _playing = false;
      }
    } else {
      // Keep the playhead bounded so precision never degrades.
      final period = clock.loop == ir.TimelineLoop.pingPong
          ? 2 * duration
          : duration;
      if (period > 0 && (_position >= period || _position < 0)) {
        _position %= period;
      }
    }
  }

  bool _reduced = false;

  /// Reduced motion (see [StageClockSource.reducedMotionChanged]): the
  /// `autoplay` and `sceneEnter` triggers jump to the end state and stay
  /// there (a `loop` or `pingPong` timeline has no end: it rests at its
  /// start). `interaction` timelines wait for [play] as before. Switching
  /// it off restarts an `autoplay` timeline; a `sceneEnter` one starts the
  /// next time its scene becomes visible.
  @override
  void reducedMotionChanged({required bool reduced}) {
    if (reduced == _reduced) return;
    _reduced = reduced;
    if (clock.trigger == ir.TimelineTrigger.interaction) return;
    if (reduced) {
      _playing = false;
      _position = clock.loop == ir.TimelineLoop.none
          ? (clock.rate >= 0 ? duration : 0)
          : 0;
    } else if (clock.trigger == ir.TimelineTrigger.autoplay) {
      play();
    }
  }

  @override
  void sceneVisibilityChanged({required bool visible}) {
    if (clock.trigger != ir.TimelineTrigger.sceneEnter || _reduced) return;
    if (visible) {
      play();
    } else {
      pause();
    }
  }
}

/// The value of a timeline of [duration] seconds at unwrapped playhead
/// [position] under [loop].
double timelineValue(double position, double duration, ir.TimelineLoop loop) {
  if (duration <= 0) return 0;
  switch (loop) {
    case ir.TimelineLoop.none:
      return position < 0 ? 0 : (position > duration ? duration : position);
    case ir.TimelineLoop.loop:
      // Dart's `%` is never negative; the end of a period is the next start.
      return position % duration;
    case ir.TimelineLoop.pingPong:
      final p = position % (2 * duration);
      return p <= duration ? p : 2 * duration - p;
  }
}
