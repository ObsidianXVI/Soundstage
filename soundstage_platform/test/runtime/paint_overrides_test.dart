import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// Typed paint overrides (T0.6b) must render exactly what the registry path
/// renders: for every typed property, the appearance as painted
/// (`StageAppearanceOverrides.apply` over the resolved node) equals the
/// node with the oracle's value (`ir.evaluateTrack`) written through the
/// property registry.

const ir.Appearance _base = ir.Appearance(
  fills: [
    ir.Paint.solid(id: 's', color: ir.StageColor(r: .2, g: .4, b: .6)),
    ir.Paint.gradient(
      id: 'g',
      stops: [
        ir.ColorStop(position: 0, color: ir.StageColor.black),
        ir.ColorStop(position: .4, color: ir.StageColor(r: 1, g: 0, b: 0)),
        ir.ColorStop(position: 1, color: ir.StageColor.white),
      ],
    ),
    ir.Paint.image(id: 'i', assetId: 'a', opacity: .5),
  ],
  strokes: ir.Stroke(
    paints: [
      ir.Paint.solid(id: 's', color: ir.StageColor.black),
      ir.Paint.gradient(
        id: 'g',
        stops: [
          ir.ColorStop(position: 0, color: ir.StageColor.black),
          ir.ColorStop(position: 1, color: ir.StageColor.white),
        ],
      ),
    ],
    weight: ir.StrokeWeight.perSide(top: 1, right: 2, bottom: 3, left: 4),
  ),
  effects: [
    ir.Effect.dropShadow(id: 'd'),
    ir.Effect.innerShadow(id: 'n', spread: 2),
    ir.Effect.layerBlur(id: 'l'),
    ir.Effect.backgroundBlur(id: 'b'),
  ],
  cornerRadius: ir.CornerRadius.perCorner(tl: 1, tr: 2, br: 3, bl: 4),
  cornerSmoothing: .3,
);

const ir.ShapeNode _shape = ir.ShapeNode(
  common: ir.NodeCommon(id: 'n', width: 100, height: 80),
  appearance: _base,
);

/// Typed paths and the value kind of their keyframes. Includes paths whose
/// target is absent or of the wrong kind (the registry ignores the write;
/// so must the override).
const Map<String, String> _paths = {
  'fills.s.color': 'color',
  'fills.s.opacity': 'number',
  'fills.g.opacity': 'number',
  'fills.i.opacity': 'number',
  'fills.g.stops.0.color': 'color',
  'fills.g.stops.1.position': 'unit',
  'fills.g.stops.2.color': 'color',
  'fills.g.stops.7.color': 'color', // no such stop
  'fills.s.stops.0.color': 'color', // not a gradient
  'fills.g.color': 'color', // not a solid
  'fills.missing.color': 'color', // no such paint
  'strokes.paints.s.color': 'color',
  'strokes.paints.g.stops.1.color': 'color',
  'strokes.paints.g.opacity': 'number',
  'strokes.weight': 'strokeWeight',
  'strokes.weight.top': 'number',
  'strokes.weight.left': 'number',
  'effects.d.color': 'color',
  'effects.n.color': 'color',
  'effects.d.offset': 'point',
  'effects.n.offset': 'point',
  'effects.d.blur': 'number',
  'effects.n.blur': 'number',
  'effects.l.blur': 'number',
  'effects.b.blur': 'number',
  'effects.l.radius': 'number',
  'effects.b.radius': 'number',
  'effects.d.radius': 'number', // shadows have no radius
  'effects.d.spread': 'number',
  'effects.n.spread': 'number',
  'effects.l.color': 'color', // blurs have no colour
  'cornerRadius': 'cornerRadius',
  'cornerRadius.tl': 'number',
  'cornerRadius.br': 'number',
  'cornerSmoothing': 'unit',
};

class _Gen {
  _Gen(int seed) : r = math.Random(seed);
  final math.Random r;

  double d([double lo = -50, double hi = 50]) =>
      lo + r.nextDouble() * (hi - lo);
  double u() => r.nextDouble();
  bool chance(double p) => r.nextDouble() < p;

  ir.Easing easing() => switch (r.nextInt(5)) {
    0 => const ir.Easing.linear(),
    1 => ir.Easing.cubicBezier(u(), d(-1, 2), u(), d(-1, 2)),
    2 => const ir.Easing.spring(stiffness: 180, damping: 12),
    3 => ir.Easing.steps(1 + r.nextInt(4)),
    _ => const ir.Easing.hold(),
  };

  ir.IrValue value(String kind) => switch (kind) {
    'number' => ir.IrValue.number(d(0, 40)),
    'unit' => ir.IrValue.number(u()),
    'color' => ir.IrValue.color(
      ir.StageColor(r: u(), g: u(), b: u(), a: chance(.4) ? u() : 1),
    ),
    'point' => ir.IrValue.point(ir.StagePoint(x: d(), y: d())),
    'cornerRadius' => ir.IrValue.cornerRadius(
      chance(.5)
          ? ir.CornerRadius.uniform(d(0, 40))
          : ir.CornerRadius.perCorner(
              tl: d(0, 40),
              tr: d(0, 40),
              br: d(0, 40),
              bl: d(0, 40),
            ),
    ),
    'strokeWeight' => ir.IrValue.strokeWeight(
      chance(.5)
          ? ir.StrokeWeight.uniform(d(0, 10))
          : ir.StrokeWeight.perSide(
              top: d(0, 10),
              right: d(0, 10),
              bottom: d(0, 10),
              left: d(0, 10),
            ),
    ),
    _ => throw ArgumentError(kind),
  };

