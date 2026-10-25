import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/easing/easing_curve.dart';
import 'package:soundstage_platform/editor/easing/easing_samples.dart';
import 'package:soundstage_platform/ir/ir.dart';
import 'package:soundstage_platform/runtime/src/animator/compiled_easing.dart';

// The easing editor draws what the runtime evaluates: every curve is
// `applyEasing` (the IR's source of truth) sampled, and the runtime's
// compiled easing agrees with it.

final List<Easing> _all = [
  const Easing.linear(),
  for (final p in EasingPreset.values) Easing.preset(p),
  const Easing.cubicBezier(0.1, -0.8, 0.9, 1.9),
  const Easing.cubicBezier(0.5, 0.5, 0.5, 0.5),
  const Easing.spring(),
  const Easing.spring(mass: 2, stiffness: 300, damping: 5),
  const Easing.spring(mass: 1, stiffness: 100, damping: 80),
  const Easing.steps(4),
  const Easing.steps(3, position: StepPosition.jumpStart),
  const Easing.hold(),
];

void main() {
  test('the drawn samples are applyEasing at evenly spaced progress', () {
    for (final e in _all) {
      final samples = sampleEasing(e);
      expect(samples.length, sampleCountFor(e));
      for (var i = 0; i < samples.length; i++) {
        expect(
          samples[i],
          applyEasing(e, i / (samples.length - 1)),
          reason: '$e at sample $i',
        );
      }
      // (CSS jump-start has already jumped at progress 0.)
      if (e is! StepsEasing || e.position == StepPosition.jumpEnd) {
        expect(samples.first, 0, reason: '$e');
      }
      expect(samples.last, 1, reason: '$e');
    }
  });

  test('and agree with the runtime\'s compiled easing', () {
    for (final e in _all) {
      final compiled = CompiledEasing.of([e]);
      final samples = sampleEasing(e);
      for (var i = 0; i < samples.length; i++) {
        expect(
          compiled.ease(0, i / (samples.length - 1)),
          closeTo(samples[i], 1e-9),
          reason: '$e at sample $i',
        );
      }
    }
  });

  test('Back curves and springs overshoot; the plot range shows it', () {
    final back = sampleEasing(const Easing.preset(EasingPreset.easeInOutBack));
    final (lo, hi) = sampleRange(back);
    expect(lo, lessThan(0));
    expect(hi, greaterThan(1));
    final (plotLo, plotHi) = plotRange(back);
    expect(plotLo, lessThan(lo));
    expect(plotHi, greaterThan(hi));
    // A plain curve keeps the 0-1 band with a margin.
    final (l2, h2) = plotRange(sampleEasing(const Easing.linear()));
    expect((l2, h2), (-0.2, 1.2));
    final spring = sampleRange(sampleEasing(const Easing.spring(damping: 5)));
    expect(spring.$2, greaterThan(1));
  });

  test('cubic-bezier text round-trips and rejects non-beziers', () {
    expect(
      cubicBezierCss(0.25, 0.1, 0.25, 1),
      'cubic-bezier(0.25, 0.1, 0.25, 1)',
    );
    expect(
      cubicBezierCss(0.34, 1.56, 0.64, 1),
      'cubic-bezier(0.34, 1.56, 0.64, 1)',
    );
    expect(cubicBezierCss(0, -0.0004, 1, 1.0), 'cubic-bezier(0, 0, 1, 1)');
    for (final e in [
      const CubicBezierEasing(0.68, -0.6, 0.32, 1.6),
      const CubicBezierEasing(0, 0, 1, 1),
      const CubicBezierEasing(0.123, -1.5, 0.987, 2.5),
    ]) {
      expect(parseCubicBezier(cubicBezierCss(e.x1, e.y1, e.x2, e.y2)), e);
    }
    expect(
      parseCubicBezier('  CUBIC-BEZIER( .4 , 0 , 1 , 1 ) '),
      const CubicBezierEasing(0.4, 0, 1, 1),
    );
    expect(
      parseCubicBezier('0.4 0 1 1'),
      const CubicBezierEasing(0.4, 0, 1, 1),
    );
    expect(parseCubicBezier('cubic-bezier(1.2, 0, 1, 1)'), isNull);
    expect(parseCubicBezier('cubic-bezier(0, 0, 1)'), isNull);
    expect(parseCubicBezier('ease'), isNull);
    expect(parseCubicBezier(''), isNull);
  });

  test('control points of presets seed the bezier editor', () {
    expect(controlPointsOf(const Easing.preset(EasingPreset.easeOutBack)), (
      0.34,
      1.56,
      0.64,
      1.0,
    ));
    expect(controlPointsOf(const Easing.linear()), (0, 0, 1, 1));
    expect(controlPointsOf(const Easing.hold()), isNull);
    expect(modeOf(const Easing.spring()), EasingMode.spring);
    expect(modeOf(const Easing.preset(EasingPreset.ease)), EasingMode.preset);
  });

  test('spring settle time grows with mass and shrinks with stiffness', () {
    final base = springSettleTime(1, 100, 15);
    expect(base, greaterThan(0));
    expect(springSettleTime(4, 100, 15), greaterThan(base));
    expect(springSettleTime(1, 400, 15), lessThan(base));
    expect(springSettleTime(0, 100, 15), 0);
  });

  testWidgets('the pad paints the samples of applyEasing', (tester) async {
    for (final e in _all) {
      await tester.pumpWidget(
        MaterialApp(
          builder: (c, child) =>
              SsScope(theme: SsThemeData.dark(), child: child!),
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 280, child: EasingCurvePad(easing: e)),
            ),
          ),
        ),
      );
      final paint = tester.widget<CustomPaint>(
        find.byKey(const ValueKey('easing-curve')),
      );
      final painter = paint.painter! as EasingCurvePainter;
      expect(painter.samples, sampleEasing(e), reason: '$e');
      for (var i = 0; i < painter.samples.length; i++) {
        expect(
          painter.samples[i],
          applyEasing(e, i / (painter.samples.length - 1)),
        );
      }
    }
  });
}
