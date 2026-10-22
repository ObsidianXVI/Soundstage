import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

// ---- Independent OKLab reference ---------------------------------------------
// Goes through CIE XYZ with the published M1/M2 matrices (Ottosson), rather
// than the combined linear-sRGB→LMS matrix the implementation uses, and
// inverts by Gaussian elimination.

typedef M3 = List<List<double>>;

const M3 _srgbToXyz = [
  [0.4124564, 0.3575761, 0.1804375],
  [0.2126729, 0.7151522, 0.0721750],
  [0.0193339, 0.1191920, 0.9503041],
];
const M3 _m1 = [
  [0.8189330101, 0.3618667424, -0.1288597137],
  [0.0329845436, 0.9293118715, 0.0361456387],
  [0.0482003018, 0.2643662691, 0.6338517070],
];
const M3 _m2 = [
  [0.2104542553, 0.7936177850, -0.0040720468],
  [1.9779984951, -2.4285922050, 0.4505937099],
  [0.0259040371, 0.7827717662, -0.8086757660],
];

List<double> _mul(M3 m, List<double> v) => [
  for (final r in m) r[0] * v[0] + r[1] * v[1] + r[2] * v[2],
];

List<double> _solve(M3 m, List<double> y) {
  final a = [
    for (var i = 0; i < 3; i++) [...m[i], y[i]],
  ];
  for (var c = 0; c < 3; c++) {
    var p = c;
    for (var r = c + 1; r < 3; r++) {
      if (a[r][c].abs() > a[p][c].abs()) p = r;
    }
    final t = a[c];
    a[c] = a[p];
    a[p] = t;
    for (var r = 0; r < 3; r++) {
      if (r == c) continue;
      final f = a[r][c] / a[c][c];
      for (var k = c; k < 4; k++) {
        a[r][k] -= f * a[c][k];
      }
    }
  }
  return [for (var i = 0; i < 3; i++) a[i][3] / a[i][i]];
}

