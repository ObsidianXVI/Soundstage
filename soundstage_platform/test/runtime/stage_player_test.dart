import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

const Size _viewport = Size(800, 600);

const ir.Breakpoint _bp = ir.Breakpoint(
  id: 'only',
  name: 'Only',
  minWidth: 0,
  designSize: ir.StageSize(width: 800, height: 600),
);

ir.ShapeNode _box(String id, {double w = 100, double h = 100}) => ir.ShapeNode(
  common: ir.NodeCommon(id: id, width: w, height: h),
  appearance: const ir.Appearance(
    fills: [ir.Paint.solid(id: 'f', color: ir.StageColor.black)],
  ),
);

ir.Track _track(
  String target,
  String property,
  String clockId,
  List<(double, double)> kfs, {
  ir.Easing easing = const ir.Easing.linear(),
}) => ir.Track(
  id: '$target-$property',
  target: target,
  property: property,
  clockId: clockId,
  keyframes: [
    for (final (t, v) in kfs)
      ir.Keyframe(id: '$t', t: t, value: ir.IrValue.number(v), easing: easing),
  ],
);

ir.Scene _pinned(
  String id, {
  double scrollLength = 2,
  List<ir.Node> children = const [],
  List<ir.Track> tracks = const [],
  List<ir.Clock>? clocks,
}) => ir.Scene(
  id: id,
  kind: ir.SceneKind.pinned,
  scrollLength: scrollLength,
  root: ir.FrameNode(
    common: ir.NodeCommon(id: '$id-root', width: 800, height: 600),
    children: children,
  ),
  clocks: clocks ?? [ir.Clock.sceneScroll(id: '$id-c', sceneId: id)],
  tracks: tracks,
);

ir.Scene _flow(String id, double height) => ir.Scene(
  id: id,
  root: ir.FrameNode(
    common: ir.NodeCommon(id: '$id-root', width: 800, height: height),
    children: [_box('$id-box')],
  ),
  clocks: [ir.Clock.sceneScroll(id: '$id-c', sceneId: id)],
);

ir.StageDocument _doc(List<ir.Scene> scenes) => ir.StageDocument(
  id: 'doc',
  breakpoints: const [_bp],
  baseBreakpointId: 'only',
  scenes: scenes,
);

/// flow A (400) · pinned P (scrollLength 2, extent 1800) · flow B (500).
ir.StageDocument _threeScenes({List<ir.Track> tracks = const []}) => _doc([
  _flow('a', 400),
  _pinned('p', children: [_box('p-box'), _box('p-wide')], tracks: tracks),
  _flow('b', 500),
]);

Future<StagePlayerController> _pump(
  WidgetTester tester,
  ir.StageDocument doc, {
  StageRenderMode mode = StageRenderMode.play,
  Map<String, double> clockOverrides = const {},
  StagePlayerController? controller,
}) async {
  final c = controller ?? StagePlayerController();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: StagePlayer(
        document: doc,
        mode: mode,
        viewportOverride: _viewport,
        clockOverrides: clockOverrides,
        controller: c,
        environment: const StageEnvironment(),
      ),
    ),
  );
  return c;
}

RenderSliverStageScene _sliver(WidgetTester tester, int index) => tester
    .renderObjectList<RenderSliverStageScene>(
      find.byType(SliverStageScene, skipOffstage: false),
    )
    .elementAt(index);

Future<void> _scrollTo(
  WidgetTester tester,
  StagePlayerController c,
  double y,
) async {
  c.scrollController!.jumpTo(y);
  await tester.pump();
}

double _stageTop(StagePlayerController c, String rootId) =>
    c.nodes![rootId]!.localToGlobal(Offset.zero).dy;

