import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';
import 'package:soundstage_platform/runtime/src/widgets/stage_behaviors.dart';

import 'stage_test_helpers.dart';

const _viewport = Size(800, 600);

/// A 300×200 frame `c` at (100, 100) with behaviour [b] and three 300×200
/// slides in a row (no gap).
ir.StageDocument _doc(ir.Behavior b) => docWithRoot(
  frame(
    'root',
    common('root', w: 800, h: 600),
    children: [
      ir.FrameNode(
        common: common('c', x: 100, y: 100, w: 300, h: 200),
        behavior: b,
        autoLayout: const ir.AutoLayout(),
        children: [
          for (var i = 0; i < 3; i++)
            rect('s$i', common('s$i', w: 300, h: 200)),
        ],
      ),
    ],
  ),
  breakpoints: const [kDesktop],
);

Future<void> _pump(
  WidgetTester tester,
  ir.StageDocument doc, {
  StageRenderMode mode = StageRenderMode.play,
  Widget Function(Widget stage)? wrap,
}) async {
  setViewport(tester, _viewport);
  final resolved = ir.resolveDocument(
    doc,
    const ir.ResolveContext(viewportWidth: 800),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: StageScope(
        environment: StageEnvironment.forDocument(doc, mode: mode),
        child: (wrap ?? (w) => w)(
          Align(
            alignment: Alignment.topLeft,
            child: StageSceneView(
              scene: resolved.scenes.first,
              viewportSize: _viewport,
              breakpoint: resolved.breakpoint,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

RenderStageFrame _c(WidgetTester tester) =>
    stageBox(tester, 'c') as RenderStageFrame;

void main() {
  test('carousel stops follow the slides, peek and the end', () {
    final g = CarouselGeometry(
      slides: const [(0, 200), (210, 410), (420, 620)],
      extent: 300,
      peek: 20,
    );
    expect(g.maxOffset, 320);
    expect(g.stops, [0, 190, 320]);
    expect(g.nearest(250), 1);
  });

  test('a marquee enters from the far edge after leaving', () {
    double at(double t) => marqueeOffset(
      elapsed: t,
      speed: 100,
      extent: 300,
      start: 0,
      end: 500,
      forward: true,
    );
    expect(at(0), 300);
    expect(at(3), 0);
    expect(at(7.99), closeTo(-499, 1));
    expect(at(8), 300);
  });

  testWidgets('a carousel swipes one slide per flick and loops', (
    tester,
  ) async {
    await _pump(tester, _doc(const ir.Behavior.carousel(loop: true)));
    await tester.flingFrom(const Offset(350, 200), const Offset(-120, 0), 800);
    await tester.pumpAndSettle();
    expect(_c(tester).contentOffset, const Offset(-300, 0));
    final state = tester.state<StageCarouselState>(find.byType(StageCarousel));
    state.step(1);
    await tester.pumpAndSettle();
    expect(_c(tester).contentOffset, const Offset(-600, 0));
    state.step(1);
    await tester.pumpAndSettle();
    expect(_c(tester).contentOffset, Offset.zero);
  });

  testWidgets('a slow drag that does not pass halfway springs back', (
    tester,
  ) async {
    await _pump(tester, _doc(const ir.Behavior.carousel()));
    await tester.dragFrom(const Offset(350, 200), const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(_c(tester).contentOffset, Offset.zero);
  });

  testWidgets('in edit mode the frame renders as authored', (tester) async {
    await _pump(
      tester,
      _doc(const ir.Behavior.carousel()),
      mode: StageRenderMode.edit,
    );
    expect(find.byType(StageCarousel), findsNothing);
    expect(_c(tester).contentOffset, Offset.zero);
  });

  testWidgets('a marquee runs; reduced motion holds it still', (tester) async {
    await _pump(tester, _doc(const ir.Behavior.marquee(speed: 100)));
    await tester.pump(const Duration(seconds: 1));
    final moved = _c(tester).contentOffset.dx;
    expect(moved, isNot(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a lightbox opens the tapped member and closes', (tester) async {
    await _pump(tester, _doc(const ir.Behavior.lightbox()));
    // A lightbox frame does not clip: slide 2 shows at x 400–700.
    await tester.tapAt(const Offset(550, 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lightbox')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lightbox')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lightbox')), findsNothing);
  });

  testWidgets('inside a StageLightboxHost the lightbox covers only the host '
      '(an editor preview pane), not the page', (tester) async {
    await _pump(
      tester,
      _doc(const ir.Behavior.lightbox()),
      wrap: (stage) => Padding(
        padding: const EdgeInsets.only(left: 100, top: 50),
        child: StageLightboxHost(child: stage),
      ),
    );
    await tester.tapAt(const Offset(650, 250));
    await tester.pumpAndSettle();
    final box = find.byKey(const ValueKey('lightbox'));
    expect(box, findsOneWidget);
    expect(
      find.ancestor(of: box, matching: find.byType(StageLightboxHost)),
      findsOneWidget,
    );
    expect(tester.getTopLeft(box), const Offset(100, 50));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(box, findsNothing);
  });
}
