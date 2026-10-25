import 'dart:convert';

import 'package:soundstage_platform/ir/ir.dart';

import 'bench_document.dart';

// The scrub benches' scene (scrub_bench.dart, timeline_bench.dart).

const List<String> _slotPaths = [
  'opacity',
  'motion.translateX',
  'motion.translateY',
  'motion.rotate',
  'motion.scaleX',
];

/// The 5,000-node bench scene (solid fills; see `canvas_drag_bench.dart`)
/// with a timeline clock and 200 mixed tracks: 100 slot (opacity,
/// motion.*), 50 fill colour, 25 corner radius, 25 layout (`x` of the free
/// layer's absolute nodes, else `width`). 150 run on the scroll clock, 50 on
/// the timeline.
StageDocument scrubBenchScene() {
  final doc = documentOfNodes(5000, scenes: 1, freeLayer: true);
  Object? solid(Object? j) {
    if (j is Map<String, dynamic>) {
      if (j['type'] == 'image' && j.containsKey('assetId')) {
        return {
          'type': 'solid',
          'id': j['id'],
          'color': {'r': 0.8, 'g': 0.8, 'b': 0.8, 'a': 1.0},
        };
      }
      return {for (final e in j.entries) e.key: solid(e.value)};
    }
    if (j is List) return [for (final e in j) solid(e)];
    return j;
  }

  final plain = StageDocument.fromJson(
    solid(jsonDecode(jsonEncode(doc.toJson()))) as Map<String, dynamic>,
  );
  final scene = plain.scenes.single;
  final scroll = scene.clocks.whereType<SceneScrollClock>().first.id;

  // Authored scene-level nodes (no instances' insides), by role.
  final any = <Node>[];
  final filled = <(Node, String)>[];
  final cornered = <Node>[];
  final free = <Node>[];
  void walk(Node n, {required bool inFree}) {
    if (!identical(n, scene.root)) any.add(n);
    final app = switch (n) {
      FrameNode(:final appearance) ||
      ShapeNode(:final appearance) => appearance,
      _ => null,
    };
    if (app != null) {
      cornered.add(n);
      final solidFill = app.fills.whereType<SolidPaint>().firstOrNull;
      if (solidFill != null) filled.add((n, solidFill.id));
    }
    if (inFree && n is ShapeNode) free.add(n);
    if (n is FrameNode) {
      final isFree = n.id.startsWith('free');
      for (final c in n.children) {
        walk(c, inFree: inFree || isFree);
      }
    }
  }

  walk(scene.root, inFree: false);
  Track track(int i, String target, String path, List<IrValue> values) => Track(
    id: 'b$i',
    target: target,
    property: path,
    clockId: i % 4 == 3 ? 'tl' : scroll,
    keyframes: [
      for (final (k, v) in values.indexed)
        Keyframe(
          id: 'b$i-$k',
          t: i % 4 == 3 ? k * 2.0 : k / (values.length - 1),
          value: v,
          easing: k.isEven
              ? const Easing.preset(EasingPreset.easeInOut)
              : const Easing.cubicBezier(0.2, 0.8, 0.3, 1.2),
        ),
    ],
  );
  IrValue n(double v) => IrValue.number(v);
  final tracks = <Track>[
    for (var i = 0; i < 100; i++)
      track(i, any[(i * 37) % any.length].id, _slotPaths[i % 5], [
        for (var k = 0; k < 4; k++)
          n(
            _slotPaths[i % 5] == 'opacity'
                ? (k.isEven ? 0.3 : 1)
                : _slotPaths[i % 5] == 'motion.scaleX'
                ? 1 + k * 0.1
                : k * 12.0,
          ),
      ]),
    for (var i = 0; i < 50; i++)
      track(
        100 + i,
        filled[(i * 53) % filled.length].$1.id,
        'fills.${filled[(i * 53) % filled.length].$2}.color',
        [
          for (var k = 0; k < 3; k++)
            IrValue.color(StageColor(r: k / 2, g: (i % 5) / 5, b: 1 - k / 2)),
        ],
      ),
    for (var i = 0; i < 25; i++)
      track(150 + i, cornered[(i * 71) % cornered.length].id, 'cornerRadius', [
        for (var k = 0; k < 3; k++)
          IrValue.cornerRadius(CornerRadius.uniform(k * 6.0)),
      ]),
    for (var i = 0; i < 25; i++)
      free.length > i
          ? track(175 + i, free[i].id, 'x', [
              for (var k = 0; k < 3; k++) n(free[i].common.x + k * 30),
            ])
          : track(175 + i, any[(i * 91) % any.length].id, 'opacity', [
              n(1),
              n(0.5),
            ]),
  ];
  return plain.copyWith(
    scenes: [
      scene.copyWith(
        clocks: [
          ...scene.clocks,
          const Clock.timeline(id: 'tl', duration: 6),
        ],
        tracks: tracks,
      ),
    ],
  );
}
