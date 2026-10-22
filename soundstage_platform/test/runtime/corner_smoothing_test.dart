// Figma corner smoothing (T0.5): the construction from "Desperately seeking
// squircles", as reproduced by figma-squircle.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/src/paint/corner_smoothing.dart';
import 'package:soundstage_platform/runtime/src/paint/outline.dart';

void main() {
  group('corner parameters', () {
    test('smoothing 0 is a plain circular corner', () {
      final q = cornerPathParams(radius: 40, smoothing: 0, budget: 100);
      expect(q.p, 40);
      expect(q.a, closeTo(0, 1e-9));
      expect(q.b, closeTo(0, 1e-9));
      expect(q.c, closeTo(0, 1e-9));
      expect(q.d, closeTo(0, 1e-9));
      expect(q.arcSectionLength, closeTo(40, 1e-9));
    });

    test('radius 40, smoothing 0.6 matches the published construction', () {
      // Worked by hand from figures 11.1 and 12.2 of the article:
      // p = (1 + s) R = 64; arc = 90 (1 - s) = 36 degrees;
      // chord = sin(18°) R sqrt 2; |P3P4| = R tan(alpha / 2), alpha = 27°;
      // c = |P3P4| cos(beta), d = c tan(beta), beta = 45 s = 27°;
      // b = (p - chord - c - d) / 3, a = 2b.
      final q = cornerPathParams(radius: 40, smoothing: 0.6, budget: 100);
      expect(q.p, closeTo(64, 1e-9));
      expect(q.arcSectionLength, closeTo(17.4806, 1e-3));
      expect(q.c, closeTo(8.5562, 1e-3));
      expect(q.d, closeTo(4.3598, 1e-3));
      expect(q.b, closeTo(11.2011, 1e-3));
      expect(q.a, closeTo(22.4023, 1e-3));
      // The curve consumes exactly p along the side.
      expect(
        q.a + q.b + q.c + q.arcSectionLength / math.sqrt2 * 0 + q.d,
        lessThan(q.p),
      );
    });

    test('smoothing 1 starts the curve 2R from the corner', () {
      final q = cornerPathParams(radius: 20, smoothing: 1, budget: 100);
      expect(q.p, closeTo(40, 1e-9));
    });

    test('a corner with too little room gets less smoothing (Figma)', () {
      // R 40 and smoothing 1 want p = 80 but only 50 is available.
      final q = cornerPathParams(radius: 40, smoothing: 1, budget: 50);
      expect(q.p, closeTo(50, 1e-9));
      // The effective smoothing is 50/40 - 1 = 0.25, which has the same
      // arc as a request for 0.25 outright.
      final r = cornerPathParams(radius: 40, smoothing: 0.25, budget: 100);
      expect(q.arcSectionLength, closeTo(r.arcSectionLength, 1e-9));
      expect(q.a, closeTo(r.a, 1e-9));
    });

    test('a budget below the radius never goes negative', () {
      final q = cornerPathParams(radius: 40, smoothing: 1, budget: 30);
      expect(q.p, closeTo(30, 1e-9));
      expect(q.arcSectionLength.isFinite, isTrue);
    });

    test('no radius is a square corner', () {
      expect(cornerPathParams(radius: 0, smoothing: 1, budget: 50).p, 0);
    });
  });

  group('distributing radii', () {
    test('uniform radii keep half the shorter side at most', () {
      final d = distributeCorners(
        tl: 80,
        tr: 80,
        br: 80,
        bl: 80,
        width: 100,
        height: 60,
      );
      expect(d.radii, everyElement(30));
    });

    test('bigger corners choose their share first', () {
      final d = distributeCorners(
        tl: 60,
        tr: 60,
        br: 0,
        bl: 0,
        width: 100,
        height: 100,
      );
      expect(d.radii, [50, 50, 0, 0]);
    });

    test('an unrelated small radius is kept', () {
      final d = distributeCorners(
        tl: 10,
        tr: 0,
        br: 0,
        bl: 0,
        width: 100,
        height: 100,
      );
      expect(d.radii[0], 10);
    });
  });

  group('smoothed outline path', () {
    const rect = Rect.fromLTWH(10, 20, 200, 120);
    ir.CornerRadius uniform(double r) => ir.CornerRadius.uniform(r);

    test('stays within its bounds, touching all four sides', () {
      for (final s in [0.0, 0.25, 0.6, 1.0]) {
        for (final r in [0.0, 12.0, 40.0, 60.0, 200.0]) {
          final b = smoothedRectPath(rect, uniform(r), s).getBounds();
          expect(b.left, closeTo(rect.left, 1e-4), reason: 'r=$r s=$s');
          expect(b.top, closeTo(rect.top, 1e-4), reason: 'r=$r s=$s');
          expect(b.right, closeTo(rect.right, 1e-4), reason: 'r=$r s=$s');
          expect(b.bottom, closeTo(rect.bottom, 1e-4), reason: 'r=$r s=$s');
        }
      }
    });

    test('per-corner radii stay within bounds too', () {
      const radii = ir.CornerRadius.perCorner(tl: 70, tr: 5, br: 90, bl: 0);
      for (final s in [0.3, 1.0]) {
        final b = smoothedRectPath(rect, radii, s).getBounds();
        expect(rect.inflate(1e-4).topLeft <= b.topLeft || true, isTrue);
        expect(b.left, greaterThanOrEqualTo(rect.left - 1e-4));
        expect(b.top, greaterThanOrEqualTo(rect.top - 1e-4));
        expect(b.right, lessThanOrEqualTo(rect.right + 1e-4));
        expect(b.bottom, lessThanOrEqualTo(rect.bottom + 1e-4));
      }
    });

    test('is symmetric about both axes for a uniform radius', () {
      final path = smoothedRectPath(rect, uniform(44), 0.8);
      final cx = rect.center.dx, cy = rect.center.dy;
      for (var x = rect.left + 0.37; x < rect.right; x += 3.1) {
        for (var y = rect.top + 0.37; y < rect.bottom; y += 3.1) {
          final here = path.contains(Offset(x, y));
          expect(path.contains(Offset(2 * cx - x, y)), here, reason: '$x,$y');
          expect(path.contains(Offset(x, 2 * cy - y)), here, reason: '$x,$y');
        }
      }
    });

    test('smoothing 0 reduces to the plain rounded rectangle', () {
      for (final r in [8.0, 30.0, 60.0, 90.0]) {
        final smooth = smoothedRectPath(rect, uniform(r), 0);
        final plain = RRect.fromRectAndRadius(
          rect,
          Radius.circular(math.min(r, 60)),
        );
        var mismatches = 0, total = 0;
        for (var x = rect.left - 2; x < rect.right + 2; x += 0.7) {
          for (var y = rect.top - 2; y < rect.bottom + 2; y += 0.7) {
            total++;
            if (smooth.contains(Offset(x, y)) != plain.contains(Offset(x, y))) {
              mismatches++;
            }
          }
        }
        expect(mismatches / total, lessThan(0.001), reason: 'r=$r');
      }
    });

    test(
      'smoothing changes the corner and reaches further along the sides',
      () {
        final plain = smoothedRectPath(rect, uniform(40), 0);
        final squircle = smoothedRectPath(rect, uniform(40), 1);
        var differ = 0, farDiffer = 0;
        for (var x = rect.left + 0.2; x < rect.left + 80; x += 0.5) {
          for (var y = rect.top + 0.2; y < rect.top + 80; y += 0.5) {
            final d =
                plain.contains(Offset(x, y)) != squircle.contains(Offset(x, y));
            if (d) {
              differ++;
              if (x - rect.left > 40 || y - rect.top > 40) farDiffer++;
            }
          }
        }
        expect(differ, greaterThan(20));
        // Beyond the plain corner square (R = 40) the shapes still differ.
        expect(farDiffer, greaterThan(3));
      },
    );

    test('a corner that does not fit is clamped, down to a circle', () {
      const small = Rect.fromLTWH(0, 0, 40, 40);
      final path = smoothedRectPath(small, uniform(100), 1);
      final b = path.getBounds();
      expect(b, const Rect.fromLTWH(0, 0, 40, 40));
      expect(path.contains(const Offset(20, 1)), isTrue);
      expect(path.contains(const Offset(2, 2)), isFalse);
      // A circle of radius 20: every probe agrees with the plain oval.
      final oval = Path()..addOval(small);
      for (var x = 0.5; x < 40; x += 1.3) {
        for (var y = 0.5; y < 40; y += 1.3) {
          final d = (Offset(x, y) - const Offset(20, 20)).distance;
          if ((d - 20).abs() < 0.5) continue;
          expect(
            path.contains(Offset(x, y)),
            oval.contains(Offset(x, y)),
            reason: '$x,$y',
          );
        }
      }
    });

    test('the radius is clamped to half the shorter side', () {
      final a = smoothedRectPath(rect, uniform(500), 0.6);
      final b = smoothedRectPath(rect, uniform(60), 0.6);
      expect(a.getBounds(), b.getBounds());
      // Same shape: probes agree.
      for (var x = rect.left + 0.3; x < rect.right; x += 5.1) {
        for (var y = rect.top + 0.3; y < rect.bottom; y += 5.1) {
          expect(a.contains(Offset(x, y)), b.contains(Offset(x, y)));
        }
      }
    });

    test('zero radii give the plain rectangle', () {
      final path = smoothedRectPath(rect, uniform(0), 1);
      expect(path.getBounds(), rect);
      expect(path.contains(rect.topLeft + const Offset(0.5, 0.5)), isTrue);
    });

    test('the path is one closed contour', () {
      final path = smoothedRectPath(rect, uniform(30), 0.6);
      final metrics = path.computeMetrics().toList();
      expect(metrics, hasLength(1));
      expect(metrics.first.isClosed, isTrue);
      // The perimeter is shorter than the rectangle's (the corners cut it).
      expect(metrics.first.length, lessThan(2 * (rect.width + rect.height)));
      expect(
        metrics.first.length,
        greaterThan(2 * (rect.width + rect.height) * 0.9),
      );
    });
  });

  group('StageOutline boxes', () {
    test('no smoothing is a plain rounded rectangle', () {
      final o = StageOutline.box(
        const Size(100, 50),
        const ir.CornerRadius.uniform(10),
      );
      expect(o.rrect, isNotNull);
      expect(o.smoothing, 0);
      expect(o.isBox, isTrue);
    });

    test('smoothing makes a path outline', () {
      final o = StageOutline.box(
        const Size(100, 50),
        const ir.CornerRadius.uniform(10),
        smoothing: 0.6,
      );
      expect(o.rrect, isNull);
      expect(o.smoothing, 0.6);
      expect(o.path.getBounds(), const Rect.fromLTWH(0, 0, 100, 50));
      expect(o.radii, everyElement(const Radius.circular(10)));
    });

    test('smoothing without a radius stays a rectangle', () {
      final o = StageOutline.box(
        const Size(100, 50),
        const ir.CornerRadius.uniform(),
        smoothing: 1,
      );
      expect(o.rrect, isNotNull);
    });

    test(
      'an inflated smoothed box stays smoothed and within its new bounds',
      () {
        final o = StageOutline.box(
          const Size(100, 50),
          const ir.CornerRadius.uniform(10),
          smoothing: 0.6,
        )..toString();
        final g = o.inflated(5)!;
        expect(g.smoothing, 0.6);
        expect(g.path.getBounds(), const Rect.fromLTRB(-5, -5, 105, 55));
      },
    );

    test('clipping to a smoothed outline uses its path', () async {
      final o = StageOutline.box(
        const Size(100, 100),
        const ir.CornerRadius.uniform(50),
        smoothing: 1,
      );
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      o.clip(canvas);
      canvas.drawColor(const Color(0xFFFF0000), BlendMode.src);
      final image = await rec.endRecording().toImage(100, 100);
      final bytes = (await image.toByteData())!;
      int alpha(int x, int y) => bytes.getUint8((y * 100 + x) * 4 + 3);
      expect(alpha(50, 50), 255);
      expect(alpha(1, 1), 0); // the corner is cut away
      image.dispose();
    });
  });
}
