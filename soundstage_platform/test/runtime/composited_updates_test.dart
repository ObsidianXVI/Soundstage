import 'dart:typed_data';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// T0.6b: typed paint overrides reach the pixels, opacity and motion update
/// composited layers without re-recording pictures, and blended groups keep
/// their animated descendants inside one canvas layer.

const Size _viewport = Size(800, 600);

const ir.Breakpoint _bp = ir.Breakpoint(
  id: 'only',
  name: 'Only',
  minWidth: 0,
  designSize: ir.StageSize(width: 800, height: 600),
);

const ir.StageColor _red = ir.StageColor(r: 1, g: 0, b: 0);
const ir.StageColor _blue = ir.StageColor(r: 0, g: 0, b: 1);

ir.ShapeNode _box(
  String id, {
  double x = 0,
  double y = 0,
  double size = 100,
  ir.Appearance appearance = const ir.Appearance(
    fills: [ir.Paint.solid(id: 'f', color: ir.StageColor.black)],
  ),
}) => ir.ShapeNode(
  common: ir.NodeCommon(id: id, x: x, y: y, width: size, height: size),
  appearance: appearance,
);

ir.Track _track(
  String target,
  String property,
  List<(double, ir.IrValue)> kfs, {
  ir.Easing easing = const ir.Easing.linear(),
}) => ir.Track(
  id: '$target-$property',
  target: target,
  property: property,
  clockId: 'c',
  keyframes: [
    for (final (t, v) in kfs)
      ir.Keyframe(id: '$t', t: t, value: v, easing: easing),
  ],
);

ir.Track _num(String target, String property, double a, double b) => _track(
  target,
  property,
  [(0, ir.IrValue.number(a)), (1, ir.IrValue.number(b))],
);

/// One pinned scene (scrollLength 2: progress = scroll offset / 1200).
ir.StageDocument _doc(
  List<ir.Node> children,
  List<ir.Track> tracks, {
  ir.Appearance rootAppearance = const ir.Appearance(),
}) => ir.StageDocument(
  id: 'doc',
  breakpoints: const [_bp],
  baseBreakpointId: 'only',
  scenes: [
    ir.Scene(
      id: 's',
      kind: ir.SceneKind.pinned,
      scrollLength: 2,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 800, height: 600),
        appearance: rootAppearance,
        children: children,
      ),
      clocks: const [ir.Clock.sceneScroll(id: 'c', sceneId: 's')],
      tracks: tracks,
    ),
  ],
);

final GlobalKey _boundary = GlobalKey();

Future<StagePlayerController> _pump(
  WidgetTester tester,
  ir.StageDocument doc,
) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = _viewport;
  addTearDown(tester.view.reset);
  final c = StagePlayerController();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: StagePlayer(
          document: doc,
          viewportOverride: _viewport,
          controller: c,
          environment: const StageEnvironment(),
        ),
      ),
    ),
  );
  return c;
}

Future<void> _scrollTo(
  WidgetTester tester,
  StagePlayerController c,
  double y,
) async {
  c.scrollController!.jumpTo(y);
  await tester.pump();
}

/// The RGBA pixels of the whole player, as composited from its layers.
Future<(ByteData, int)> _capture(WidgetTester tester) async {
  final boundary =
      _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData();
    final width = image.width;
    image.dispose();
    return (bytes!, width);
  }))!;
}

Color _pixel((ByteData, int) img, int x, int y) {
  final (bytes, width) = img;
  final i = (y * width + x) * 4;
  return Color.fromARGB(
    bytes.getUint8(i + 3),
    bytes.getUint8(i),
    bytes.getUint8(i + 1),
    bytes.getUint8(i + 2),
  );
}

/// Every layer under [root], depth first.
List<Layer> _layers(Layer root) {
  final out = <Layer>[root];
  if (root is ContainerLayer) {
    var child = root.firstChild;
    while (child != null) {
      out.addAll(_layers(child));
      child = child.nextSibling;
    }
  }
  return out;
}