  ir.Track track(String path, String kind, {String id = 't'}) {
    final n = 1 + r.nextInt(5);
    return ir.Track(
      id: id,
      target: 'n',
      property: path,
      clockId: 'c',
      keyframes: [
        for (var i = 0; i < n; i++)
          ir.Keyframe(
            id: '$id$i',
            t: (u() * 10).round() / 10,
            value: value(kind),
            easing: easing(),
          ),
      ],
    );
  }
}

List<double> _clockValues(_Gen g, ir.Track track) => [
  for (var i = -2; i <= 52; i++) i / 50,
  for (var i = 52; i >= -2; i -= 3) i / 50,
  for (var i = 0; i < 20; i++) g.d(-0.2, 1.2),
  for (final k in track.keyframes) k.t,
];

/// [tracks] bound as typed channels on a fresh override store.
(StageAppearanceOverrides, List<(CompiledTrack, StageAppearanceChannel)>) _bind(
  List<ir.Track> tracks,
) {
  final o = StageAppearanceOverrides();
  final bound = [
    for (final t in tracks)
      (CompiledTrack.compile(t), o.add(StageAppearancePath.parse(t.property)!)),
  ];
  return (o, bound);
}

/// The registry path: each track's oracle value written in order.
ir.Appearance _oracle(ir.ShapeNode base, List<ir.Track> tracks, double t) {
  ir.Node n = base;
  for (final track in tracks) {
    final v = ir.evaluateTrack(track, t);
    final match = ir.PropertyRegistry.standard.lookup(track.property)!;
    if (v != null) n = match.set(n, v);
  }
  return (n as ir.ShapeNode).appearance;
}

void _expectSameAppearance(ir.Appearance a, ir.Appearance b, String where) {
  _close(a.toJson(), b.toJson(), where);
}

void _close(Object? a, Object? b, String where) {
  if (a is num && b is num) {
    expect((a - b).abs(), lessThanOrEqualTo(1e-9), reason: where);
  } else if (a is Map && b is Map) {
    expect(a.keys.toSet(), b.keys.toSet(), reason: where);
    for (final k in a.keys) {
      _close(a[k], b[k], '$where.$k');
    }
  } else if (a is List && b is List) {
    expect(a.length, b.length, reason: where);
    for (var i = 0; i < a.length; i++) {
      _close(a[i], b[i], '$where[$i]');
    }
  } else {
    expect(a, b, reason: where);
  }
}

class _Vsync implements TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

