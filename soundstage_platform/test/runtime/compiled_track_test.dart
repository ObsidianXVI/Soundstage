import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// Compiled tracks must equal `ir.evaluateTrack` (the reference oracle) for
/// every value type, easing and clock value (architecture §17.1).

const double _tol = 1e-9;

/// Deep comparison of two IrValues' JSON with a numeric tolerance.
void _expectClose(Object? a, Object? b, String where) {
  if (a is num && b is num) {
    expect((a - b).abs(), lessThanOrEqualTo(_tol), reason: where);
  } else if (a is Map && b is Map) {
    expect(a.keys.toSet(), b.keys.toSet(), reason: where);
    for (final k in a.keys) {
      _expectClose(a[k], b[k], '$where.$k');
    }
  } else if (a is List && b is List) {
    expect(a.length, b.length, reason: where);
    for (var i = 0; i < a.length; i++) {
      _expectClose(a[i], b[i], '$where[$i]');
    }
  } else {
    expect(a, b, reason: where);
  }
}

class _Gen {
  _Gen(int seed) : r = math.Random(seed);
  final math.Random r;

  double d([double lo = -100, double hi = 100]) =>
      lo + r.nextDouble() * (hi - lo);
  double u() => r.nextDouble();
  bool chance(double p) => r.nextDouble() < p;

  ir.StageColor color() =>
      ir.StageColor(r: u(), g: u(), b: u(), a: chance(.3) ? u() : 1);

  ir.Easing easing() => switch (r.nextInt(7)) {
    0 => const ir.Easing.linear(),
    1 => ir.Easing.cubicBezier(u(), d(-1, 2), u(), d(-1, 2)),
    2 => ir.Easing.preset(
      ir.EasingPreset.values[r.nextInt(ir.EasingPreset.values.length)],
    ),
    3 => ir.Easing.spring(
      mass: d(0.2, 4),
      stiffness: d(10, 400),
      damping: chance(.2) ? 2 * math.sqrt(100) : d(0, 40),
    ),
    4 => ir.Easing.steps(
      r.nextInt(6),
      position: chance(.5)
          ? ir.StepPosition.jumpStart
          : ir.StepPosition.jumpEnd,
    ),
    5 => const ir.Easing.hold(),
    _ => const ir.Easing.spring(mass: -1),
  };

  ir.IrValue value(String kind) => switch (kind) {
    'number' => ir.IrValue.number(d()),
    'color' => ir.IrValue.color(color()),
    'point' => ir.IrValue.point(ir.StagePoint(x: d(), y: d())),
    'insets' => ir.IrValue.insets(
      ir.EdgeInsetsValue(top: d(), right: d(), bottom: d(), left: d()),
    ),
    'cornerRadius' => ir.IrValue.cornerRadius(
      chance(.5)
          ? ir.CornerRadius.uniform(d(0, 50))
          : ir.CornerRadius.perCorner(tl: d(), tr: d(), br: d(), bl: d()),
    ),
    'strokeWeight' => ir.IrValue.strokeWeight(
      chance(.5)
          ? ir.StrokeWeight.uniform(d(0, 10))
          : ir.StrokeWeight.perSide(
              top: d(),
              right: d(),
              bottom: d(),
              left: d(),
            ),
    ),
    'gap' => ir.IrValue.gap(
      chance(.15) ? const ir.Gap.auto() : ir.Gap.fixed(d()),
    ),
    'lineHeight' => ir.IrValue.lineHeight(switch (r.nextInt(5)) {
      0 => const ir.LineHeight.auto(),
      1 || 2 => ir.LineHeight.px(d(0, 80)),
      _ => ir.LineHeight.percent(d(50, 200)),
    }),
    'letterSpacing' => ir.IrValue.letterSpacing(
      chance(.5)
          ? ir.LetterSpacing.px(d(-5, 5))
          : ir.LetterSpacing.percent(d()),
    ),
    'numbers' => ir.IrValue.numbers([
      for (var i = 0, n = 2 + (chance(.3) ? r.nextInt(2) : 0); i < n; i++)
        d(0, 20),
    ]),
    'paints' => ir.IrValue.paints([
      ir.Paint.solid(id: 'a', color: color(), opacity: u()),
      ir.Paint.gradient(
        id: 'g',
        stops: [
          ir.ColorStop(position: 0, color: color()),
          ir.ColorStop(position: u(), color: color()),
          if (chance(.2)) ir.ColorStop(position: 1, color: color()),
        ],
      ),
    ]),
    'effect' => ir.IrValue.effect(
      ir.Effect.dropShadow(
        id: 's',
        color: color(),
        offset: ir.StagePoint(x: d(-10, 10), y: d(-10, 10)),
        blur: d(0, 30),
      ),
    ),
    'boolean' => ir.IrValue.boolean(chance(.5)),
    'enum' => ir.IrValue.enumValue(
      ['normal', 'multiply', 'screen'][r.nextInt(3)],
    ),
    'string' => ir.IrValue.string('s${r.nextInt(4)}'),
    _ => throw ArgumentError(kind),
  };

