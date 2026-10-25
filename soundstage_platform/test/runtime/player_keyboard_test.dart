// T2.7: keyboard movement in the player, and focus.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

const ir.Breakpoint _bp = ir.Breakpoint(
  id: 'only',
  name: 'Only',
  minWidth: 0,
  designSize: ir.StageSize(width: 800, height: 600),
);

ir.Scene _flow(String id, double height) => ir.Scene(
  id: id,
  root: ir.FrameNode(
    common: ir.NodeCommon(id: '$id-root', width: 800, height: height),
  ),
  clocks: [ir.Clock.sceneScroll(id: '$id-c', sceneId: id)],
);

ir.StageDocument _doc() => ir.StageDocument(
  id: 'doc',
  breakpoints: const [_bp],
  // Scene starts at 0, 3000, 6000; total 9000 over a 600 px viewport.
  scenes: [_flow('a', 3000), _flow('b', 3000), _flow('c', 3000)],
);

void main() {
  group('keyboardScrollTarget', () {
    double go(double offset, int dir, {List<double>? starts}) =>
        keyboardScrollTarget(
          offset: offset,
          viewport: 600,
          min: 0,
          max: 8400,
          sceneStarts: starts ?? const [0, 3000, 6000],
          direction: dir,
        );

    test('moves a viewport inside a long scene', () {
      expect(go(0, 1), 600);
      expect(go(1200, 1), 1800);
      expect(go(1800, -1), 1200);
    });

    test('snaps to a scene start it would cross', () {
      expect(go(2700, 1), 3000);
      expect(go(2400, 1), 3000);
      expect(go(3000, 1), 3600);
      expect(go(3300, -1), 3000);
      expect(go(3000, -1), 2400);
      expect(go(3100, -1), 3000);
    });

    test('clamps to the ends', () {
      expect(go(8200, 1), 8400);
      expect(go(100, -1), 0);
    });
  });

  group('in the player', () {
    Future<StagePlayerController> pump(WidgetTester tester) async {
      setViewport(tester, const Size(800, 600));
      final controller = StagePlayerController();
      await tester.pumpWidget(
        MaterialApp(
          home: StagePlayer(
            document: _doc(),
            mode: StageRenderMode.play,
            controller: controller,
          ),
        ),
      );
      await tester.pump();
      return controller;
    }

    Future<void> press(
      WidgetTester tester,
      LogicalKeyboardKey key, {
      bool shift = false,
    }) async {
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('page, space and arrow keys move a viewport and snap', (
      tester,
    ) async {
      final c = await pump(tester);
      final s = c.scrollController!;
      for (final k in [
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowDown,
      ]) {
        s.jumpTo(0);
        await press(tester, k);
        expect(s.offset, 600, reason: '$k');
      }
      s.jumpTo(2700);
      await press(tester, LogicalKeyboardKey.pageDown);
      expect(s.offset, 3000, reason: 'snaps to the start of scene b');
      await press(tester, LogicalKeyboardKey.pageDown);
      expect(s.offset, 3600);
      await press(tester, LogicalKeyboardKey.pageUp);
      expect(s.offset, 3000, reason: 'back to the start of scene b');
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(s.offset, 2400);
      await press(tester, LogicalKeyboardKey.space, shift: true);
      expect(s.offset, 1800);
    });

    testWidgets('Home and End go to the ends', (tester) async {
      final c = await pump(tester);
      final s = c.scrollController!;
      await press(tester, LogicalKeyboardKey.end);
      expect(s.offset, s.position.maxScrollExtent);
      await press(tester, LogicalKeyboardKey.home);
      expect(s.offset, 0);
    });

    testWidgets('movement is smooth: it takes frames to arrive', (
      tester,
    ) async {
      final c = await pump(tester);
      final s = c.scrollController!;
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(s.offset, inExclusiveRange(0, 600));
      await tester.pumpAndSettle();
      expect(s.offset, 600);
    });

    testWidgets('with reduced motion it is instant', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      final c = await pump(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pump();
      expect(c.scrollController!.offset, 600);
      await tester.sendKeyEvent(LogicalKeyboardKey.end);
      await tester.pump();
      expect(
        c.scrollController!.offset,
        c.scrollController!.position.maxScrollExtent,
      );
    });

    testWidgets('chords with Ctrl, Meta or Alt are not viewport moves', (
      tester,
    ) async {
      final c = await pump(tester);
      for (final mod in [
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.metaLeft,
        LogicalKeyboardKey.altLeft,
      ]) {
        await tester.sendKeyDownEvent(mod);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.sendKeyUpEvent(mod);
        await tester.pumpAndSettle();
        // Flutter's own shortcut may nudge it; the viewport step is ours.
        expect(c.scrollController!.offset, lessThan(600), reason: '$mod');
        c.scrollController!.jumpTo(0);
      }
    });
  });

  testWidgets('the player does not steal focus from the enter gate', (
    tester,
  ) async {
    setViewport(tester, const Size(800, 600));
    final doc = ir.StageDocument(
      id: 'doc',
      breakpoints: const [kMobile],
      scenes: [
        ir.Scene(id: 's', root: frame('r', common('r', w: 390, h: 844))),
      ],
    );
    final env = StageEnvironment.forDocument(doc);
    final controller = StagePlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: StageEnterGate(
          document: doc,
          environment: env,
          onEntered: controller.requestFocus,
          child: StagePlayer(
            document: doc,
            environment: env,
            controller: controller,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'StageEnterGate');
    // Space would scroll the story; here it enters the gate instead.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'StagePlayer');
  });
}
