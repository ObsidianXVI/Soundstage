import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

const Size _viewport = Size(800, 600);

const _bps = [
  ir.Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 600,
    designSize: ir.StageSize(width: 800, height: 600),
    primary: true,
  ),
  ir.Breakpoint(
    id: 'mobile',
    name: 'Mobile',
    minWidth: 0,
    designSize: ir.StageSize(width: 400, height: 600),
    primary: true,
  ),
];

ir.ShapeNode _box(String id) => ir.ShapeNode(
  common: ir.NodeCommon(id: id, width: 100, height: 100),
  appearance: const ir.Appearance(
    fills: [ir.Paint.solid(id: 'f', color: ir.StageColor.black)],
  ),
);

ir.Track _track(
  String id,
  String target,
  String property,
  String clockId,
  List<(double, double)> kfs, {
  List<String>? breakpoints,
}) => ir.Track(
  id: id,
  target: target,
  property: property,
  clockId: clockId,
  breakpoints: breakpoints,
  keyframes: [
    for (final (i, (t, v)) in kfs.indexed)
      ir.Keyframe(id: '$id$i', t: t, value: ir.IrValue.number(v)),
  ],
);

ir.StageDocument _doc(List<ir.Track> tracks) => ir.StageDocument(
  id: 'doc',
  breakpoints: _bps,
  scenes: [
    ir.Scene(
      id: 'p',
      kind: ir.SceneKind.pinned,
      scrollLength: 1,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 800, height: 600),
        children: [_box('a'), _box('b'), _box('c')],
      ),
      clocks: const [
        ir.Clock.sceneScroll(id: 'scroll', sceneId: 'p'),
        ir.Clock.timeline(id: 'tl', duration: 2),
        ir.Clock.pointer(id: 'px', frameId: 'root'),
      ],
      tracks: tracks,
    ),
  ],
);

Future<StagePlayerController> _pump(
  WidgetTester tester,
  ir.StageDocument doc,
  Map<String, double> clocks, {
  StagePlayerController? controller,
}) async {
  final c = controller ?? StagePlayerController();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: StagePlayer(
        document: doc,
        mode: StageRenderMode.edit,
        viewportOverride: _viewport,
        clockOverrides: clocks,
        controller: c,
        environment: const StageEnvironment(),
      ),
    ),
  );
  return c;
}

double _slot(StagePlayerController c, String id, int slot) =>
    c.nodes![id]!.animatedSlot(slot);

void main() {
  testWidgets('every clock kind takes its playhead in edit mode', (
    tester,
  ) async {
    final doc = _doc([
      _track('t1', 'a', 'opacity', 'scroll', [(0, 0), (1, 1)]),
      _track('t2', 'a', 'motion.translateX', 'tl', [(0, 0), (2, 100)]),
      _track('t3', 'a', 'motion.translateY', 'px', [(-1, -50), (1, 50)]),
    ]);
    final c = await _pump(tester, doc, const {
      'scroll': 0.5,
      'tl': 1,
      'px': -0.5,
    });
    expect(_slot(c, 'a', RenderStageBox.slotOpacity), 0.5);
    expect(_slot(c, 'a', RenderStageBox.slotTranslateX), 50);
    expect(_slot(c, 'a', RenderStageBox.slotTranslateY), -25);
  });

  testWidgets('changing one playhead writes render objects directly', (
    tester,
  ) async {
    final doc = _doc([
      _track('t1', 'a', 'opacity', 'scroll', [(0, 0), (1, 1)]),
      _track('t2', 'b', 'x', 'tl', [(0, 0), (2, 200)]),
    ]);
    final c = await _pump(tester, doc, const {});
    final animator = c.animator!;
    animator.clockOverrides = const {'scroll': 0.25, 'tl': 1};
    await tester.pump();
    expect(_slot(c, 'a', RenderStageBox.slotOpacity), 0.25);
    // A layout-class property relaid out the node.
    final b = c.nodes!['b']!;
    expect((b.parentData! as StageParentData).offset.dx, 100);
  });

  testWidgets('a reload recompiles only the edited tracks', (tester) async {
    final doc = _doc([
      _track('t1', 'a', 'opacity', 'scroll', [(0, 0), (1, 1)]),
      _track('t2', 'b', 'opacity', 'scroll', [(0, 1), (1, 0)]),
      _track('t3', 'c', 'x', 'scroll', [(0, 0), (1, 100)]),
    ]);
    final clocks = const {'scroll': 0.5};
    final c = await _pump(tester, doc, clocks);
    final animator = c.animator!;
    expect(animator.compileCount, 3);

    // Edit t2's keyframes.
    final edited = ir.moveKeyframes(doc, 'p', {
      't2': {'t21': 0.5},
    }).document;
    await _pump(tester, edited, clocks, controller: c);
    expect(identical(c.animator, animator), isTrue);
    expect(animator.compileCount, 4);
    expect(_slot(c, 'a', RenderStageBox.slotOpacity), 0.5);
    expect(_slot(c, 'b', RenderStageBox.slotOpacity), 0);

    // A property edit elsewhere recompiles nothing.
    final moved = ir
        .updateNode(
          edited,
          'a',
          (n) => n.copyWith(common: n.common.copyWith(y: 40)),
        )
        .document;
    await _pump(tester, moved, clocks, controller: c);
    expect(animator.compileCount, 5, reason: 'only t1 (its target changed)');
    expect(_slot(c, 'a', RenderStageBox.slotOpacity), 0.5);

    // Removing a track resets its slot; removing a node-level track restores
    // the static value.
    final removed = ir.removeTracks(moved, 'p', ['t2', 't3']).document;
    await _pump(tester, removed, clocks, controller: c);
    expect(_slot(c, 'b', RenderStageBox.slotOpacity), isNaN);
    final box = c.nodes!['c']!;
    expect((box.parentData! as StageParentData).offset.dx, 0);
    expect(animator.trackCount, 1);
  });

  testWidgets('a breakpoint-specific track wins in the runtime too', (
    tester,
  ) async {
    final doc = _doc([
      _track('all', 'a', 'opacity', 'scroll', [(0, 0), (1, 1)]),
      _track(
        'mob',
        'a',
        'opacity',
        'scroll',
        [(0, 1), (1, 0)],
        breakpoints: ['mobile'],
      ),
    ]);
    final c = StagePlayerController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StagePlayer(
          document: doc,
          mode: StageRenderMode.edit,
          viewportOverride: const Size(400, 600),
          clockOverrides: const {'scroll': 0.25},
          controller: c,
          environment: const StageEnvironment(),
        ),
      ),
    );
    expect(c.animator!.trackCount, 1);
    expect(_slot(c, 'a', RenderStageBox.slotOpacity), 0.75);
    expect(
      ir.evaluateTrack(doc.scenes.single.tracks[1], 0.25),
      const ir.IrValue.number(0.75),
    );
  });
}
