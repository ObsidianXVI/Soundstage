import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'timeline_clock.dart';

/// The clock values of [scene]'s composed state, its poster frame
/// (architecture §16.1, m4.md T4.6): scroll clocks at [at] (default the
/// scene's poster clock), autoplay and sceneEnter timelines where reduced
/// motion leaves them (their end), every other clock at rest (0).
Map<String, double> posterClockValues(ir.Scene scene, {double? at}) => {
  for (final c in scene.clocks)
    c.id: switch (c) {
      ir.SceneScrollClock() => at ?? scene.effectivePosterClock,
      final ir.TimelineClock t =>
        (StageTimelineSource(t)..reducedMotionChanged(reduced: true)).value,
      _ => 0,
    },
};