double _dec(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
double _enc(double c) =>
    c <= 0.0031308 ? 12.92 * c : 1.055 * math.pow(c, 1 / 2.4) - 0.055;
double _cbrt(double x) =>
    x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();

List<double> refLab(StageColor c) {
  final lms = _mul(_m1, _mul(_srgbToXyz, [_dec(c.r), _dec(c.g), _dec(c.b)]));
  return _mul(_m2, [for (final v in lms) _cbrt(v)]);
}

List<double> refRgb(List<double> lab) {
  final lmsC = _solve(_m2, lab);
  final lms = [for (final v in lmsC) v * v * v];
  final rgb = _solve(_srgbToXyz, _solve(_m1, lms));
  return [for (final v in rgb) _enc(v.clamp(0.0, 1.0)).clamp(0.0, 1.0)];
}

// ---- Independent bezier reference: pure bisection on the Bernstein form ----

double refBezier(double x1, double y1, double x2, double y2, double x) {
  double b(double p1, double p2, double t) =>
      3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t;
  var lo = 0.0, hi = 1.0;
  for (var i = 0; i < 200; i++) {
    final mid = (lo + hi) / 2;
    if (b(x1, x2, mid) < x) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return b(y1, y2, (lo + hi) / 2);
}

const red = StageColor(r: 1, g: 0, b: 0);
const blue = StageColor(r: 0, g: 0, b: 1);

Matcher near(double v, [double eps = 1e-6]) => closeTo(v, eps);

void main() {
  group('OKLab', () {
    test('conversion matches published reference values', () {
      // CSS Color 4 / Ottosson: sRGB red, blue and white in OKLab.
      final r = srgbToOkLab(red);
      expect(r.l, near(0.627955, 1e-5));
      expect(r.a, near(0.224863, 1e-5));
      expect(r.b, near(0.125846, 1e-5));
      final b = srgbToOkLab(blue);
      expect(b.l, near(0.452014, 1e-5));
      expect(b.a, near(-0.032457, 1e-5));
      expect(b.b, near(-0.311528, 1e-5));
      final w = srgbToOkLab(StageColor.white);
      expect(w.l, near(1, 1e-4));
      expect(w.a.abs() + w.b.abs(), lessThan(1e-4));
    });

    test('agrees with the XYZ-route reference', () {
      for (final c in [red, blue, const StageColor(r: 0.2, g: 0.7, b: 0.4)]) {
        final lab = srgbToOkLab(c);
        final ref = refLab(c);
        expect(lab.l, near(ref[0], 2e-4));
        expect(lab.a, near(ref[1], 2e-4));
        expect(lab.b, near(ref[2], 2e-4));
      }
    });

    test('lerp midpoint of red and blue', () {
      final mid = lerpColor(red, blue.withAlpha(0.5), 0.5);
      final a = refLab(red), b = refLab(blue);
      final ref = refRgb([for (var i = 0; i < 3; i++) (a[i] + b[i]) / 2]);
      expect(mid.r, near(ref[0], 1e-3));
      expect(mid.g, near(ref[1], 1e-3));
      expect(mid.b, near(ref[2], 1e-3));
      expect(mid.a, near(0.75)); // alpha is linear
      // Perceptual midpoint, not the sRGB average (0.5, 0, 0.5).
      expect(mid.r, greaterThan(0.52));
    });

    test('lerp midpoint of black and white has OKLab lightness 0.5', () {
      final mid = lerpColor(StageColor.black, StageColor.white, 0.5);
      expect(srgbToOkLab(mid).l, near(0.5, 1e-4));
      expect(mid.r, near(mid.g, 1e-6));
    });

    test('endpoints are exact and round-trips are close', () {
      const c = StageColor(r: 0.123, g: 0.456, b: 0.789, a: 0.3);
      expect(lerpColor(c, red, 0), same(c));
      expect(lerpColor(red, c, 1), same(c));
      final back = okLabToSrgb(srgbToOkLab(c), c.a);
      expect(back.r, near(c.r, 1e-6));
      expect(back.g, near(c.g, 1e-6));
      expect(back.b, near(c.b, 1e-6));
    });
  });

  group('lerpIrValue', () {
    test('numbers, points, insets, radii', () {
      expect(
        lerpIrValue(const IrValue.number(0), const IrValue.number(10), 0.25),
        const IrValue.number(2.5),
      );
      expect(
        lerpIrValue(
          const IrValue.point(StagePoint(x: 0, y: 10)),
          const IrValue.point(StagePoint(x: 10, y: 0)),
          0.5,
        ),
        const IrValue.point(StagePoint(x: 5, y: 5)),
      );
      expect(
        lerpIrValue(
          const IrValue.insets(EdgeInsetsValue()),
          IrValue.insets(EdgeInsetsValue.all(8)),
          0.5,
        ),
        IrValue.insets(EdgeInsetsValue.all(4)),
      );
      expect(
        lerpIrValue(
          const IrValue.cornerRadius(CornerRadius.uniform(0)),
          const IrValue.cornerRadius(CornerRadius.perCorner(tl: 8)),
          0.5,
        ),
        const IrValue.cornerRadius(CornerRadius.perCorner(tl: 4)),
      );
    });

    test('discrete and mismatched values step (null)', () {
      expect(
        lerpIrValue(
          const IrValue.boolean(true),
          const IrValue.boolean(false),
          0.5,
        ),
        isNull,
      );
      expect(
        lerpIrValue(
          const IrValue.enumValue('a'),
          const IrValue.enumValue('b'),
          0.5,
        ),
        isNull,
      );
      expect(
        lerpIrValue(const IrValue.number(1), const IrValue.string('x'), 0.5),
        isNull,
      );
      expect(
        lerpIrValue(
          const IrValue.lineHeight(LineHeight.px(10)),
          const IrValue.lineHeight(LineHeight.percent(120)),
          0.5,
        ),
        isNull,
      );
      expect(
        lerpIrValue(
          const IrValue.gap(Gap.auto()),
          const IrValue.gap(Gap.fixed(4)),
          0.5,
        ),
        isNull,
      );
    });

    test('paint stacks lerp stop-wise when structures match', () {
      const a = IrValue.paints([
        Paint.gradient(
          id: 'g',
          stops: [
            ColorStop(position: 0, color: red),
            ColorStop(position: 1, color: blue),
          ],
        ),
      ]);
      const b = IrValue.paints([
        Paint.gradient(
          id: 'g',
          stops: [
            ColorStop(position: 0.5, color: red),
            ColorStop(position: 1, color: red),
          ],
        ),
      ]);
      final mid = lerpIrValue(a, b, 0.5)! as PaintsValue;
      final g = mid.value.single as GradientPaint;
      expect(g.stops[0].position, 0.25);
      expect(g.stops[1].color, lerpColor(blue, red, 0.5));
    });

    test('paint stacks with different structure step', () {
      const a = IrValue.paints([Paint.solid(id: 'a', color: red)]);
      for (final b in const [
        IrValue.paints([Paint.solid(id: 'b', color: blue)]), // other id
        IrValue.paints([
          Paint.solid(id: 'a', color: blue),
          Paint.solid(id: 'c', color: blue),
        ]),
        IrValue.paints([
          Paint.gradient(
            id: 'a',
            stops: [ColorStop(position: 0, color: red)],
          ),
        ]),
      ]) {
        expect(lerpIrValue(a, b, 0.5), isNull);
      }
    });

    test('shadows and blurs lerp field-wise', () {
      const a = IrValue.effects([
        Effect.dropShadow(
          id: 's',
          offset: StagePoint(y: 0),
          blur: 0,
          spread: 0,
        ),
        Effect.layerBlur(id: 'b', radius: 0),
      ]);
      const b = IrValue.effects([
        Effect.dropShadow(
          id: 's',
          offset: StagePoint(y: 10),
          blur: 20,
          spread: 4,
        ),
        Effect.layerBlur(id: 'b', radius: 8),
      ]);
      final mid = (lerpIrValue(a, b, 0.5)! as EffectsValue).value;
      final s = mid[0] as DropShadow;
      expect((s.offset.y, s.blur, s.spread), (5.0, 10.0, 2.0));
      expect((mid[1] as LayerBlur).radius, 4);
    });
  });

  group('easing', () {
    test('CSS ease samples match an independent bisection solve to 1e-6', () {
      for (final x in [0.01, 0.1, 0.25, 0.5, 0.75, 0.9, 0.99]) {
        expect(
          applyEasing(const Easing.preset(EasingPreset.ease), x),
          near(refBezier(0.25, 0.1, 0.25, 1, x)),
          reason: 'ease($x)',
        );
      }
      // Published approximations of CSS `ease`.
      expect(
        applyEasing(const Easing.preset(EasingPreset.ease), 0.25),
        near(0.40851, 1e-5),
      );
      expect(
        applyEasing(const Easing.preset(EasingPreset.ease), 0.5),
        near(0.80240, 1e-5),
      );
    });

    test('every preset agrees with the reference and pins the endpoints', () {
      for (final MapEntry(key: p, value: (x1, y1, x2, y2))
          in kEasingPresets.entries) {
        final e = Easing.preset(p);
        expect(applyEasing(e, 0), 0);
        expect(applyEasing(e, 1), 1);
        for (var i = 1; i < 100; i++) {
          final x = i / 100;
          expect(
            applyEasing(e, x),
            near(refBezier(x1, y1, x2, y2, x)),
            reason: '$p($x)',
          );
        }
      }
    });

    // Where dx/dt = 0 (x = 0.5 on the second curve) y is ill-conditioned in
    // x, so the bisection reference itself is only good to ~1e-5 there; by
    // symmetry the exact value is 0.5.
    test('custom bezier with steep and flat regions', () {
      expect(applyEasing(const Easing.cubicBezier(1, 0, 0, 1), 0.5), near(0.5));
      for (final x in [0.001, 0.3, 0.5, 0.999]) {
        expect(
          applyEasing(const Easing.cubicBezier(0, 1, 1, 0), x),
          near(refBezier(0, 1, 1, 0, x)),
        );
        expect(
          applyEasing(const Easing.cubicBezier(1, 0, 0, 1), x),
          near(refBezier(1, 0, 0, 1, x), 1e-5),
        );
      }
    });

    test('CSS presets are monotonic; Back presets overshoot', () {
      for (final p in [
        EasingPreset.ease,
        EasingPreset.easeIn,
        EasingPreset.easeOut,
        EasingPreset.easeInOut,
      ]) {
        var prev = 0.0;
        for (var i = 1; i <= 1000; i++) {
          final v = applyEasing(Easing.preset(p), i / 1000);
          expect(v, greaterThanOrEqualTo(prev - 1e-12), reason: '$p');
          prev = v;
        }
      }
      expect(
        applyEasing(const Easing.preset(EasingPreset.easeInBack), 0.2),
        lessThan(0),
      );
      expect(
        applyEasing(const Easing.preset(EasingPreset.easeOutBack), 0.8),
        greaterThan(1),
      );
    });

    test('spring starts at 0, ends at exactly 1', () {
      for (final s in const [
        Easing.spring(),
        Easing.spring(stiffness: 300, damping: 5),
        Easing.spring(stiffness: 100, damping: 20), // critical
        Easing.spring(mass: 2, stiffness: 50, damping: 60), // over-damped
        Easing.spring(damping: 0), // floored damping ratio
      ]) {
        expect(applyEasing(s, 0), 0);
        expect(applyEasing(s, 1), 1);
        expect(applyEasing(s, 0.999), near(1, 5e-3));
        for (var i = 0; i <= 100; i++) {
          expect(applyEasing(s, i / 100).isFinite, isTrue);
        }
      }
      // Under-damped overshoots; over-damped approaches monotonically.
      final bouncy = [
        for (var i = 0; i <= 200; i++)
          applyEasing(const Easing.spring(damping: 5), i / 200),
      ];
      expect(bouncy.reduce(math.max), greaterThan(1.1));
      var prev = 0.0;
      for (var i = 1; i <= 200; i++) {
        final v = applyEasing(
          const Easing.spring(mass: 2, stiffness: 50, damping: 60),
          i / 200,
        );
        expect(v, greaterThanOrEqualTo(prev));
        prev = v;
      }
    });

    test('degenerate springs fall back to linear', () {
      expect(applyEasing(const Easing.spring(mass: 0), 0.3), 0.3);
      expect(applyEasing(const Easing.spring(stiffness: -1), 0.3), 0.3);
    });

    test('steps follow CSS jump-end and jump-start', () {
      const end = Easing.steps(4);
      expect(
        [0.0, 0.24, 0.25, 0.5, 0.99, 1.0].map((x) => applyEasing(end, x)),
        [0, 0, 0.25, 0.5, 0.75, 1],
      );
      const start = Easing.steps(4, position: StepPosition.jumpStart);
      expect(
        [0.0, 0.24, 0.25, 0.74, 0.75, 1.0].map((x) => applyEasing(start, x)),
        [0.25, 0.25, 0.5, 0.75, 1, 1],
      );
      expect(applyEasing(const Easing.steps(0), 0.5), 0); // count < 1 → 1 step
    });

    test('hold and linear', () {
      expect(applyEasing(const Easing.hold(), 0.999), 0);
      expect(applyEasing(const Easing.hold(), 1), 1);
      expect(applyEasing(const Easing.linear(), 0.37), 0.37);
      expect(applyEasing(const Easing.linear(), 2), 1); // clamped input
    });
  });

  group('evaluateTrack', () {
    Track track(String property, List<(double, IrValue, Easing)> kfs) => Track(
      id: 't',
      target: 'n',
      property: property,
      clockId: 'c',
      keyframes: [
        for (final (i, (t, v, e)) in kfs.indexed)
          Keyframe(id: 'k$i', t: t, value: v, easing: e),
      ],
    );
    const lin = Easing.linear();

    final opacity = track('opacity', [
      (0, const IrValue.number(0), lin),
      (1, const IrValue.number(10), const Easing.preset(EasingPreset.ease)),
      (2, const IrValue.number(20), lin),
    ]);

    test('holds before the first and after the last keyframe', () {
      expect(evaluateTrack(opacity, -5), const IrValue.number(0));
      expect(evaluateTrack(opacity, 0), const IrValue.number(0));
      expect(evaluateTrack(opacity, 2), const IrValue.number(20));
      expect(evaluateTrack(opacity, 99), const IrValue.number(20));
    });

    test('interpolates between keyframes with the earlier keyframe easing', () {
      expect(evaluateTrack(opacity, 0.5), const IrValue.number(5));
      final eased = evaluateTrack(opacity, 1.5)! as NumberValue;
      expect(eased.value, near(10 + 10 * refBezier(0.25, 0.1, 0.25, 1, 0.5)));
      expect(evaluateTrack(opacity, 1), const IrValue.number(10));
    });

    test('unsorted keyframes are ordered by time', () {
      final t = track('opacity', [
        (1, const IrValue.number(10), lin),
        (0, const IrValue.number(0), lin),
      ]);
      expect(evaluateTrack(t, 0.25), const IrValue.number(2.5));
    });

    test('step properties switch at the later keyframe', () {
      final t = track('visible', [
        (0, const IrValue.boolean(true), lin),
        (1, const IrValue.boolean(false), lin),
      ]);
      expect(evaluateTrack(t, 0.999), const IrValue.boolean(true));
      expect(evaluateTrack(t, 1), const IrValue.boolean(false));
      final e = track('layoutChild.horizontalSizing', [
        (0, const IrValue.enumValue('fixed'), lin),
        (1, const IrValue.enumValue('fill'), lin),
      ]);
      expect(evaluateTrack(e, 0.6), const IrValue.enumValue('fixed'));
    });

    test('hold easing and unknown properties step', () {
      final h = track('opacity', [
        (0, const IrValue.number(0), const Easing.hold()),
        (1, const IrValue.number(1), lin),
      ]);
      expect(evaluateTrack(h, 0.9), const IrValue.number(0));
      final u = track('not.a.property', [
        (0, const IrValue.number(0), lin),
        (1, const IrValue.number(1), lin),
      ]);
      expect(evaluateTrack(u, 0.5), const IrValue.number(0));
    });

    test('colours interpolate in OKLab through the registry', () {
      final t = track('fills.p.color', [
        (0, const IrValue.color(red), lin),
        (1, const IrValue.color(blue), lin),
      ]);
      expect(evaluateTrack(t, 0.5), IrValue.color(lerpColor(red, blue, 0.5)));
    });

    test('paint stacks with mismatched structure step', () {
      final t = track('fills', [
        (0, const IrValue.paints([Paint.solid(id: 'a', color: red)]), lin),
        (1, const IrValue.paints([Paint.solid(id: 'b', color: blue)]), lin),
      ]);
      expect(
        evaluateTrack(t, 0.7),
        const IrValue.paints([Paint.solid(id: 'a', color: red)]),
      );
      expect(
        evaluateTrack(t, 1),
        const IrValue.paints([Paint.solid(id: 'b', color: blue)]),
      );
      final same = track('fills', [
        (0, const IrValue.paints([Paint.solid(id: 'a', color: red)]), lin),
        (1, const IrValue.paints([Paint.solid(id: 'a', color: blue)]), lin),
      ]);
      expect(
        evaluateTrack(same, 0.5),
        IrValue.paints([
          Paint.solid(id: 'a', color: lerpColor(red, blue, 0.5)),
        ]),
      );
    });

    test('no keyframes gives null; coincident keyframes jump', () {
      expect(evaluateTrack(track('opacity', const []), 0), isNull);
      final j = track('opacity', [
        (0, const IrValue.number(0), lin),
        (1, const IrValue.number(1), lin),
        (1, const IrValue.number(5), lin),
        (2, const IrValue.number(5), lin),
      ]);
      expect(evaluateTrack(j, 1), const IrValue.number(5));
      expect(evaluateTrack(j, 0.5), const IrValue.number(0.5));
    });
  });
}
