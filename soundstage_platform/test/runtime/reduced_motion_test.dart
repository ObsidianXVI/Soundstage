// T2.7: `prefers-reduced-motion` (MediaQuery.disableAnimations). Scroll
// tracks still map to the scroll position with smoothing off, autoplay and
// sceneEnter timelines jump to their end state, audio is unaffected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

ir.TimelineClock _tl({
  ir.TimelineLoop loop = ir.TimelineLoop.none,
  ir.TimelineTrigger trigger = ir.TimelineTrigger.autoplay,
  double rate = 1,
}) => ir.TimelineClock(
  id: 'tl',
  duration: 2,
  loop: loop,
  rate: rate,
  trigger: trigger,
);

void main() {
  group('timeline source', () {
    test('autoplay none jumps to its end and stays', () {
      final s = StageTimelineSource(_tl())..reducedMotionChanged(reduced: true);
      expect(s.value, 2);
      expect(s.isPlaying, isFalse);
      expect(s.isActive, isFalse);
      s.advance(1);
      expect(s.value, 2);
    });

    test('a negative rate ends at 0', () {
      final s = StageTimelineSource(_tl(rate: -1))
        ..reducedMotionChanged(reduced: true);
      expect(s.value, 0);
      expect(s.isPlaying, isFalse);
    });

    test('loops rest at their start', () {
      for (final loop in [ir.TimelineLoop.loop, ir.TimelineLoop.pingPong]) {
        final s = StageTimelineSource(_tl(loop: loop))
          ..reducedMotionChanged(reduced: true);
        expect(s.isPlaying, isFalse, reason: '$loop');
        expect(s.value, 0, reason: '$loop');
      }
    });

    test('sceneEnter ends at once and does not play on entering', () {
      final s = StageTimelineSource(_tl(trigger: ir.TimelineTrigger.sceneEnter))
        ..reducedMotionChanged(reduced: true)
        ..sceneVisibilityChanged(visible: true);
      expect(s.value, 2);
      expect(s.isPlaying, isFalse);
    });

    test('interaction timelines are left alone', () {
      final s = StageTimelineSource(
        _tl(trigger: ir.TimelineTrigger.interaction),
      )..reducedMotionChanged(reduced: true);
      expect(s.value, 0);
      s.play();
      expect(s.isPlaying, isTrue);
    });

    test('switching it off restarts autoplay', () {
      final s = StageTimelineSource(_tl())
        ..reducedMotionChanged(reduced: true)
        ..reducedMotionChanged(reduced: false);
      expect(s.isPlaying, isTrue);
      expect(s.value, 0);
    });
  });

  group('in the player', () {
    const viewport = Size(800, 600);

    ir.StageDocument doc() => ir.StageDocument(
      id: 'doc',
      breakpoints: const [
        ir.Breakpoint(
          id: 'only',
          name: 'Only',
          minWidth: 0,
          designSize: ir.StageSize(width: 800, height: 600),
        ),
      ],
      scenes: [
        ir.Scene(
          id: 'a',
          kind: ir.SceneKind.pinned,
          scrollLength: 2,
          root: frame('a-root', common('a-root', w: 800, h: 600)),
          clocks: [
            const ir.Clock.sceneScroll(id: 'sc', sceneId: 'a', smoothing: 0.5),
            _tl(),
          ],
        ),
      ],
    );

    Future<StagePlayerController> pump(
      WidgetTester tester, {
      required bool reduced,
    }) async {
      setViewport(tester, viewport);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          FakeAccessibilityFeatures(disableAnimations: reduced);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final controller = StagePlayerController();
      await tester.pumpWidget(
        MaterialApp(
          home: StagePlayer(document: doc(), controller: controller),
        ),
      );
      await tester.pump();
      return controller;
    }

    testWidgets('normally the timeline plays and the scroll clock eases', (
      tester,
    ) async {
      final c = await pump(tester, reduced: false);
      final a = c.animator!;
      expect(a.clockValue('tl'), lessThan(2));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(a.clockValue('tl'), greaterThan(0));
      expect(a.clockValue('tl'), lessThan(2));
      c.scrollController!.jumpTo(600);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      final raw = 600 / 1200;
      expect(a.clockValue('sc'), lessThan(raw), reason: 'smoothed');
    });

    testWidgets('reduced: the timeline is at its end, smoothing is off', (
      tester,
    ) async {
      final c = await pump(tester, reduced: true);
      final a = c.animator!;
      expect(a.reducedMotion, isTrue);
      expect(a.clockValue('tl'), 2);
      expect(a.isTicking, isFalse);
      c.scrollController!.jumpTo(600);
      await tester.pump();
      // The scroll clock follows the scroll position exactly.
      expect(a.clockValue('sc'), closeTo(600 / 1200, 1e-9));
    });

    testWidgets('toggling the setting live takes effect', (tester) async {
      final c = await pump(tester, reduced: false);
      final a = c.animator!;
      expect(a.reducedMotion, isFalse);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      await tester.pump();
      expect(a.reducedMotion, isTrue);
      expect(a.clockValue('tl'), 2);
    });
  });
}
