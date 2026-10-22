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
    baseBreakpointId: 'd',
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

/// An animator over [slotTrackDocument] with every target bound to a
/// (detached) render object, as the registry would on attach.
({StageAnimator animator, List<RenderStageBox> boxes}) boundAnimator() {
  final resolved = slotTrackDocument();
  final registry = StageNodeRegistry();
  final animator = StageAnimator(registry: registry, vsync: _Vsync());
  final env = StageEnvironment(nodes: registry);
  final boxes = <RenderStageBox>[
    for (final child in resolved.scenes.single.root.children)
      RenderStageShape(
        node: child.node,
        environment: env,
        repaintBoundary: true,
      ),
  ];
  for (final b in boxes) {
    registry.attachNode(b);
  }
  animator.load(resolved);
  return (animator: animator, boxes: boxes);
}

/// The scroll progress of frame [i] of a back-and-forth sweep.
double sweep(int i, int period) {
  final p = i % (2 * period);
  return (p <= period ? p : 2 * period - p) / period;
}
