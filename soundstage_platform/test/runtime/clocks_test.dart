import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// Runs a smoother at [hz] for [seconds] towards [target] (a function of
/// time, sampled at the start of each frame) and returns the final value.
double _run(double hz, double seconds, double Function(double t) target) {
  final s = StageSmoother(smoothing: 0.2);
  final dt = 1 / hz;
  final frames = (seconds * hz).round();
  for (var i = 0; i < frames; i++) {
    s.step(target(i * dt), dt);
  }
  return s.value;
}

void main() {
  group('smoothing', () {
    test('converges to a step target and comes to rest exactly', () {
      final s = StageSmoother(smoothing: 0.2);
      var frames = 0;
      while (!s.settledOn(1) && frames < 1000) {
        s.step(1, 1 / 60);
        frames++;
      }
      expect(s.value, 1);
      expect(s.velocity, 0);
      // About 2–3 time constants to settle within 1e-5 of a unit step.
      expect(frames / 60, inInclusiveRange(0.4, 2.0));
    });

    test('is critically damped: approaches without overshoot', () {
      final s = StageSmoother(smoothing: 0.3);
      var last = 0.0;
      for (var i = 0; i < 240; i++) {
        s.step(1, 1 / 120);
        expect(s.value, lessThanOrEqualTo(1));
        expect(s.value, greaterThanOrEqualTo(last));
        last = s.value;
      }
    });

    test('follows the analytic response (ω = 2 / smoothing)', () {
      final s = StageSmoother(smoothing: 0.2);
      for (var i = 0; i < 12; i++) {
        s.step(1, 1 / 60);
      }
      const w = 2 / 0.2, t = 12 / 60;
      expect(s.value, closeTo(1 - (1 + w * t) * math.exp(-w * t), 1e-12));
    });

    test('is frame-rate independent (30 vs 60 vs 120 Hz)', () {
      // A step target is integrated exactly: identical at shared times.
      final step30 = _run(30, 0.5, (_) => 1);
      final step60 = _run(60, 0.5, (_) => 1);
      final step120 = _run(120, 0.5, (_) => 1);
      expect(step60, closeTo(step30, 1e-12));
      expect(step120, closeTo(step30, 1e-12));

      // A moving target (scroll) is sampled per frame, so rates differ by
      // the sampling only: within a small tolerance of each other.
      double ramp(double t) => math.min(1.0, t / 0.4);
      final r30 = _run(30, 0.6, ramp);
      final r60 = _run(60, 0.6, ramp);
      final r120 = _run(120, 0.6, ramp);
      expect((r30 - r120).abs(), lessThan(0.03));
      expect((r60 - r120).abs(), lessThan(0.015));
      for (final hz in [30.0, 60.0, 120.0]) {
        expect(_run(hz, 3, ramp), closeTo(1, 1e-5), reason: '$hz Hz settles');
      }
    });

    test('no smoothing follows the target exactly', () {
      final s = StageSmoother(smoothing: 0);
      expect(s.step(0.4, 1 / 60), isTrue);
      expect(s.value, 0.4);
      expect(s.step(0.4, 1 / 60), isFalse);
    });
  });

  group('timeline', () {
    ir.TimelineClock clock(
      ir.TimelineLoop loop, {
      double rate = 1,
      ir.TimelineTrigger trigger = ir.TimelineTrigger.autoplay,
    }) => ir.TimelineClock(
      id: 'tl',
      duration: 2,
      loop: loop,
      rate: rate,
      trigger: trigger,
    );

    List<double> sample(StageTimelineSource s, int steps, double dt) => [
      for (var i = 0; i < steps; i++) (s..advance(dt)).value,
    ];

    test('none: plays to the end and stops', () {
      final s = StageTimelineSource(clock(ir.TimelineLoop.none));
      expect(s.isPlaying, isTrue);
      expect(sample(s, 5, 0.5), [0.5, 1.0, 1.5, 2.0, 2.0]);
      expect(s.isPlaying, isFalse);
      expect(s.isActive, isFalse);
      s.play(); // a finished timeline restarts
      expect(s.value, 0);
    });

    test('loop: wraps to 0', () {
      final s = StageTimelineSource(clock(ir.TimelineLoop.loop));
      expect(sample(s, 6, 0.75), [0.75, 1.5, 0.25, 1.0, 1.75, 0.5]);
      expect(s.isPlaying, isTrue);
    });

    test('pingPong: runs forward then backward', () {
      final s = StageTimelineSource(clock(ir.TimelineLoop.pingPong));
      expect(sample(s, 8, 0.5), [0.5, 1.0, 1.5, 2.0, 1.5, 1.0, 0.5, 0.0]);
      expect(sample(s, 2, 0.5), [0.5, 1.0]);
    });

    test('rate scales time; negative rates play backward', () {
      final fast = StageTimelineSource(clock(ir.TimelineLoop.none, rate: 2));
      expect(sample(fast, 2, 0.25), [0.5, 1.0]);
      final back = StageTimelineSource(clock(ir.TimelineLoop.none, rate: -1))
        ..seek(2);
      expect(sample(back, 3, 1), [1.0, 0.0, 0.0]);
      expect(back.isPlaying, isFalse);
    });

    test('sceneEnter plays while visible; play/pause/seek', () {
      final s = StageTimelineSource(
        clock(ir.TimelineLoop.loop, trigger: ir.TimelineTrigger.sceneEnter),
      );
      expect(s.isPlaying, isFalse);
      s.sceneVisibilityChanged(visible: true);
      expect(sample(s, 1, 0.5), [0.5]);
      s.sceneVisibilityChanged(visible: false);
      expect(sample(s, 1, 0.5), [0.5]);
      s
        ..seek(1.25)
        ..play();
      expect(sample(s, 1, 0.25), [1.5]);
      s.pause();
      expect(sample(s, 1, 0.25), [1.5]);
    });

    test('interaction waits for play', () {
      final s = StageTimelineSource(
        clock(ir.TimelineLoop.none, trigger: ir.TimelineTrigger.interaction),
      );
      s.sceneVisibilityChanged(visible: true);
      expect(s.isPlaying, isFalse);
      s.play();
      expect(sample(s, 1, 0.5), [0.5]);
    });
  });
}