void main() {
  group('scene scroll math', () {
    test('pinned extent and progress at the pin boundaries', () {
      expect(pinnedSceneExtent(600, 2), 1800);
      expect(pinnedSceneExtent(600, -1), 600);
      expect(pinnedSceneProgress(0, 600, 2), 0); // before / at the pin
      expect(pinnedSceneProgress(600, 600, 2), 0.5); // inside
      expect(pinnedSceneProgress(1200, 600, 2), 1); // at the pin end
      expect(pinnedSceneProgress(1500, 600, 2), 1); // after
      expect(pinnedSceneProgress(0, 600, 0), 0);
      expect(pinnedSceneProgress(1, 600, 0), 1);
      expect(pinnedStageOffset(0, 600, 2), 0);
      expect(pinnedStageOffset(1200, 600, 2), 0);
      expect(pinnedStageOffset(1201, 600, 2), -1);
    });

    test('flow progress: top enters the bottom → bottom leaves the top', () {
      double p(double s, double remaining) => flowSceneProgress(
        scrollOffset: s,
        remainingPaintExtent: remaining,
        viewportExtent: 600,
        extent: 400,
      );
      expect(p(0, 0), 0); // below the viewport
      expect(p(0, 300), 0.3); // top half-way up the viewport
      expect(p(0, 600), 0.6); // top at the viewport top
      expect(p(200, 400), 0.8);
      expect(p(400, 0), 1); // bottom at the viewport top
    });
  });

  group('StagePlayer slivers', () {
    testWidgets('extents and progress around the pin', (tester) async {
      final c = await _pump(tester, _threeScenes());
      expect(_sliver(tester, 0).geometry!.scrollExtent, 400);
      expect(_sliver(tester, 1).geometry!.scrollExtent, 1800);
      expect(_sliver(tester, 2).geometry!.scrollExtent, 500);
      expect(
        c.scrollController!.position.maxScrollExtent,
        400 + 1800 + 500 - 600,
      );

      final p = _sliver(tester, 1);
      // Just before the pin: the stage is 1 px below the viewport top.
      await _scrollTo(tester, c, 399);
      expect(p.progress, 0);
      expect(_stageTop(c, 'p-root'), 1);
      // At the pin start.
      await _scrollTo(tester, c, 400);
      expect(p.progress, 0);
      expect(_stageTop(c, 'p-root'), 0);
      // Inside: held at the top while the clock runs.
      await _scrollTo(tester, c, 400 + 600);
      expect(p.progress, 0.5);
      expect(_stageTop(c, 'p-root'), 0);
      // At the pin end.
      await _scrollTo(tester, c, 400 + 1200);
      expect(p.progress, 1);
      expect(_stageTop(c, 'p-root'), 0);
      // Just after: it scrolls away normally.
      await _scrollTo(tester, c, 400 + 1201);
      expect(p.progress, 1);
      expect(_stageTop(c, 'p-root'), -1);

      // Flow scene A: its top is at the viewport top at 0.
      await _scrollTo(tester, c, 0);
      expect(_sliver(tester, 0).progress, closeTo(0.6, 1e-12));
      await _scrollTo(tester, c, 200);
      expect(_sliver(tester, 0).progress, closeTo(0.8, 1e-12));
      // Flow scene B starts at 2200: below the viewport until 1600.
      await _scrollTo(tester, c, 1600);
      expect(_sliver(tester, 2).progress, 0);
      await _scrollTo(tester, c, 1900);
      expect(_sliver(tester, 2).progress, closeTo(300 / 1100, 1e-12));
      expect(_stageTop(c, 'b-root'), 300);
    });

    testWidgets('scroll-driven values land in the same frame (oracle)', (
      tester,
    ) async {
      final t = _track(
        'p-box',
        'motion.translateY',
        'p-c',
        [(0, 0), (1, 300)],
        easing: const ir.Easing.preset(ir.EasingPreset.easeInOut),
      );
      final c = await _pump(tester, _threeScenes(tracks: [t]));
      for (final y in [400.0, 700.0, 1000.0, 1350.0, 1600.0]) {
        await _scrollTo(tester, c, y);
        final progress = _sliver(tester, 1).progress;
        final expected =
            (ir.evaluateTrack(t, progress)! as ir.NumberValue).value;
        final box = c.nodes!['p-box']!;
        expect(box.animatedSlot(RenderStageBox.slotTranslateY), expected);
        expect(box.localToGlobal(Offset.zero).dy, closeTo(expected, 1e-9));
      }
    });

    testWidgets('layout-class tracks relayout the node', (tester) async {
      final t = _track('p-wide', 'width', 'p-c', [(0, 100), (1, 500)]);
      final c = await _pump(tester, _threeScenes(tracks: [t]));
      await _scrollTo(tester, c, 400 + 600);
      expect(c.nodes!['p-wide']!.size.width, closeTo(300, 1e-9));
      expect(c.nodes!['p-wide']!.baseNode.common.width, 100);
      await _scrollTo(tester, c, 400 + 1200);
      expect(c.nodes!['p-wide']!.size.width, 500);
    });

    testWidgets('scrolling rebuilds no widgets and relayouts no stage nodes', (
      tester,
    ) async {
      final tracks = [
        _track('p-box', 'motion.translateY', 'p-c', [(0, 0), (1, 200)]),
        _track('p-box', 'opacity', 'p-c', [(0, 0.2), (1, 1)]),
        _track('p-wide', 'motion.rotate', 'p-c', [(0, 0), (1, 90)]),
      ];
      final c = await _pump(tester, _threeScenes(tracks: tracks));
      await _scrollTo(tester, c, 450);

      List<Widget> stageWidgets() => [
        for (final e in tester.allElements)
          if (e.widget is StageNodeWidget ||
              e.widget is StageSceneView ||
              e.widget is StageShapeWidget ||
              e.widget is StageFrameWidget)
            e.widget,
      ];
      final before = stageWidgets();
      expect(before, isNotEmpty);

      final rebuilt = <String>[];
      debugOnRebuildDirtyWidget = (e, _) =>
          rebuilt.add(e.widget.runtimeType.toString());
      final layouts = RenderStageBox.debugLayoutCount;
      final paints = RenderStageBox.debugPaintCount;
      final box = c.nodes!['p-box']!;
      final slots = <double>[];
      // Inside the pin range, short of the lazy-window boundary at 1000
      // (where flow A leaves and flow B enters).
      for (var y = 460.0; y < 1000; y += 13) {
        await _scrollTo(tester, c, y);
        slots.add(box.animatedSlot(RenderStageBox.slotTranslateY));
      }
      debugOnRebuildDirtyWidget = null;

      expect(rebuilt, isEmpty, reason: 'no element rebuilt while scrolling');
      final after = stageWidgets();
      expect(after.length, before.length);
      for (var i = 0; i < after.length; i++) {
        expect(identical(after[i], before[i]), isTrue);
      }
      expect(
        RenderStageBox.debugLayoutCount - layouts,
        0,
        reason: 'paint-class tracks never relayout',
      );
      expect(
        RenderStageBox.debugPaintCount - paints,
        0,
        reason: 'opacity and motion update composited layers, no re-record',
      );

      // Crossing the window boundary builds exactly the entering scene.
      debugOnRebuildDirtyWidget = (e, _) =>
          rebuilt.add(e.widget.runtimeType.toString());
      await _scrollTo(tester, c, 1010);
      debugOnRebuildDirtyWidget = null;
      expect(rebuilt..sort(), [
        'StageNodeWidget', // b-root
        'StageNodeWidget', // b-box
        'StageSceneView',
      ]);
      expect(slots.toSet().length, slots.length, reason: 'values moved');
    });
  });

  group('lazy scenes', () {
    testWidgets('only scenes within ±1 viewport build a stage', (tester) async {
      final doc = _doc([
        for (var i = 0; i < 8; i++) _pinned('s$i', scrollLength: 0),
      ]);
      final c = await _pump(tester, doc);
      Set<String> built() => {
        for (final e in tester.allElements)
          if (e.widget case StageSceneView(:final scene)) scene.id,
      };
      // Each scene is one viewport (600) tall.
      expect(built(), {'s0', 's1'});
      expect(c.nodes!['s0-root'], isNotNull);
      expect(c.nodes!['s2-root'], isNull);

      await _scrollTo(tester, c, 3 * 600);
      expect(built(), {'s2', 's3', 's4'});
      expect(c.nodes!['s0-root'], isNull, reason: 'unbuilt scenes detach');

      await _scrollTo(tester, c, 3 * 600 + 300);
      expect(built(), {'s2', 's3', 's4', 's5'});

      await _scrollTo(tester, c, 7 * 600);
      expect(built(), {'s6', 's7'});
    });
  });

  group('clocks in the player', () {
    testWidgets('edit mode freezes clocks at the overrides', (tester) async {
      final doc = _doc([
        _pinned(
          'p',
          children: [_box('p-box')],
          clocks: const [
            ir.Clock.sceneScroll(id: 'p-c', sceneId: 'p'),
            ir.Clock.timeline(
              id: 'tl',
              duration: 1,
              trigger: ir.TimelineTrigger.autoplay,
            ),
            ir.Clock.pointer(id: 'px', frameId: 'p-root'),
          ],
          tracks: [
            _track('p-box', 'opacity', 'p-c', [(0, 0), (1, 1)]),
            _track('p-box', 'motion.translateX', 'tl', [(0, 0), (1, 100)]),
            _track('p-box', 'motion.translateY', 'px', [(-1, -50), (1, 50)]),
          ],
        ),
        _flow('after', 600),
      ]);
      var c = await _pump(
        tester,
        doc,
        mode: StageRenderMode.edit,
        clockOverrides: const {'p-c': 0.25, 'tl': 0.5},
      );
      final box = c.nodes!['p-box']!;
      expect(box.animatedSlot(RenderStageBox.slotOpacity), 0.25);
      expect(box.animatedSlot(RenderStageBox.slotTranslateX), 50);
      expect(box.animatedSlot(RenderStageBox.slotTranslateY), 0);

      await _scrollTo(tester, c, 600);
      await tester.pump(const Duration(seconds: 1));
      expect(c.animator!.isTicking, isFalse);
      expect(box.animatedSlot(RenderStageBox.slotOpacity), 0.25);
      expect(box.animatedSlot(RenderStageBox.slotTranslateX), 50);

      // The editor moves its playhead.
      c = await _pump(
        tester,
        doc,
        mode: StageRenderMode.edit,
        clockOverrides: const {'p-c': 1, 'tl': 1},
        controller: c,
      );
      expect(box.animatedSlot(RenderStageBox.slotOpacity), 1);
      expect(box.animatedSlot(RenderStageBox.slotTranslateX), 100);
    });

    testWidgets('a timeline plays on scene enter and the ticker idles after', (
      tester,
    ) async {
      final doc = _doc([
        _flow('before', 1200),
        _pinned(
          'p',
          children: [_box('p-box')],
          clocks: const [ir.Clock.timeline(id: 'tl', duration: 0.5)],
          tracks: [
            _track('p-box', 'motion.translateX', 'tl', [(0, 0), (0.5, 100)]),
          ],
        ),
      ]);
      final c = await _pump(tester, doc);
      await tester.pump(const Duration(milliseconds: 200));
      expect(c.animator!.isTicking, isFalse, reason: 'not on screen yet');
      expect(c.clockValue('tl'), 0);

      await _scrollTo(tester, c, 700); // the pinned scene enters
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      final mid = c.clockValue('tl')!;
      expect(mid, inExclusiveRange(0.15, 0.25));
      final box = c.nodes!['p-box']!;
      expect(
        box.animatedSlot(RenderStageBox.slotTranslateX),
        closeTo(mid / 0.5 * 100, 1e-9),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(c.clockValue('tl'), 0.5);
      expect(c.animator!.isTicking, isFalse, reason: 'finished: idle');
    });

    testWidgets('a smoothed scroll clock lags, converges and stops', (
      tester,
    ) async {
      final doc = _doc([
        _pinned(
          'p',
          children: [_box('p-box')],
          clocks: const [
            ir.Clock.sceneScroll(id: 'p-c', sceneId: 'p', smoothing: 0.2),
          ],
          tracks: [
            _track('p-box', 'motion.translateY', 'p-c', [(0, 0), (1, 100)]),
          ],
        ),
        _flow('after', 600),
      ]);
      final c = await _pump(tester, doc);
      await _scrollTo(tester, c, 1200); // progress 1 at once
      expect(c.clockValue('p-c'), 0, reason: 'not yet followed');
      expect(c.animator!.isTicking, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
      final v = c.clockValue('p-c')!;
      expect(v, inExclusiveRange(0, 1));
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(c.clockValue('p-c'), 1);
      expect(
        c.nodes!['p-box']!.animatedSlot(RenderStageBox.slotTranslateY),
        100,
      );
      expect(c.animator!.isTicking, isFalse);
    });
  });
}
