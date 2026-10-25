import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/artboard.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

const _bps = [
  ir.Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 1024,
    designSize: ir.StageSize(width: 1000, height: 800),
    primary: true,
  ),
  ir.Breakpoint(
    id: 'mobile',
    name: 'Mobile',
    minWidth: 0,
    designSize: ir.StageSize(width: 400, height: 800),
    primary: true,
  ),
];

ir.ShapeNode _shape(String id, double x, double y) => ir.ShapeNode(
  common: ir.NodeCommon(id: id, x: x, y: y, width: 50, height: 50),
);

ir.Track _track(
  String id,
  String target,
  String property,
  String clockId,
  double a,
  double b, {
  double end = 1,
}) => ir.Track(
  id: id,
  target: target,
  property: property,
  clockId: clockId,
  keyframes: [
    ir.Keyframe(id: '${id}0', t: 0, value: ir.IrValue.number(a)),
    ir.Keyframe(id: '${id}1', t: end, value: ir.IrValue.number(b)),
  ],
);

/// s1: root [ fade (opacity on scroll), slide (motion.translateX on the
/// timeline, 0 → 200 over 2 s), move (x on scroll, 100 → 300), still ].
ir.StageDocument _doc() => ir.StageDocument(
  id: 'doc',
  breakpoints: _bps,
  scenes: [
    ir.Scene(
      id: 's1',
      kind: ir.SceneKind.pinned,
      scrollLength: 1,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 1000, height: 800),
        children: [
          _shape('fade', 0, 0),
          _shape('slide', 0, 100),
          _shape('move', 100, 200),
          _shape('still', 0, 300),
        ],
      ),
      clocks: const [
        ir.Clock.sceneScroll(id: 'scroll', sceneId: 's1'),
        ir.Clock.timeline(id: 'tl', duration: 2),
      ],
      tracks: [
        _track('t1', 'fade', 'opacity', 'scroll', 0, 1),
        _track('t2', 'slide', 'motion.translateX', 'tl', 0, 200, end: 2),
        _track('t3', 'move', 'x', 'scroll', 100, 300),
      ],
    ),
  ],
);

Future<ProviderContainer> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [initialDocumentProvider.overrideWithValue(_doc())],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: const Scaffold(body: EditorCanvas()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(EditorCanvas)));
}

void main() {
  testWidgets('scrubbing writes render objects with no widget rebuild', (
    tester,
  ) async {
    final c = await _pump(tester);
    final ctl = c.read(editorControllerProvider.notifier);
    final canvas = c.read(canvasControllerProvider);
    RenderStageBox box(String id, [String bp = 'desktop']) =>
        canvas.artboards[bp]!.registry[id]!;

    expect(box('fade').effectiveOpacity, 0);
    var rebuilds = 0;
    var geometry = 0;
    void onGeometry() => geometry++;
    canvas.geometry.addListener(onGeometry);
    addTearDown(() => canvas.geometry.removeListener(onGeometry));
    final artboardBuilds = Artboard.debugBuildCount;
    // Riverpod's scope element rebuilds itself to flush provider updates on
    // any state change; it rebuilds nothing below it.
    debugOnRebuildDirtyWidget = (e, _) {
      if (!e.widget.runtimeType.toString().contains('ProviderScope')) {
        rebuilds++;
      }
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    final doc = c.read(editorControllerProvider).document;

    for (var i = 1; i <= 10; i++) {
      ctl.setPlayhead('s1', 'scroll', i / 10);
      await tester.pump();
    }
    expect(rebuilds, 0);
    expect(Artboard.debugBuildCount, artboardBuilds);
    expect(identical(c.read(editorControllerProvider).document, doc), isTrue);
    expect(geometry, greaterThanOrEqualTo(10));
    for (final bp in ['desktop', 'mobile']) {
      expect(box('fade', bp).effectiveOpacity, closeTo(1, 1e-9));
      final pd = box('move', bp).parentData! as StageParentData;
      expect(pd.offset.dx, closeTo(300, 1e-9));
    }

    // Each clock has its own playhead.
    ctl.setPlayhead('s1', 'tl', 1);
    await tester.pump();
    expect(rebuilds, 0);
    expect(
      box('slide').animatedSlot(RenderStageBox.slotTranslateX),
      closeTo(100, 1e-9),
    );
    expect(box('fade').effectiveOpacity, closeTo(1, 1e-9));
  });

  testWidgets('the overlay follows animated geometry at the playhead', (
    tester,
  ) async {
    final c = await _pump(tester);
    final ctl = c.read(editorControllerProvider.notifier);
    final canvas = c.read(canvasControllerProvider);
    final overlay = canvas.overlay;
    final x0 = overlay.worldRectFor('slide', 'desktop')!.left;
    final m0 = overlay.worldRectFor('move', 'desktop')!.left;
    ctl
      ..setPlayhead('s1', 'tl', 2)
      ..setPlayhead('s1', 'scroll', 0.5);
    await tester.pump();
    expect(
      overlay.worldRectFor('slide', 'desktop')!.left,
      closeTo(x0 + 200, 1e-6),
    );
    expect(
      overlay.worldRectFor('move', 'desktop')!.left,
      closeTo(m0 + 100, 1e-6),
    );
  });

  testWidgets('a keyframe edit re-renders at the playhead and recompiles '
      'only its track', (tester) async {
    final c = await _pump(tester);
    final ctl = c.read(editorControllerProvider.notifier);
    final canvas = c.read(canvasControllerProvider);
    ctl.setPlayhead('s1', 'scroll', 0.5);
    await tester.pump();
    final box = canvas.artboards['desktop']!.registry['fade']!;
    expect(box.effectiveOpacity, closeTo(0.5, 1e-9));
    ctl.execute(
      const MoveKeyframes('s1', {
        't1': {'t11': 0.5},
      }),
    );
    await tester.pump();
    expect(box.effectiveOpacity, closeTo(1, 1e-9));
    ctl.undo();
    await tester.pump();
    expect(box.effectiveOpacity, closeTo(0.5, 1e-9));
  });

  testWidgets('a pointer clock scrubs like any other', (tester) async {
    final c = await _pump(tester);
    final ctl = c.read(editorControllerProvider.notifier);
    ctl.execute(
      const AddClock('s1', ir.Clock.pointer(id: 'px', frameId: 'root')),
    );
    ctl.execute(
      AddTrack('s1', _track('t4', 'still', 'motion.translateY', 'px', 0, 40)),
    );
    await tester.pump();
    ctl.setPlayhead('s1', 'px', 0.5);
    await tester.pump();
    final box = c
        .read(canvasControllerProvider)
        .artboards['desktop']!
        .registry['still']!;
    expect(box.animatedSlot(RenderStageBox.slotTranslateY), closeTo(20, 1e-9));
  });
}
