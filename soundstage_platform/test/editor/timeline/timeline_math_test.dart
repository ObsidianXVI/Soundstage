import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/timeline/timeline_math.dart';
import 'package:soundstage_platform/ir/ir.dart';

void main() {
  group('clock spans', () {
    final doc = StageDocument.empty(ids: IdGenerator.seeded(1));
    final scene = Scene.blankPinned(
      ids: IdGenerator.seeded(2),
      breakpoint: doc.breakpoints.first,
    );

    test('per clock kind', () {
      expect(
        clockSpan(doc, scene, const Clock.sceneScroll(id: 's', sceneId: 'x')),
        const ClockSpan(0, 1, ClockUnit.progress),
      );
      final tl = clockSpan(
        doc,
        scene,
        const Clock.timeline(id: 't', duration: 4),
      );
      expect(
        (tl.min, tl.max, tl.unit, tl.playable),
        (0.0, 4.0, ClockUnit.seconds, true),
      );
      expect(tl.openEnded, isTrue);
      final p = clockSpan(
        doc,
        scene,
        const Clock.pointer(id: 'p', frameId: 'f'),
      );
      expect((p.min, p.max, p.playable), (-1.0, 1.0, false));
      expect(p.clamp(3), 1);
      expect(tl.clamp(9), 9);
      expect(tl.clamp(-1), 0);
    });

    test('audio clocks use the asset duration, else the last keyframe', () {
      final withAudio = doc.copyWith(
        assets: const {
          'a1': Asset(
            id: 'a1',
            kind: AssetKind.audio,
            uri: 'asset://a1',
            duration: 12.5,
          ),
        },
        audioTracks: const [AudioTrack(id: 'au', assetId: 'a1')],
      );
      const clock = Clock.audio(id: 'ac', audioTrackId: 'au');
      expect(clockSpan(withAudio, scene, clock).max, 12.5);
      final keyed = scene.copyWith(
        tracks: const [
          Track(
            id: 't',
            target: 'n',
            property: 'opacity',
            clockId: 'ac',
            keyframes: [Keyframe(id: 'k', t: 7, value: IrValue.number(1))],
          ),
        ],
      );
      expect(clockSpan(doc, keyed, clock).max, 7);
    });
  });

  group('view mapping', () {
    test('fit, pan and zoom about a point', () {
      final v = TimelineView.fit(
        const ClockSpan(0, 1, ClockUnit.progress),
        1024,
        margin: 12,
      );
      expect(v.xOf(0), closeTo(12, 1e-9));
      expect(v.xOf(1), closeTo(1012, 1e-9));
      expect(v.tOf(v.xOf(0.3)), closeTo(0.3, 1e-12));
      final panned = v.panBy(100);
      expect(panned.xOf(0), closeTo(112, 1e-9));
      final zoomed = v.zoomAbout(512, 2);
      expect(zoomed.pxPerUnit, closeTo(v.pxPerUnit * 2, 1e-9));
      expect(zoomed.tOf(512), closeTo(v.tOf(512), 1e-12));
    });
  });

  group('ruler', () {
    test('nice steps in display units (percent for progress)', () {
      // 1000 px for 0–1: 72 px is 7.2 %, so majors every 10 %.
      final v = const TimelineView(start: 0, pxPerUnit: 1000);
      final steps = rulerSteps(v, ClockUnit.progress);
      expect(steps.major, closeTo(0.1, 1e-12));
      // Seconds: 100 px per second → majors every 1 s.
      final s = rulerSteps(
        const TimelineView(start: 0, pxPerUnit: 100),
        ClockUnit.seconds,
      );
      expect(s.major, closeTo(1, 1e-12));
      // 30 px per second → 72 px is 2.4 s → majors every 5 s.
      expect(
        rulerSteps(
          const TimelineView(start: 0, pxPerUnit: 30),
          ClockUnit.seconds,
        ).major,
        closeTo(5, 1e-12),
      );
    });

    test('ticks cover the width; majors on multiples of the step', () {
      const v = TimelineView(start: 0, pxPerUnit: 1000);
      final ticks = rulerTicks(v, 500, ClockUnit.progress);
      expect(ticks.first.t, 0);
      expect(ticks.last.t, closeTo(0.5, 1e-9));
      final majors = ticks.where((t) => t.major).map((t) => t.t);
      expect(majors, [
        for (final m in [0.0, 0.1, 0.2, 0.3, 0.4, 0.5]) closeTo(m, 1e-9),
      ]);
    });

    test('labels', () {
      expect(formatClockValue(0.42, ClockUnit.progress), '42%');
      expect(formatClockValue(1.25, ClockUnit.seconds), '1.25 s');
      expect(formatClockValue(2, ClockUnit.seconds, step: 1), '2 s');
      expect(formatClockValue(-0.5, ClockUnit.signed), '−0.5');
      expect(formatClockValue(0.05, ClockUnit.progress, step: 0.05), '5%');
    });
  });

  group('snapping', () {
    test('nearest candidate within the threshold, else unchanged', () {
      expect(snapTime(0.49, [0, 0.5, 1], 0.02), (t: 0.5, target: 0.5));
      expect(snapTime(0.45, [0, 0.5, 1], 0.02), (t: 0.45, target: null));
      // The nearer of two in reach wins.
      expect(snapTime(0.507, [0.5, 0.51], 0.02).t, 0.51);
      // Exactly at the threshold still snaps.
      expect(snapTime(0.48, [0.5], 0.02).t, 0.5);
    });

    test('a drag snaps the grabbed keyframe to the playhead', () {
      const view = TimelineView(start: 0, pxPerUnit: 1000);
      const range = ClockSpan(0, 1, ClockUnit.progress);
      final r = keyframeDragDelta(
        grabbedT: 0.2,
        rawDelta: 0.297, // lands at 0.497, 3 px from the playhead at 0.5
        dragged: [0.2, 0.3],
        range: range,
        view: view,
        candidates: [0.5],
      );
      expect(r.delta, closeTo(0.3, 1e-12));
      expect(r.target, 0.5);
      // Shift: no snapping.
      final free = keyframeDragDelta(
        grabbedT: 0.2,
        rawDelta: 0.297,
        dragged: [0.2, 0.3],
        range: range,
        view: view,
        candidates: [0.5],
        snap: false,
      );
      expect(free.delta, closeTo(0.297, 1e-12));
      expect(free.target, isNull);
    });

    test('snap threshold is in pixels: zooming out widens it in time', () {
      const range = ClockSpan(0, 10, ClockUnit.seconds, openEnded: true);
      double delta(double px) => keyframeDragDelta(
        grabbedT: 1,
        rawDelta: 0.95,
        dragged: [1],
        range: range,
        view: TimelineView(start: 0, pxPerUnit: px),
        candidates: [2],
      ).delta;
      expect(delta(100), closeTo(1, 1e-12)); // 5 px away: snaps
      expect(delta(1000), closeTo(0.95, 1e-12)); // 50 px away: doesn't
    });

    test('the delta keeps every dragged keyframe inside the range', () {
      const range = ClockSpan(0, 1, ClockUnit.progress);
      expect(limitDelta(0.5, [0.2, 0.8], range), closeTo(0.2, 1e-12));
      expect(limitDelta(-0.5, [0.2, 0.8], range), closeTo(-0.2, 1e-12));
      const open = ClockSpan(0, 4, ClockUnit.seconds, openEnded: true);
      expect(limitDelta(10, [1], open), 10);
      // A limited delta reports no snap target.
      final r = keyframeDragDelta(
        grabbedT: 0.9,
        rawDelta: 0.2,
        dragged: [0.9],
        range: range,
        view: const TimelineView(start: 0, pxPerUnit: 1000),
        candidates: [1.1],
        thresholdPx: 50,
      );
      expect(r.delta, closeTo(0.1, 1e-12));
      expect(r.target, isNull);
    });

    test('candidates: playhead, other keyframes and minor ticks in view', () {
      final c = dragSnapCandidates(
        playhead: 0.33,
        others: [0.71],
        view: const TimelineView(start: 0, pxPerUnit: 1000),
        width: 100,
        unit: ClockUnit.progress,
      );
      expect(c.take(2), [0.33, 0.71]);
      // Minor ticks every 2 % across the 10 % in view.
      expect(c.skip(2).length, 6);
    });

    test('nudge steps', () {
      expect(nudgeStep(ClockUnit.progress), 0.01);
      expect(nudgeStep(ClockUnit.progress, big: true), closeTo(0.1, 1e-12));
      expect(nudgeStep(ClockUnit.seconds), 0.1);
      expect(nudgeStep(ClockUnit.seconds, big: true), closeTo(1, 1e-12));
    });
  });

  test('easing names and summaries', () {
    expect(easingName(const Easing.linear()), 'Linear');
    expect(
      easingName(const Easing.preset(EasingPreset.easeInOut)),
      'Ease in out',
    );
    expect(easingName(const Easing.steps(4)), 'Steps (4)');
    Keyframe k(double t, Easing e) =>
        Keyframe(id: '$t', t: t, value: const IrValue.number(0), easing: e);
    Track track(List<Keyframe> kfs) => Track(
      id: 't',
      target: 'n',
      property: 'opacity',
      clockId: 'c',
      keyframes: kfs,
    );
    expect(easingSummary(track([k(0, const Easing.linear())])), '—');
    // The last keyframe's easing starts no segment and is ignored.
    expect(
      easingSummary(
        track([
          k(0, const Easing.hold()),
          k(1, const Easing.hold()),
          k(2, const Easing.linear()),
        ]),
      ),
      'Hold',
    );
    expect(
      easingSummary(
        track([
          k(0, const Easing.hold()),
          k(1, const Easing.linear()),
          k(2, const Easing.linear()),
        ]),
      ),
      'Mixed',
    );
  });

  test('clock picker labels: the clock name, else derived', () {
    final doc = StageDocument.empty(ids: IdGenerator.seeded(1));
    expect(
      clockLabel(doc, const Clock.sceneScroll(id: 's', sceneId: 'x')),
      'Scene scroll',
    );
    expect(
      clockLabel(doc, const Clock.timeline(id: 't', duration: 4)),
      'Timeline · 4 s',
    );
    expect(
      clockLabel(
        doc,
        const Clock.timeline(id: 't', duration: 4, name: 'Intro'),
      ),
      'Intro',
    );
    expect(
      clockLabel(
        doc,
        const Clock.pointer(id: 'p', frameId: 'f', name: 'Hover'),
      ),
      'Hover',
    );
    expect(
      clockLabel(doc, const Clock.pointer(id: 'p', frameId: 'f')),
      'Pointer X · f',
    );
  });
}