  /// A track for [path] with mostly-[kind] keyframes (some times repeat, the
  /// order is shuffled, and a few values have the wrong type).
  ir.Track track(String path, String kind) {
    final n = 1 + r.nextInt(6);
    final values = <ir.IrValue>[];
    for (var i = 0; i < n; i++) {
      if (chance(.05)) {
        values.add(value(kind == 'number' ? 'color' : 'number'));
      } else if (i > 0 && chance(.15)) {
        values.add(values[i - 1]); // equal neighbours
      } else {
        values.add(value(kind));
      }
    }
    return ir.Track(
      id: 't',
      target: 'n',
      property: path,
      clockId: 'c',
      keyframes: [
        for (var i = 0; i < n; i++)
          ir.Keyframe(
            id: 'k$i',
            t: (d(0, 1) * 20).round() / 20, // repeats some times
            value: values[i],
            easing: easing(),
          ),
      ],
    );
  }
}

const Map<String, String> _paths = {
  'number': 'motion.translateY',
  'color': 'fills.p.color',
  'point': 'fills.p.focalPoint',
  'insets': 'autoLayout.padding',
  'cornerRadius': 'cornerRadius',
  'strokeWeight': 'strokes.weight',
  'gap': 'autoLayout.gap',
  'lineHeight': 'style.lineHeight',
  'letterSpacing': 'style.letterSpacing',
  'numbers': 'strokes.dash',
  'paints': 'fills',
  'effect': 'effects.s',
  'boolean': 'visible',
  'enum': 'blendMode',
  'string': 'characters',
};

void main() {
  group('compiled track ≡ evaluateTrack', () {
    for (final MapEntry(key: kind, value: path) in _paths.entries) {
      test('$kind ($path)', () {
        final g = _Gen(kind.hashCode);
        var compared = 0;
        for (var trial = 0; trial < 150; trial++) {
          final track = g.track(path, kind);
          final compiled = CompiledTrack.compile(track);
          // Sweep forward, backward and at random (segment cache paths),
          // including keyframe times, the ends, outside and NaN.
          final ts = <double>[
            for (var i = -5; i <= 105; i++) i / 100,
            for (var i = 105; i >= -5; i -= 3) i / 100,
            for (var i = 0; i < 40; i++) g.d(-0.2, 1.2),
            for (final k in track.keyframes) k.t,
            double.nan,
          ];
          for (final t in ts) {
            compiled.evaluate(t);
            final expected = ir.evaluateTrack(track, t);
            _expectClose(
              compiled.value?.toJson(),
              expected?.toJson(),
              '$kind trial $trial t=$t',
            );
            compared++;
          }
        }
        expect(compared, greaterThan(150 * 150));
      });
    }
  });

  test('scalar output is readable without boxing', () {
    final track = const ir.Track(
      id: 't',
      target: 'n',
      property: 'opacity',
      clockId: 'c',
      keyframes: [
        ir.Keyframe(id: 'a', t: 0, value: ir.IrValue.number(0)),
        ir.Keyframe(
          id: 'b',
          t: 1,
          value: ir.IrValue.number(1),
          easing: ir.Easing.preset(ir.EasingPreset.easeInOut),
        ),
      ],
    );
    final c = CompiledTrack.compile(track);
    expect(c.kind, TrackValueKind.scalar);
    expect(c.evaluate(0.5), isTrue);
    expect(c.scalar, closeTo(0.5, 1e-9));
    expect(c.heldIndex, -1);
    expect(c.evaluate(0.5), isFalse, reason: 'unchanged output');
    expect(c.evaluate(2), isTrue);
    expect(c.heldIndex, 1);
    expect(c.scalar, 1);
  });

  test('steps only report a change when the held keyframe changes', () {
    final track = const ir.Track(
      id: 't',
      target: 'n',
      property: 'visible',
      clockId: 'c',
      keyframes: [
        ir.Keyframe(id: 'a', t: 0, value: ir.IrValue.boolean(false)),
        ir.Keyframe(id: 'b', t: 0.5, value: ir.IrValue.boolean(true)),
      ],
    );
    final c = CompiledTrack.compile(track);
    expect(c.kind, TrackValueKind.step);
    expect(c.evaluate(0.1), isTrue);
    expect(c.evaluate(0.2), isFalse);
    expect(c.evaluate(0.6), isTrue);
    expect(c.value, const ir.IrValue.boolean(true));
  });
}
