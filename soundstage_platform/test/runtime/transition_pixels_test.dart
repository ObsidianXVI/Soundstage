import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

ir.Scene _scene(String id, ir.StageColor color, {ir.SceneTransition? t}) =>
    ir.Scene(
      id: id,
      kind: ir.SceneKind.pinned,
      scrollLength: 1,
      transitionIn: t ?? const ir.SceneTransition(),
      root: ir.FrameNode(
        common: ir.NodeCommon(id: '$id-root', width: 100, height: 100),
        appearance: ir.Appearance(
          fills: [ir.Paint.solid(id: 'f', color: color)],
        ),
      ),
    );

Future<(GlobalKey, StagePlayerController)> _pump(
  WidgetTester tester,
  ir.SceneTransitionKind kind,
) async {
  setViewport(tester, const Size(100, 100));
  final doc = ir.StageDocument(
    id: 'd',
    breakpoints: const [
      ir.Breakpoint(
        id: 'bp',
        name: 'Bp',
        minWidth: 0,
        designSize: ir.StageSize(width: 100, height: 100),
      ),
    ],
    scenes: [
      _scene('a', ir.StageColor.white),
      _scene(
        'b',
        ir.StageColor.black,
        t: ir.SceneTransition(kind: kind, amount: 0.5),
      ),
    ],
  );
  final key = GlobalKey();
  final c = StagePlayerController();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: StagePlayer(
          document: doc,
          viewportOverride: const Size(100, 100),
          controller: c,
          environment: const StageEnvironment(),
        ),
      ),
    ),
  );
  await tester.pump();
  return (key, c);
}

Future<int> _red(WidgetTester tester, GlobalKey key, int x, int y) async {
  final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final data = await tester.runAsync(() async {
    final image = await b.toImage();
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  return data!.getUint8((y * 100 + x) * 4);
}

void main() {
  testWidgets('slide over: the incoming scene covers the outgoing one '
      'below its top edge', (tester) async {
    final (key, c) = await _pump(tester, ir.SceneTransitionKind.overlap);
    c.scrollController!.jumpTo(100); // a's pin ends; b's top at 50
    await tester.pump();
    expect(await _red(tester, key, 50, 25), 255); // a above
    expect(await _red(tester, key, 50, 75), 0); // b below
  });

  testWidgets('crossfade: halfway through, the two scenes mix evenly', (
    tester,
  ) async {
    final (key, c) = await _pump(tester, ir.SceneTransitionKind.crossfade);
    c.scrollController!.jumpTo(125); // b's top 25 below the top: half way
    await tester.pump();
    expect(await _red(tester, key, 50, 10), closeTo(128, 3));
    expect(await _red(tester, key, 50, 90), closeTo(128, 3));
    c.scrollController!.jumpTo(150);
    await tester.pump();
    expect(await _red(tester, key, 50, 50), 0);
  });
}
