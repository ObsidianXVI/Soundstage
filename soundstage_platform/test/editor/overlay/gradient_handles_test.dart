import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/overlay/gradient_handles.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

const _size = Size(200, 100);

Matcher _near(Offset o, [double eps = 1e-6]) => isA<Offset>()
    .having((p) => p.dx, 'dx', closeTo(o.dx, eps))
    .having((p) => p.dy, 'dy', closeTo(o.dy, eps));

Matcher _pt(double x, double y, [double eps = 1e-6]) => isA<ir.StagePoint>()
    .having((p) => p.x, 'x', closeTo(x, eps))
    .having((p) => p.y, 'y', closeTo(y, eps));

double _deg(Offset v) => math.atan2(v.dy, v.dx) * 180 / math.pi;

const _handles = ir.GradientHandles(
  start: ir.StagePoint(x: 0.5, y: 0.5),
  end: ir.StagePoint(x: 1, y: 0.5),
);

void main() {
  group('geometry ↔ normalised values', () {
    test('start/end are the normalised points in pixels; an unset width is '
        'the axis turned 90° clockwise in pixels', () {
      final p = GradientHandlePoints.of(_handles, _size);
      expect(p.start, _near(const Offset(100, 50)));
      expect(p.end, _near(const Offset(200, 50)));
      expect(p.width, _near(const Offset(100, 150)));
      expect(normalizedPoint(p.end, _size), _pt(1, 0.5));
    });

    test('an explicit width handle is used as stored', () {
      final p = GradientHandlePoints.of(
        _handles.copyWith(width: const ir.StagePoint(x: 0.5, y: 0.8)),
        _size,
      );
      expect(p.width, _near(const Offset(100, 80)));
    });

    test('stops sit along start → end and project back', () {
      final p = GradientHandlePoints.of(_handles, _size);
      expect(p.stopPoint(0.25), _near(const Offset(125, 50)));
      expect(p.positionAt(const Offset(150, 70)), closeTo(0.5, 1e-9));
      expect(p.positionAt(const Offset(500, 0)), 1);
      expect(p.distanceToLine(const Offset(150, 70)), closeTo(20, 1e-9));
    });
  });

  group('drags', () {
    for (final kind in ir.GradientKind.values) {
      test('$kind: dragging the end writes the pointer, normalised', () {
        final h = dragGradientHandle(
          _handles,
          kind,
          _size,
          GradientHandleKind.end,
          const Offset(150, 0),
        );
        expect(h.end, _pt(0.75, 0));
        expect(h.start, _handles.start);
        expect(gradientDragFields(_handles, kind, GradientHandleKind.end), {
          GradientHandleKind.end,
        });
      });
    }

    test('linear: the start moves alone', () {
      final h = dragGradientHandle(
        _handles,
        ir.GradientKind.linear,
        _size,
        GradientHandleKind.start,
        const Offset(20, 10),
      );
      expect(h.start, _pt(0.1, 0.1));
      expect(h.end, _handles.end);
    });

    for (final kind in [
      ir.GradientKind.radial,
      ir.GradientKind.angular,
      ir.GradientKind.diamond,
    ]) {
      test('$kind: the centre moves the whole gradient', () {
        final withWidth = _handles.copyWith(
          width: const ir.StagePoint(x: 0.5, y: 0.8),
        );
        final h = dragGradientHandle(
          withWidth,
          kind,
          _size,
          GradientHandleKind.start,
          const Offset(120, 60),
        );
        expect(h.start, _pt(0.6, 0.6));
        expect(h.end, _pt(1.1, 0.6));
        expect(h.width, _pt(0.6, 0.9));
        expect(
          gradientDragFields(withWidth, kind, GradientHandleKind.start),
          GradientHandleKind.values.toSet(),
        );
        // Unset width stays unset (still derived).
        final h2 = dragGradientHandle(
          _handles,
          kind,
          _size,
          GradientHandleKind.start,
          const Offset(120, 60),
        );
        expect(h2.width, const ir.StagePoint());
      });

      test('$kind: the width handle stays perpendicular, at the pointer\'s '
          'distance', () {
        final h = dragGradientHandle(
          _handles,
          kind,
          _size,
          GradientHandleKind.width,
          const Offset(160, 90),
        );
        // Axis along +x; perpendicular (clockwise) is +y; distance 40.
        expect(h.width, _pt(0.5, 0.9));
        final up = dragGradientHandle(
          _handles,
          kind,
          _size,
          GradientHandleKind.width,
          const Offset(100, 20),
        );
        expect(up.width, _pt(0.5, 0.2));
        final p = GradientHandlePoints.of(h, _size);
        final u = p.end - p.start, v = p.width - p.start;
        expect(u.dx * v.dx + u.dy * v.dy, closeTo(0, 1e-6));
      });

      test('$kind: turning the end turns an explicit width with it', () {
        final withWidth = _handles.copyWith(
          width: const ir.StagePoint(x: 0.5, y: 0.9), // 40 px below
        );
        final h = dragGradientHandle(
          withWidth,
          kind,
          _size,
          GradientHandleKind.end,
          const Offset(100, 0), // straight up
        );
        final p = GradientHandlePoints.of(h, _size);
        expect(p.end, _near(const Offset(100, 0), 1e-3));
        // Was +x with width +y (clockwise); now -y, so width is +x.
        expect(p.width, _near(const Offset(140, 50), 1e-3));
      });
    }
  });

  group('Shift snaps the axis to 15°', () {
    test('snapAngle keeps the length and lands on multiples of 15°', () {
      const from = Offset(10, 10);
      for (final to in [
        const Offset(100, 17),
        const Offset(40, 90),
        const Offset(-50, -33),
      ]) {
        final s = snapAngle(from, to);
        expect((s - from).distance, closeTo((to - from).distance, 1e-9));
        final a = _deg(s - from);
        expect((a / 15 - (a / 15).roundToDouble()).abs(), lessThan(1e-9));
      }
      expect(
        snapAngle(from, const Offset(100, 13)),
        _near(const Offset(100.05, 10), 0.01),
      );
    });

    test('end drag with snap: the visual angle is a multiple of 15°', () {
      final h = dragGradientHandle(
        _handles,
        ir.GradientKind.linear,
        _size,
        GradientHandleKind.end,
        const Offset(190, 98),
        snap: true,
      );
      final p = GradientHandlePoints.of(h, _size);
      expect(_deg(p.end - p.start), closeTo(30, 1e-4));
    });
  });

  group('stops', () {
    final paint = const ir.GradientPaint(
      id: 'g',
      stops: [
        ir.ColorStop(position: 0, color: ir.StageColor(r: 0, g: 0, b: 0, a: 1)),
        ir.ColorStop(
          position: 0.5,
          color: ir.StageColor(r: 1, g: 0, b: 0, a: 1),
        ),
        ir.ColorStop(position: 1, color: ir.StageColor(r: 1, g: 1, b: 1, a: 1)),
      ],
    );

    test('a dragged stop stays between its neighbours', () {
      expect(clampStopPosition(paint.stops, 1, 0.9), 0.9);
      expect(clampStopPosition(paint.stops, 1, 1.5), 1);
      expect(clampStopPosition(paint.stops, 1, 0.33333), 0.3333);
      expect(clampStopPosition(paint.stops, 0, 0.7), 0.5);
    });

    test('Alt-click adds a stop coloured as the gradient there, sorted', () {
      final g = gradientWithStopAt(paint, 0.25);
      expect(g.stops.map((s) => s.position), [0, 0.25, 0.5, 1]);
      expect(g.stops[1].color.r, closeTo(0.5, 1e-6));
    });
  });
}
