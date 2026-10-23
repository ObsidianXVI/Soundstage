import 'dart:math';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// |a − b| within 1e-9, relative to the magnitude for large values.
bool close(double a, double b) =>
    (a - b).abs() <= 1e-9 * max(1, max(a.abs(), b.abs()));

void main() {
  group('inverseResolveAxisConstraint round trip', () {
    test('forward(inverse(x)) == x for every constraint, random inputs', () {
      final r = Random(42);
      double rnd(double lo, double hi) => lo + r.nextDouble() * (hi - lo);
      var checked = 0;
      for (var i = 0; i < 20000; i++) {
        final c = AxisConstraint.values[r.nextInt(5)];
        final reference = rnd(1, 3000);
        final parent = rnd(0.5, 4000);
        final offset = rnd(-2000, 2000);
        final size = rnd(0, 2000);
        // Bounds that contain the desired size half of the time.
        final withBounds = r.nextBool();
        final double? min = withBounds && r.nextBool()
            ? size * rnd(0, 1)
            : null;
        final double? mx = withBounds && r.nextBool() ? size * rnd(1, 2) : null;
        final inv = inverseResolveAxisConstraint(
          constraint: c,
          offset: offset,
          size: size,
          reference: reference,
          parent: parent,
          min: min,
          max: mx,
        );
        expect(inv.exact, isTrue, reason: '$c $offset $size');
        final fwd = resolveAxisConstraint(
          constraint: c,
          position: inv.position,
          size: inv.size,
          reference: reference,
          parent: parent,
          min: min,
          max: mx,
        );
        expect(
          close(fwd.offset, offset) && close(fwd.size, size),
          isTrue,
          reason:
              '$c R=$reference P=$parent: wanted ($offset, $size), '
              'got (${fwd.offset}, ${fwd.size})',
        );
        checked++;
      }
      expect(checked, 20000);
    });

    test('inverse(forward(stored)) == stored when nothing clamps', () {
      final r = Random(7);
      double rnd(double lo, double hi) => lo + r.nextDouble() * (hi - lo);
      for (var i = 0; i < 20000; i++) {
        final c = AxisConstraint.values[r.nextInt(5)];
        final reference = rnd(1, 3000);
        final parent = rnd(0.5, 4000);
        final x = rnd(-500, 1500);
        // Keep stretch sizes non-negative after the forward map.
        final w = rnd(max(0, reference - parent), 2000 + reference);
        final fwd = resolveAxisConstraint(
          constraint: c,
          position: x,
          size: w,
          reference: reference,
          parent: parent,
        );
        final inv = inverseResolveAxisConstraint(
          constraint: c,
          offset: fwd.offset,
          size: fwd.size,
          reference: reference,
          parent: parent,
        );
        expect(
          close(inv.position, x) && close(inv.size, w),
          isTrue,
          reason: '$c R=$reference P=$parent: ($x, $w) → $inv',
        );
      }
    });

    test('a parent at the reference size is the identity', () {
      for (final c in AxisConstraint.values) {
        final inv = inverseResolveAxisConstraint(
          constraint: c,
          offset: 30,
          size: 40,
          reference: 200,
          parent: 200,
        );
        expect((inv.position, inv.size, inv.exact), (30.0, 40.0, true));
      }
    });

    test('known values for each constraint (R = 100, P = 300)', () {
      InverseAxisPlacement inv(AxisConstraint c) =>
          inverseResolveAxisConstraint(
            constraint: c,
            offset: 220,
            size: 50,
            reference: 100,
            parent: 300,
          );
      // start: as is.
      expect(inv(AxisConstraint.start).position, 220);
      // end: right margin 300 − 220 − 50 = 30 → x = 100 − 30 − 50 = 20.
      expect(inv(AxisConstraint.end).position, 20);
      // center: child centre 245 is 95 right of 150 → x = 50 + 95 − 25.
      expect(inv(AxisConstraint.center).position, 120);
      // stretch: margins 220 and 30 → stored w = 100 − 220 − 30 = −150.
      expect(inv(AxisConstraint.stretch).size, -150);
      // scale ×3.
      final s = inv(AxisConstraint.scale);
      expect((s.position, s.size), closeToPair(220 / 3, 50 / 3));
    });
  });

  group('non-invertible cases', () {
    test('a size outside min/max reaches the clamped size, inexact', () {
      for (final c in AxisConstraint.values) {
        final inv = inverseResolveAxisConstraint(
          constraint: c,
          offset: 10,
          size: 500,
          reference: 400,
          parent: 800,
          max: 200,
        );
        expect(inv.exact, isFalse);
        final fwd = resolveAxisConstraint(
          constraint: c,
          position: inv.position,
          size: inv.size,
          reference: 400,
          parent: 800,
          max: 200,
        );
        expect(close(fwd.offset, 10) && close(fwd.size, 200), isTrue);
      }
    });

    test('a size on a clamp bound is exact', () {
      final inv = inverseResolveAxisConstraint(
        constraint: AxisConstraint.stretch,
        offset: 0,
        size: 120,
        reference: 400,
        parent: 800,
        min: 120,
      );
      expect(inv.exact, isTrue);
    });

    test('a negative size is unreachable', () {
      final inv = inverseResolveAxisConstraint(
        constraint: AxisConstraint.start,
        offset: 0,
        size: -5,
        reference: 100,
        parent: 100,
      );
      expect((inv.size, inv.exact), (0.0, false));
    });

    test('hugging content fixes the size', () {
      for (final c in [
        AxisConstraint.start,
        AxisConstraint.end,
        AxisConstraint.center,
      ]) {
        final exact = inverseResolveAxisConstraint(
          constraint: c,
          offset: 40,
          size: 80,
          reference: 300,
          parent: 500,
          contentSize: 80,
        );
        expect(exact.exact, isTrue);
        final fwd = resolveAxisConstraint(
          constraint: c,
          position: exact.position,
          size: exact.size,
          reference: 300,
          parent: 500,
          contentSize: 80,
        );
        expect(close(fwd.offset, 40) && close(fwd.size, 80), isTrue);
        final other = inverseResolveAxisConstraint(
          constraint: c,
          offset: 40,
          size: 120,
          reference: 300,
          parent: 500,
          contentSize: 80,
        );
        expect((other.size, other.exact), (80.0, false));
      }
    });

    test('scale into a zero-size parent', () {
      final inv = inverseResolveAxisConstraint(
        constraint: AxisConstraint.scale,
        offset: 10,
        size: 20,
        reference: 100,
        parent: 0,
      );
      expect(inv.exact, isFalse);
      expect(
        inverseResolveAxisConstraint(
          constraint: AxisConstraint.scale,
          offset: 0,
          size: 0,
          reference: 100,
          parent: 0,
        ).exact,
        isTrue,
      );
    });
  });

  test('inverseResolveConstraints round-trips both axes', () {
    final r = Random(3);
    double rnd(double lo, double hi) => lo + r.nextDouble() * (hi - lo);
    for (var i = 0; i < 5000; i++) {
      final cons = ir.Constraints(
        horizontal: ir.HorizontalConstraint.values[r.nextInt(5)],
        vertical: ir.VerticalConstraint.values[r.nextInt(5)],
      );
      final desired = Rect.fromLTWH(
        rnd(-500, 500),
        rnd(-500, 500),
        rnd(0, 800),
        rnd(0, 800),
      );
      final rw = rnd(1, 2000), rh = rnd(1, 2000);
      final pw = rnd(1, 3000), ph = rnd(1, 3000);
      final inv = inverseResolveConstraints(
        constraints: cons,
        desired: desired,
        referenceWidth: rw,
        referenceHeight: rh,
        parentWidth: pw,
        parentHeight: ph,
      );
      expect(inv.exact, isTrue);
      final fwd = resolveConstraints(
        constraints: cons,
        stored: inv.stored,
        referenceWidth: rw,
        referenceHeight: rh,
        parentWidth: pw,
        parentHeight: ph,
      );
      expect(
        close(fwd.left, desired.left) &&
            close(fwd.top, desired.top) &&
            close(fwd.width, desired.width) &&
            close(fwd.height, desired.height),
        isTrue,
        reason: '$cons $desired → ${inv.stored} → $fwd',
      );
    }
  });
}

Matcher closeToPair(double a, double b) => predicate<(double, double)>(
  (p) => close(p.$1, a) && close(p.$2, b),
  'close to ($a, $b)',
);
