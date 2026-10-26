// m4.md T4.6: the lite and static player tiers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

const _viewport = Size(800, 600);

ir.StageDocument _doc() => ir.StageDocument(
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
      posterClock: 0.25,
      root: frame('a-root', common('a-root', w: 800, h: 600)),
      clocks: const [
        ir.Clock.sceneScroll(id: 'sc', sceneId: 'a'),
        ir.Clock.pointer(id: 'pt', frameId: 'a-root'),
        ir.TimelineClock(id: 'tl', duration: 2),
      ],
    ),
    ir.Scene(
      id: 'b',
      kind: ir.SceneKind.pinned,
      scrollLength: 1,
      transitionIn: const ir.SceneTransition(
        kind: ir.SceneTransitionKind.crossfade,
        amount: 0.5,
      ),
      root: frame('b-root', common('b-root', w: 800, h: 600)),
      clocks: const [ir.Clock.sceneScroll(id: 'sc-b', sceneId: 'b')],
    ),
  ],
);

Future<StagePlayerController> _pump(WidgetTester tester, StageTier tier) async {
  setViewport(tester, _viewport);
  final controller = StagePlayerController();
  await tester.pumpWidget(
    MaterialApp(
      home: StagePlayer(document: _doc(), tier: tier, controller: controller),
    ),
  );
  await tester.pump();
  return controller;
}

StageRenderMode _envMode(WidgetTester tester) =>
    tester.widget<StageScope>(find.byType(StageScope).first).environment.mode;

void main() {
  test('tier names', () {
    expect(StageTier.parse('lite'), StageTier.lite);
    expect(StageTier.parse('static'), StageTier.static);
    expect(StageTier.parse(null), StageTier.full);
    expect(StageTier.parse('bogus'), StageTier.full);
  });

  test('poster clock values', () {
    final v = posterClockValues(_doc().scenes.first);
    expect(v, {'sc': 0.25, 'pt': 0, 'tl': 2});
    expect(posterClockValues(_doc().scenes.first, at: 0.8)['sc'], 0.8);
  });

  testWidgets('full: scenes scroll through their length', (tester) async {
    final c = await _pump(tester, StageTier.full);
    // a: 600 × 3, b: 600 × 2, minus one viewport and the half-viewport
    // crossfade overlap.
    expect(c.scrollController!.position.maxScrollExtent, 2100);
    expect(_envMode(tester), StageRenderMode.play);
  });

  testWidgets('lite: poster state held, one viewport per scene', (
    tester,
  ) async {
    final c = await _pump(tester, StageTier.lite);
    final a = c.animator!;
    expect(c.scrollController!.position.maxScrollExtent, 600);
    expect(a.clockValue('sc'), 0.25);
    expect(a.clockValue('tl'), 2, reason: 'reduced motion: at its end');
    c.scrollController!.jumpTo(300);
    await tester.pump();
    expect(a.clockValue('sc'), 0.25);
    a.pointerMoved(const Offset(700, 300));
    expect(a.clockValue('pt'), 0);
    expect(_envMode(tester), StageRenderMode.play);
    final mq = MediaQuery.of(tester.element(find.byType(StageScope).first));
    expect(mq.disableAnimations, isTrue);
  });

  testWidgets('static: frozen at the poster, not interactive', (tester) async {
    final c = await _pump(tester, StageTier.static);
    final a = c.animator!;
    expect(c.scrollController!.position.maxScrollExtent, 600);
    expect(a.clockValue('sc'), 0.25);
    expect(a.clockValue('tl'), 2);
    expect(a.isTicking, isFalse);
    expect(_envMode(tester), StageRenderMode.still);
    c.scrollController!.jumpTo(300);
    await tester.pump();
    expect(a.clockValue('sc'), 0.25);
  });

  testWidgets('switching tiers rebuilds the animator', (tester) async {
    setViewport(tester, _viewport);
    final controller = StagePlayerController();
    Widget app(StageTier t) => MaterialApp(
      home: StagePlayer(document: _doc(), tier: t, controller: controller),
    );
    await tester.pumpWidget(app(StageTier.static));
    await tester.pump();
    await tester.pumpWidget(app(StageTier.full));
    await tester.pump();
    expect(_envMode(tester), StageRenderMode.play);
    expect(controller.scrollController!.position.maxScrollExtent, 2100);
    controller.scrollController!.jumpTo(600);
    await tester.pump();
    expect(controller.animator!.clockValue('sc'), closeTo(0.5, 1e-9));
  });

  testWidgets('onSceneNear reports scenes entering the lazy window', (
    tester,
  ) async {
    setViewport(tester, _viewport);
    final near = <String>[];
    final controller = StagePlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: StagePlayer(
          document: _doc(),
          controller: controller,
          lazyWindow: 0,
          onSceneNear: near.add,
        ),
      ),
    );
    await tester.pump();
    expect(near, ['a']);
    controller.scrollController!.jumpTo(2000);
    await tester.pump();
    expect(near, ['a', 'b']);
    controller.scrollController!.jumpTo(0);
    await tester.pump();
    // Re-entering reports again (the chunk loader fetches once).
    expect(near, ['a', 'b', 'a']);
  });
}