void main() {
  group('typed paths', () {
    test('parse: typed paths and registry fallbacks', () {
      for (final p in _paths.keys) {
        expect(StageAppearancePath.parse(p), isNotNull, reason: p);
      }
      for (final p in [
        'fills',
        'fills.s',
        'fills.s.visible',
        'fills.s.blendMode',
        'fills.g.handles.start',
        'fills.i.focalPoint',
        'fills.g.stops.x.color',
        'strokes.align',
        'strokes.dash',
        'strokes.weight.middle',
        'effects',
        'effects.d.visible',
        'effects.d.showBehindTransparentAreas',
        'cornerRadius.middle',
        'width',
        'opacity',
        'motion.translateX',
      ]) {
        expect(StageAppearancePath.parse(p), isNull, reason: p);
      }
    });

    test('every typed path is a known registry property', () {
      for (final p in _paths.keys) {
        expect(ir.PropertyRegistry.standard.lookup(p), isNotNull, reason: p);
      }
    });
  });

  group('typed override ≡ registry with evaluateTrack', () {
    for (final MapEntry(key: path, value: kind) in _paths.entries) {
      test(path, () {
        final g = _Gen(path.hashCode);
        var compared = 0;
        for (var trial = 0; trial < 40; trial++) {
          final track = g.track(path, kind);
          final (overrides, bound) = _bind([track]);
          final (compiled, channel) = bound.single;
          expect(compiled.isTyped, isTrue);
          expect(channel.path.stride, compiled.stride);
          for (final t in _clockValues(g, track)) {
            compiled.evaluate(t);
            channel.write(compiled.out, uniform: compiled.outputUniform);
            _expectSameAppearance(
              overrides.apply(_base),
              _oracle(_shape, [track], t),
              '$path trial $trial t=$t',
            );
            compared++;
          }
        }
        expect(compared, greaterThan(40 * 90));
      });
    }

    test('several tracks on one node compose in track order', () {
      final g = _Gen(7);
      final groups = [
        ['cornerRadius', 'cornerRadius.tl', 'cornerRadius.br'],
        ['cornerRadius.tl', 'cornerRadius'],
        ['strokes.weight.top', 'strokes.weight', 'strokes.weight.left'],
        [
          'fills.g.stops.0.color',
          'fills.g.opacity',
          'fills.g.stops.0.position',
          'fills.g.stops.2.color',
        ],
        ['effects.d.color', 'effects.d.offset', 'effects.d.blur'],
      ];
      for (final paths in groups) {
        for (var trial = 0; trial < 20; trial++) {
          final tracks = [
            for (final (i, p) in paths.indexed)
              g.track(p, _paths[p] ?? 'unit', id: 't$i'),
          ];
          final (overrides, bound) = _bind(tracks);
          for (final t in _clockValues(g, tracks.first)) {
            for (final (compiled, channel) in bound) {
              compiled.evaluate(t);
              channel.write(compiled.out, uniform: compiled.outputUniform);
            }
            _expectSameAppearance(
              overrides.apply(_base),
              _oracle(_shape, tracks, t),
              '$paths trial $trial t=$t',
            );
          }
        }
      }
    });
  });

  group('animator binding', () {
    ir.ResolvedDocument doc(List<ir.Track> tracks, {List<ir.Node>? nodes}) =>
        ir.resolveDocument(
          ir.StageDocument(
            id: 'd',
            baseBreakpointId: 'b',
            breakpoints: const [
              ir.Breakpoint(
                id: 'b',
                name: 'B',
                minWidth: 0,
                designSize: ir.StageSize(width: 400, height: 300),
              ),
            ],
            scenes: [
              ir.Scene(
                id: 's',
                kind: ir.SceneKind.pinned,
                root: ir.FrameNode(
                  common: const ir.NodeCommon(
                    id: 'root',
                    width: 400,
                    height: 300,
                  ),
                  children: nodes ?? const [_shape],
                ),
                clocks: const [ir.Clock.sceneScroll(id: 'c', sceneId: 's')],
                tracks: tracks,
              ),
            ],
          ),
        );

    test('typed tracks never copy the node and match the oracle', () {
      final g = _Gen(11);
      final tracks = [
        for (final (i, p) in [
          'fills.s.color',
          'fills.g.stops.2.color',
          'strokes.weight',
          'effects.d.offset',
          'cornerRadius.tl',
          'cornerSmoothing',
        ].indexed)
          g.track(p, _paths[p]!, id: 't$i'),
      ];
      final resolved = doc(tracks);
      final registry = StageNodeRegistry();
      final animator = StageAnimator(registry: registry, vsync: _Vsync());
      final box = RenderStageShape(
        node: resolved.scenes.single.root.children.single.node,
        environment: StageEnvironment(nodes: registry),
      );
      registry.attachNode(box);
      animator.load(resolved);
      final base = box.node;
      for (var i = 0; i <= 40; i++) {
        final t = i / 40;
        animator.sceneScrolled('s', progress: t, visible: true);
        expect(identical(box.node, base), isTrue, reason: 'no node copy');
        _expectSameAppearance(
          box.appearanceOverrides!.apply((box.node as ir.ShapeNode).appearance),
          _oracle(base as ir.ShapeNode, tracks, t),
          't=$t',
        );
      }
      animator.dispose();
    });

    test('malformed typed tracks and text nodes keep the registry path', () {
      // A colour track with a number keyframe cannot be typed.
      const bad = ir.Track(
        id: 'bad',
        target: 'n',
        property: 'fills.s.color',
        clockId: 'c',
        keyframes: [
          ir.Keyframe(id: 'a', t: 0, value: ir.IrValue.number(1)),
          ir.Keyframe(
            id: 'b',
            t: 1,
            value: ir.IrValue.color(ir.StageColor.white),
          ),
        ],
      );
      expect(CompiledTrack.compile(bad).isTyped, isFalse);
      final resolved = doc(const [bad]);
      final registry = StageNodeRegistry();
      final animator = StageAnimator(registry: registry, vsync: _Vsync());
      final box = RenderStageShape(
        node: resolved.scenes.single.root.children.single.node,
        environment: StageEnvironment(nodes: registry),
      );
      registry.attachNode(box);
      animator.load(resolved);
      expect(box.appearanceOverrides, isNull);
      animator.sceneScrolled('s', progress: 1, visible: true);
      final fill = (box.node as ir.ShapeNode).appearance.fills.first;
      expect((fill as ir.SolidPaint).color, ir.StageColor.white);
      animator.dispose();
    });

    test('reattaching rebinds the channels without duplicates', () {
      final g = _Gen(3);
      final tracks = [g.track('fills.s.color', 'color')];
      final resolved = doc(tracks);
      final registry = StageNodeRegistry();
      final animator = StageAnimator(registry: registry, vsync: _Vsync());
      final box = RenderStageShape(
        node: resolved.scenes.single.root.children.single.node,
        environment: StageEnvironment(nodes: registry),
      );
      registry.attachNode(box);
      animator.load(resolved);
      registry
        ..detachNode(box)
        ..attachNode(box);
      expect(box.appearanceOverrides!.channels, hasLength(1));
      animator.load(resolved);
      expect(box.appearanceOverrides!.channels, hasLength(1));
      animator.dispose();
    });
  });
}
