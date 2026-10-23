import 'package:flutter/rendering.dart' show PipelineOwner;
import 'package:flutter/scheduler.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// Shared setup for the animator benchmarks (architecture §18: animator
/// work per frame with 200 active tracks < 2 ms, zero allocations).

const List<ir.Easing> _easings = [
  ir.Easing.linear(),
  ir.Easing.preset(ir.EasingPreset.easeInOut),
  ir.Easing.cubicBezier(0.2, 0.8, 0.3, 1.2),
  ir.Easing.spring(stiffness: 180, damping: 12),
  ir.Easing.preset(ir.EasingPreset.easeOutBack),
  ir.Easing.steps(4),
];

const List<String> _slotPaths = [
  'motion.translateX',
  'motion.translateY',
  'motion.rotate',
  'motion.scaleX',
  'opacity',
];

ir.Track _numberTrack(int i, String target, String path) => ir.Track(
  id: 'n$i',
  target: target,
  property: path,
  clockId: 'c',
  keyframes: [
    for (var k = 0; k < 4; k++)
      ir.Keyframe(
        id: 'n$i-$k',
        t: k / 3,
        value: ir.IrValue.number(
          path == 'opacity' ? (k.isEven ? 0.2 : 1) : (k * 37 + i) % 200,
        ),
        easing: _easings[(i + k) % _easings.length],
      ),
  ],
);

ir.Track _colorTrack(int i, String target) => ir.Track(
  id: 'col$i',
  target: target,
  property: 'fills.f.color',
  clockId: 'c',
  keyframes: [
    for (var k = 0; k < 3; k++)
      ir.Keyframe(
        id: 'col$i-$k',
        t: k / 2,
        value: ir.IrValue.color(
          ir.StageColor(
            r: (i % 7) / 7,
            g: k / 2,
            b: 1 - (i % 5) / 5,
            a: 1 - k * 0.2,
          ),
        ),
        easing: _easings[(i + k) % _easings.length],
      ),
  ],
);

/// 200 evaluator-level tracks: 150 numeric (four keyframes, mixed easing)
/// and 50 colour (three keyframes, OKLab).
List<CompiledTrack> mixedCompiledTracks() => [
  for (var i = 0; i < 150; i++)
    CompiledTrack.compile(_numberTrack(i, 'n${i ~/ 5}', _slotPaths[i % 5])),
  for (var i = 0; i < 50; i++) CompiledTrack.compile(_colorTrack(i, 'n$i')),
];

/// A pinned scene with 40 shapes and 200 slot tracks (opacity and motion.*)
/// on one unsmoothed scroll clock, resolved.
ir.ResolvedDocument slotTrackDocument() {
  final nodes = [
    for (var i = 0; i < 40; i++)
      ir.ShapeNode(
        common: ir.NodeCommon(id: 'n$i', width: 40, height: 40),
        appearance: const ir.Appearance(
          fills: [ir.Paint.solid(id: 'f', color: ir.StageColor.black)],
        ),
      ),
  ];
  final doc = ir.StageDocument(
    id: 'bench',
    breakpoints: const [
      ir.Breakpoint(
        id: 'd',
        name: 'D',
        minWidth: 0,
        designSize: ir.StageSize(width: 800, height: 600),
      ),
    ],
    scenes: [
      ir.Scene(
        id: 's',
        kind: ir.SceneKind.pinned,
        scrollLength: 2,
        root: ir.FrameNode(
          common: const ir.NodeCommon(id: 'root', width: 800, height: 600),
          children: nodes,
        ),
        clocks: const [ir.Clock.sceneScroll(id: 'c', sceneId: 's')],
        tracks: [
          for (var i = 0; i < 200; i++)
            _numberTrack(i, 'n${i ~/ 5}', _slotPaths[i % 5]),
        ],
      ),
    ],
  );
  return ir.resolveDocument(doc);
}

class _Vsync implements TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

/// An animator over [slotTrackDocument] with every target attached to a
/// pipeline owner as a repaint boundary (as `StageSceneView` makes animated
/// nodes), so pushes take the composited-update path.
({StageAnimator animator, List<RenderStageBox> boxes}) boundAnimator() {
  final resolved = slotTrackDocument();
  final registry = StageNodeRegistry();
  final animator = StageAnimator(registry: registry, vsync: _Vsync());
  final env = StageEnvironment(nodes: registry);
  final owner = PipelineOwner();
  final boxes = <RenderStageBox>[
    for (final child in resolved.scenes.single.root.children)
      RenderStageShape(
        node: child.node,
        environment: env,
        repaintBoundary: true,
      ),
  ];
  for (final b in boxes) {
    b.attach(owner); // registers with the registry
  }
  animator.load(resolved);
  return (animator: animator, boxes: boxes);
}

/// The scroll progress of frame [i] of a back-and-forth sweep.
double sweep(int i, int period) {
  final p = i % (2 * period);
  return (p <= period ? p : 2 * period - p) / period;
}

// ---- Mixed paint tracks (T0.6b) ------------------------------------------------