int _red8(Color c) => (c.r * 255).round();
int _blue8(Color c) => (c.b * 255).round();

void main() {
  testWidgets('an animated gradient stop colour reaches the layer output', (
    tester,
  ) async {
    const gradient = ir.Appearance(
      fills: [
        ir.Paint.gradient(
          id: 'g',
          stops: [
            ir.ColorStop(position: 0, color: _red),
            ir.ColorStop(position: 1, color: _red),
          ],
        ),
      ],
    );
    final c = await _pump(
      tester,
      _doc(
        [_box('grad', size: 200, appearance: gradient)],
        [
          _track('grad', 'fills.g.stops.0.color', [
            (0, const ir.IrValue.color(_red)),
            (1, const ir.IrValue.color(_blue)),
          ]),
        ],
      ),
    );
    final box = c.nodes!['grad']!;
    expect(box.appearanceOverrides, isNotNull);
    expect(identical(box.node, box.baseNode), isTrue);

    final atStart = _pixel(await _capture(tester), 100, 1);
    expect(_red8(atStart), greaterThan(240));
    expect(_blue8(atStart), lessThan(15));

    await _scrollTo(tester, c, 1200); // progress 1
    final atEnd = _capture(tester);
    final top = _pixel(await atEnd, 100, 1);
    final bottom = _pixel(await atEnd, 100, 198);
    expect(_blue8(top), greaterThan(240), reason: 'stop 0 is blue now');
    expect(_red8(top), lessThan(15));
    expect(_red8(bottom), greaterThan(240), reason: 'stop 1 is still red');
    expect(identical(box.node, box.baseNode), isTrue, reason: 'no node copy');
  });

  testWidgets(
    'scrolling an opacity/motion scene re-records no pictures for the '
    'animated nodes',
    (tester) async {
      final c = await _pump(
        tester,
        _doc(
          [
            _box('fade', x: 0, y: 0),
            _box('move', x: 0, y: 200),
            _box('still', x: 400, y: 0),
          ],
          [
            _num('fade', 'opacity', 0, 1),
            _num('move', 'motion.translateX', 0, 300),
            _num('move', 'motion.rotate', 0, 45),
            _num('move', 'motion.scaleY', 1, 2),
          ],
        ),
      );
      await _scrollTo(tester, c, 60);
      final fade = c.nodes!['fade']!;
      final move = c.nodes!['move']!;
      final root = c.nodes!['root']!;
      expect(fade.isRepaintBoundary, isTrue);
      expect(move.isRepaintBoundary, isTrue);

      final counts = [
        for (final b in [fade, move, root, c.nodes!['still']!])
          b.debugNodePaintCount,
      ];
      final allPaints = RenderStageBox.debugPaintCount;
      for (var y = 80.0; y <= 1200; y += 37) {
        await _scrollTo(tester, c, y);
        final p = y / 1200;

        // The node's own layers carry the animated values …
        final fadeLayer = fade.debugLayer! as TransformLayer;
        final opacityLayer = fadeLayer.firstChild! as OpacityLayer;
        expect(opacityLayer.alpha, (p * 255).round(), reason: 'y=$y');
        final moveLayer = move.debugLayer! as TransformLayer;
        expect(moveLayer.transform, move.paintTransform, reason: 'y=$y');
        expect(move.animatedSlot(RenderStageBox.slotTranslateX), p * 300);
      }
      // … and no stage node recorded a picture.
      expect([
        for (final b in [fade, move, root, c.nodes!['still']!])
          b.debugNodePaintCount,
      ], counts);
      expect(RenderStageBox.debugPaintCount, allPaints);

      // The composited output shows it: half-way, the fade box is half
      // transparent and the moved box has left its stored position.
      await _scrollTo(tester, c, 600);
      final img = await _capture(tester);
      expect(_pixel(img, 50, 50).a, closeTo(0.5, 0.01));
      expect(_pixel(img, 5, 295).a, 0, reason: 'moved away');
      expect(fade.debugNodePaintCount, counts[0]);
    },
  );

  testWidgets('paint-class typed tracks repaint only their own node', (
    tester,
  ) async {
    final c = await _pump(
      tester,
      _doc(
        [_box('tint'), _box('fade', x: 200)],
        [
          _track('tint', 'fills.f.color', [
            (0, const ir.IrValue.color(_red)),
            (1, const ir.IrValue.color(_blue)),
          ]),
          _num('fade', 'opacity', 0.2, 1),
        ],
      ),
    );
    await _scrollTo(tester, c, 60);
    final tint = c.nodes!['tint']!;
    final fade = c.nodes!['fade']!;
    final root = c.nodes!['root']!;
    final before = (
      tint.debugNodePaintCount,
      fade.debugNodePaintCount,
      root.debugNodePaintCount,
    );
    for (var y = 100.0; y <= 1100; y += 100) {
      await _scrollTo(tester, c, y);
    }
    expect(tint.debugNodePaintCount - before.$1, 11);
    expect(fade.debugNodePaintCount, before.$2);
    expect(root.debugNodePaintCount, before.$3);
  });

  group('blended groups', () {
    // `grp` blends (multiply) once its blendMode track passes 0.5; `kid`
    // (fill + stroke, so its opacity needs a layer) animates inside it, and
    // `free` animates outside it.
    ir.StageDocument blendDoc() => _doc(
      [
        ir.FrameNode(
          common: const ir.NodeCommon(id: 'grp', width: 300, height: 300),
          appearance: const ir.Appearance(
            fills: [ir.Paint.solid(id: 'f', color: ir.StageColor.white)],
          ),
          children: [
            _box(
              'kid',
              x: 50,
              y: 50,
              appearance: const ir.Appearance(
                fills: [ir.Paint.solid(id: 'f', color: _red)],
                strokes: ir.Stroke(
                  paints: [ir.Paint.solid(id: 's', color: ir.StageColor.black)],
                ),
              ),
            ),
          ],
        ),
        _box('free', x: 500),
      ],
      [
        _track('grp', 'blendMode', [
          (0, const ir.IrValue.enumValue('passThrough')),
          (0.5, const ir.IrValue.enumValue('multiply')),
        ]),
        _num('kid', 'opacity', 0.2, 0.8),
        _num('kid', 'motion.translateX', 0, 50),
        _track('kid', 'fills.f.color', [
          (0, const ir.IrValue.color(_red)),
          (1, const ir.IrValue.color(_blue)),
        ]),
        _num('free', 'opacity', 0.2, 0.8),
      ],
      // A yellow backdrop: multiplying removes all blue.
      rootAppearance: const ir.Appearance(
        fills: [
          ir.Paint.solid(id: 'y', color: ir.StageColor(r: 1, g: 1, b: 0)),
        ],
      ),
    );

    /// The container layers that may exist: the root's and `free`'s
    /// composited layers (a transform layer and its opacity layer each),
    /// plus `kid`'s and `grp`'s when they are boundaries.
    void expectNoStrayLayers(StagePlayerController c, String where) {
      final root = c.nodes!['root']!;
      final allowed = <Layer>{};
      for (final id in ['root', 'free', 'kid', 'grp']) {
        final b = c.nodes![id]!;
        if (!b.isRepaintBoundary) continue;
        final l = b.debugLayer!;
        allowed
          ..add(l)
          ..add(l.firstChild!);
      }
      final containers = _layers(
        root.debugLayer!,
      ).whereType<ContainerLayer>().toSet();
      expect(containers.difference(allowed), isEmpty, reason: where);
    }

    testWidgets('an animated child inside a blended group composites with '
        'the group', (tester) async {
      final c = await _pump(tester, blendDoc());
      await _scrollTo(tester, c, 120); // progress 0.1: passThrough
      final grp = c.nodes!['grp']! as RenderStageFrame;
      final kid = c.nodes!['kid']!;
      final free = c.nodes!['free']!;

      // Not blended yet: the animated child is its own boundary.
      expect(kid.inBlendGroup, isFalse);
      expect(kid.isRepaintBoundary, isTrue);
      expect(kid.debugLayer, isA<TransformLayer>());
      expect(grp.isRepaintBoundary, isTrue);
      expectNoStrayLayers(c, 'passThrough');

      // Multiply: the group is one canvas layer.
      await _scrollTo(tester, c, 720); // progress 0.6
      expect(grp.node.effectiveBlendMode, ir.BlendMode.multiply);
      expect(grp.isRepaintBoundary, isFalse, reason: 'blends itself');
      expect(kid.inBlendGroup, isTrue);
      expect(kid.isRepaintBoundary, isFalse);
      expect(kid.debugLayer, isNull);
      expect(free.isRepaintBoundary, isTrue);
      expectNoStrayLayers(c, 'multiply');

      // The root's opacity layer holds one picture (root, grp and kid,
      // the whole group) and then free's layer.
      final rootLayer = c.nodes!['root']!.debugLayer!;
      final content = rootLayer.firstChild! as ContainerLayer;
      final kids = <Layer>[];
      for (var l = content.firstChild; l != null; l = l.nextSibling) {
        kids.add(l);
      }
      expect(kids, hasLength(2));
      expect(kids.first, isA<PictureLayer>());
      expect(identical(kids.last, free.debugLayer), isTrue);

      // Animated values inside the group repaint with it, still with no
      // layers of their own.
      final kidPaints = kid.debugNodePaintCount;
      final grpPaints = grp.debugNodePaintCount;
      await _scrollTo(tester, c, 900);
      expect(kid.debugNodePaintCount, greaterThan(kidPaints));
      expect(grp.debugNodePaintCount, greaterThan(grpPaints));
      expect(kid.debugLayer, isNull);
      expectNoStrayLayers(c, 'multiply, animating');

      // At progress 0.75 the child (opacity 0.65, translated 37.5) is drawn
      // inside the white group, and the group multiplies onto the yellow
      // backdrop as one: no blue survives, and red is the group's red.
      final img = await _capture(tester);
      final p = _pixel(img, 137, 100);
      final fill =
          ir.evaluateTrack(
                _track('kid', 'fills.f.color', [
                  (0, const ir.IrValue.color(_red)),
                  (1, const ir.IrValue.color(_blue)),
                ]),
                0.75,
              )!
              as ir.ColorValue;
      final groupRed = 0.35 + 0.65 * fill.value.r;
      expect(p.a, closeTo(1, 0.01));
      expect(_blue8(p), lessThan(3), reason: 'multiplied by yellow');
      expect(_red8(p), closeTo(groupRed * 255, 3));

      // Back to passThrough: boundaries again.
      await _scrollTo(tester, c, 120);
      expect(kid.inBlendGroup, isFalse);
      expect(kid.isRepaintBoundary, isTrue);
      expect(grp.isRepaintBoundary, isTrue);
      expectNoStrayLayers(c, 'passThrough again');
    });

    testWidgets('a group blended from the start never composites its '
        'children', (tester) async {
      final c = await _pump(
        tester,
        _doc(
          [
            ir.FrameNode(
              common: const ir.NodeCommon(
                id: 'grp',
                width: 300,
                height: 300,
                blendMode: ir.BlendMode.screen,
              ),
              children: [
                ir.FrameNode(
                  common: const ir.NodeCommon(
                    id: 'inner',
                    width: 200,
                    height: 200,
                  ),
                  children: [_box('deep')],
                ),
              ],
            ),
          ],
          [
            _num('deep', 'opacity', 0.2, 0.8),
            _num('inner', 'motion.rotate', 0, 30),
          ],
        ),
      );
      await _scrollTo(tester, c, 300);
      for (final id in ['inner', 'deep']) {
        final b = c.nodes![id]!;
        expect(b.inBlendGroup, isTrue, reason: id);
        expect(b.isRepaintBoundary, isFalse, reason: id);
        expect(b.needsCompositing, isFalse, reason: id);
      }
      expect(c.nodes!['grp']!.needsCompositing, isFalse);
    });
  });
}