/// The appearance every mixed-bench node carries, so every track path
/// exists on it.
const ir.Appearance _mixedAppearance = ir.Appearance(
  fills: [
    ir.Paint.solid(id: 'f', color: ir.StageColor.black),
    ir.Paint.gradient(
      id: 'g',
      stops: [
        ir.ColorStop(position: 0, color: ir.StageColor.black),
        ir.ColorStop(position: 1, color: ir.StageColor.white),
      ],
    ),
  ],
  strokes: ir.Stroke(
    paints: [ir.Paint.solid(id: 's', color: ir.StageColor.black)],
  ),
  effects: [ir.Effect.dropShadow(id: 'd')],
  cornerRadius: ir.CornerRadius.uniform(4),
);

/// The mixed track kinds, cycled: (path, keyframe value at keyframe k of
/// track i).
final List<(String, ir.IrValue Function(int i, int k))> _mixedKinds = [
  ('fills.f.color', (i, k) => ir.IrValue.color(_mixColor(i, k))),
  ('fills.g.stops.0.color', (i, k) => ir.IrValue.color(_mixColor(i + 3, k))),
  ('fills.g.stops.1.position', (i, k) => ir.IrValue.number(0.5 + k * 0.15)),
  ('effects.d.color', (i, k) => ir.IrValue.color(_mixColor(i + 5, k))),
  (
    'effects.d.offset',
    (i, k) => ir.IrValue.point(ir.StagePoint(x: k * 3.0, y: 4.0 + i % 7)),
  ),
  ('effects.d.blur', (i, k) => ir.IrValue.number(4.0 + k * 6)),
  (
    'cornerRadius',
    (i, k) => ir.IrValue.cornerRadius(
      k.isEven
          ? ir.CornerRadius.uniform(4.0 + k)
          : ir.CornerRadius.perCorner(tl: 2, tr: 8.0 + k, br: 4, bl: 16),
    ),
  ),
  ('opacity', (i, k) => ir.IrValue.number(k.isEven ? 0.3 : 1)),
  ('motion.translateX', (i, k) => ir.IrValue.number((k * 37.0 + i) % 200)),
  ('motion.rotate', (i, k) => ir.IrValue.number(k * 15.0)),
];

ir.StageColor _mixColor(int i, int k) =>
    ir.StageColor(r: (i % 7) / 7, g: k / 3, b: 1 - (i % 5) / 5, a: 1 - k * 0.1);

/// Paths of the 200 mixed tracks, in order.
List<String> get mixedTrackPaths => [
  for (var i = 0; i < 200; i++) _mixedKinds[i % _mixedKinds.length].$1,
];

/// A pinned scene with 20 shapes and 20 frames and 200 *mixed* tracks
/// (fill colours, gradient stops, shadow colour/offset/blur, corner radii,
/// opacity and motion; five per node) on one unsmoothed scroll clock.
ir.ResolvedDocument mixedTrackDocument() {
  final nodes = <ir.Node>[
    for (var i = 0; i < 40; i++)
      i.isEven
          ? ir.ShapeNode(
              common: ir.NodeCommon(id: 'n$i', width: 40, height: 40),
              appearance: _mixedAppearance,
            )
          : ir.FrameNode(
              common: ir.NodeCommon(id: 'n$i', width: 40, height: 40),
              appearance: _mixedAppearance,
            ),
  ];
  final doc = ir.StageDocument(
    id: 'bench',
    breakpoints: const [
      ir.Breakpoint(
        id: 'd',
        name: 'D',
        minWidth: 0,
        designSize: ir.StageSize(width: 800, height: 600),
      ),
    ],
    scenes: [
      ir.Scene(
        id: 's',
        kind: ir.SceneKind.pinned,
        scrollLength: 2,
        root: ir.FrameNode(
          common: const ir.NodeCommon(id: 'root', width: 800, height: 600),
          children: nodes,
        ),
        clocks: const [ir.Clock.sceneScroll(id: 'c', sceneId: 's')],
        tracks: [
          for (var i = 0; i < 200; i++)
            ir.Track(
              id: 'm$i',
              target: 'n${i ~/ 5}',
              property: _mixedKinds[i % _mixedKinds.length].$1,
              clockId: 'c',
              keyframes: [
                for (var k = 0; k < 4; k++)
                  ir.Keyframe(
                    id: 'm$i-$k',
                    t: k / 3,
                    value: _mixedKinds[i % _mixedKinds.length].$2(i, k),
                    easing: _easings[(i + k) % _easings.length],
                  ),
              ],
            ),
        ],
      ),
    ],
  );
  return ir.resolveDocument(doc);
}

/// An animator over [mixedTrackDocument] with every target attached to a
/// pipeline owner (repaint boundaries, as `StageSceneView` makes them), so
/// slot tracks take the composited-update path and paint tracks write typed
/// paint overrides.
({StageAnimator animator, List<RenderStageBox> boxes}) boundMixedAnimator() {
  final resolved = mixedTrackDocument();
  final registry = StageNodeRegistry();
  final animator = StageAnimator(registry: registry, vsync: _Vsync());
  final env = StageEnvironment(nodes: registry);
  final owner = PipelineOwner();
  final boxes = <RenderStageBox>[
    for (final child in resolved.scenes.single.root.children)
      switch (child.node) {
        final ir.FrameNode f => RenderStageFrame(
          node: f,
          environment: env,
          repaintBoundary: true,
        ),
        final n => RenderStageShape(
          node: n,
          environment: env,
          repaintBoundary: true,
        ),
      },
  ];
  for (final b in boxes) {
    b.attach(owner); // registers with the registry
  }
  animator.load(resolved);
  return (animator: animator, boxes: boxes);
}
