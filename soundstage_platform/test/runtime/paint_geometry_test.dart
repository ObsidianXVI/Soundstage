// Pure geometry of the paint pipeline (T0.5): image placement, gradient
// handles, stroke bands, dashes and image filters.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/src/paint/gradient.dart';
import 'package:soundstage_platform/runtime/src/paint/image_filters.dart';
import 'package:soundstage_platform/runtime/src/paint/image_scale.dart';
import 'package:soundstage_platform/runtime/src/paint/outline.dart';
import 'package:soundstage_platform/runtime/src/paint/stroke_geometry.dart';

ir.StagePoint pt(double x, double y) => ir.StagePoint(x: x, y: y);

void expectNear(Offset actual, Offset expected) {
  expect((actual - expected).distance, lessThan(1e-9), reason: '$actual');
}

void main() {
  group('scale modes: destination and source rects (§6)', () {
    // (name, box, image, mode, focal, crop, tileScale, expected src, expected dst)
    final cases =
        <
          (
            String,
            Size,
            Size,
            ir.ImageScaleMode,
            ir.StagePoint,
            ir.StageRect?,
            double,
            Rect,
            Rect,
          )
        >[
          // fill
          (
            'fill, same aspect',
            const Size(200, 100),
            const Size(400, 200),
            ir.ImageScaleMode.fill,
            pt(0.5, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 400, 200),
            const Rect.fromLTWH(0, 0, 200, 100),
          ),
          (
            'fill, wide image in square, centred',
            const Size(100, 100),
            const Size(200, 100),
            ir.ImageScaleMode.fill,
            pt(0.5, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 200, 100),
            const Rect.fromLTWH(-50, 0, 200, 100),
          ),
          (
            'fill, focal left edge clamps to the left',
            const Size(100, 100),
            const Size(200, 100),
            ir.ImageScaleMode.fill,
            pt(0, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 200, 100),
            const Rect.fromLTWH(0, 0, 200, 100),
          ),
          (
            'fill, focal right edge clamps to the right',
            const Size(100, 100),
            const Size(200, 100),
            ir.ImageScaleMode.fill,
            pt(1, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 200, 100),
            const Rect.fromLTWH(-100, 0, 200, 100),
          ),
          (
            'fill, focal beyond 1 clamps like 1',
            const Size(100, 100),
            const Size(200, 100),
            ir.ImageScaleMode.fill,
            pt(3, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 200, 100),
            const Rect.fromLTWH(-100, 0, 200, 100),
          ),
          (
            'fill, focal 0.75 sits near the centre',
            const Size(100, 100),
            const Size(200, 100),
            ir.ImageScaleMode.fill,
            pt(0.75, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 200, 100),
            const Rect.fromLTWH(-100, 0, 200, 100),
          ),
          (
            'fill, tall image in wide box, focal at the top',
            const Size(200, 100),
            const Size(100, 200),
            ir.ImageScaleMode.fill,
            pt(0.5, 0),
            null,
            1,
            const Rect.fromLTWH(0, 0, 100, 200),
            const Rect.fromLTWH(0, 0, 200, 400),
          ),
          // fit
          (
            'fit, wide image in square, centred',
            const Size(100, 100),
            const Size(200, 100),
            ir.ImageScaleMode.fit,
            pt(0.5, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 200, 100),
            const Rect.fromLTWH(0, 25, 100, 50),
          ),
          (
            'fit, letterbox aligned to the start',
            const Size(100, 100),
            const Size(200, 100),
            ir.ImageScaleMode.fit,
            pt(0, 0),
            null,
            1,
            const Rect.fromLTWH(0, 0, 200, 100),
            const Rect.fromLTWH(0, 0, 100, 50),
          ),
          (
            'fit, letterbox aligned to the end',
            const Size(100, 100),
            const Size(200, 100),
            ir.ImageScaleMode.fit,
            pt(1, 1),
            null,
            1,
            const Rect.fromLTWH(0, 0, 200, 100),
            const Rect.fromLTWH(0, 50, 100, 50),
          ),
          (
            'fit, tall image pillarboxed at focal 0.2',
            const Size(200, 100),
            const Size(100, 200),
            ir.ImageScaleMode.fit,
            pt(0.2, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 100, 200),
            const Rect.fromLTWH(30, 0, 50, 100),
          ),
          (
            'fit, an image smaller than the box scales up',
            const Size(300, 300),
            const Size(30, 10),
            ir.ImageScaleMode.fit,
            pt(0.5, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 30, 10),
            const Rect.fromLTWH(0, 100, 300, 100),
          ),
          // crop
          (
            'crop, rect mapped onto the box (stretches)',
            const Size(200, 100),
            const Size(400, 200),
            ir.ImageScaleMode.crop,
            pt(0.5, 0.5),
            const ir.StageRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5),
            1,
            const Rect.fromLTRB(100, 100, 300, 200),
            const Rect.fromLTWH(0, 0, 200, 100),
          ),
          (
            'crop, a different aspect still maps exactly',
            const Size(50, 200),
            const Size(400, 200),
            ir.ImageScaleMode.crop,
            pt(0.5, 0.5),
            const ir.StageRect(x: 0, y: 0, width: 1, height: 0.25),
            1,
            const Rect.fromLTRB(0, 0, 400, 50),
            const Rect.fromLTWH(0, 0, 50, 200),
          ),
          (
            'crop, a rect past the image is clamped',
            const Size(100, 100),
            const Size(400, 200),
            ir.ImageScaleMode.crop,
            pt(0.5, 0.5),
            const ir.StageRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5),
            1,
            const Rect.fromLTRB(320, 160, 400, 200),
            const Rect.fromLTWH(0, 0, 100, 100),
          ),
          (
            'crop without a rect shows the whole image',
            const Size(100, 100),
            const Size(400, 200),
            ir.ImageScaleMode.crop,
            pt(0.5, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 400, 200),
            const Rect.fromLTWH(0, 0, 100, 100),
          ),
          // tile
          (
            'tile, scale 1 uses the intrinsic size',
            const Size(500, 500),
            const Size(100, 50),
            ir.ImageScaleMode.tile,
            pt(0.5, 0.5),
            null,
            1,
            const Rect.fromLTWH(0, 0, 100, 50),
            const Rect.fromLTWH(0, 0, 100, 50),
          ),
          (
            'tile, scale 0.5 halves the cell',
            const Size(500, 500),
            const Size(100, 50),
            ir.ImageScaleMode.tile,
            pt(0.5, 0.5),
            null,
            0.5,
            const Rect.fromLTWH(0, 0, 100, 50),
            const Rect.fromLTWH(0, 0, 50, 25),
          ),
          (
            'tile, scale 2 doubles the cell',
            const Size(500, 500),
            const Size(100, 50),
            ir.ImageScaleMode.tile,
            pt(0.5, 0.5),
            null,
            2,
            const Rect.fromLTWH(0, 0, 100, 50),
            const Rect.fromLTWH(0, 0, 200, 100),
          ),
        ];
    for (final c in cases) {
      test(c.$1, () {
        final p = placeImage(
          box: c.$2,
          image: c.$3,
          mode: c.$4,
          focalPoint: c.$5,
          cropRect: c.$6,
          tileScale: c.$7,
        );
        expect(p.src, c.$8);
        expect(p.dst, c.$9);
        expect(p.tile, c.$4 == ir.ImageScaleMode.tile);
      });
    }

    test('tile uses the original size when the decoded one is a variant', () {
      final p = placeImage(
        box: const Size(500, 500),
        image: const Size(50, 25), // a half-size variant
        intrinsic: const Size(100, 50),
        mode: ir.ImageScaleMode.tile,
        tileScale: 1,
      );
      expect(p.dst, const Rect.fromLTWH(0, 0, 100, 50));
      expect(p.src, const Rect.fromLTWH(0, 0, 50, 25));
    });
  });

  group('rotation', () {
    test('quarter turns snap and wrap', () {
      expect(quarterTurnsOf(0), 0);
      expect(quarterTurnsOf(90), 1);
      expect(quarterTurnsOf(180), 2);
      expect(quarterTurnsOf(270), 3);
      expect(quarterTurnsOf(360), 0);
      expect(quarterTurnsOf(-90), 3);
      expect(quarterTurnsOf(100), 1);
    });

    test('odd turns swap the displayed size', () {
      expect(rotatedImageSize(const Size(200, 100), 0), const Size(200, 100));
      expect(rotatedImageSize(const Size(200, 100), 1), const Size(100, 200));
      expect(rotatedImageSize(const Size(200, 100), 2), const Size(200, 100));
      expect(rotatedImageSize(const Size(200, 100), 3), const Size(100, 200));
    });

    Offset map(Matrix4 m, double x, double y) =>
        MatrixUtils.transformPoint(m, Offset(x, y));

    test('the transform turns the image clockwise into its placement', () {
      const decoded = Size(200, 100);
      const placement = ImagePlacement(
        src: Rect.fromLTWH(0, 0, 100, 200),
        dst: Rect.fromLTWH(0, 0, 100, 200),
      );
      final m = imageTransform(placement, decoded, 1);
      // Top-left goes to top-right, top-right to bottom-right.
      expectNear(map(m, 0, 0), const Offset(100, 0));
      expectNear(map(m, 200, 0), const Offset(100, 200));
      expectNear(map(m, 0, 100), const Offset(0, 0));
      expectNear(map(m, 200, 100), const Offset(0, 200));
    });

    test('180 turns flip both axes', () {
      const decoded = Size(200, 100);
      const placement = ImagePlacement(
        src: Rect.fromLTWH(0, 0, 200, 100),
        dst: Rect.fromLTWH(0, 0, 200, 100),
      );
      final m = imageTransform(placement, decoded, 2);
      expectNear(map(m, 0, 0), const Offset(200, 100));
      expectNear(map(m, 200, 100), const Offset(0, 0));
    });

    test('270 turns top-left to bottom-left', () {
      const decoded = Size(200, 100);
      const placement = ImagePlacement(
        src: Rect.fromLTWH(0, 0, 100, 200),
        dst: Rect.fromLTWH(0, 0, 100, 200),
      );
      final m = imageTransform(placement, decoded, 3);
      expectNear(map(m, 0, 0), const Offset(0, 200));
      expectNear(map(m, 200, 0), const Offset(0, 0));
    });

    test('a rotated fill is placed on the rotated size', () {
      // 200x100 image rotated 90 is 100x200: it covers a 100x100 box at
      // scale 1, centred vertically.
      final rotated = rotatedImageSize(const Size(200, 100), 1);
      final p = placeImage(
        box: const Size(100, 100),
        image: rotated,
        mode: ir.ImageScaleMode.fill,
      );
      expect(p.dst, const Rect.fromLTWH(0, -50, 100, 200));
      final m = imageTransform(p, const Size(200, 100), 1);
      // The image's top-left lands at the top-right of the placement.
      expectNear(map(m, 0, 0), const Offset(100, -50));
    });

    test('a crop maps its rect onto the box through the transform', () {
      const decoded = Size(400, 200);
      final p = placeImage(
        box: const Size(100, 100),
        image: decoded,
        mode: ir.ImageScaleMode.crop,
        cropRect: const ir.StageRect(x: 0.5, y: 0, width: 0.5, height: 1),
      );
      final m = imageTransform(p, decoded, 0);
      expectNear(map(m, 200, 0), const Offset(0, 0));
      expectNear(map(m, 400, 200), const Offset(100, 100));
    });
  });

  group('gradient handles map to the node box (§5)', () {
    const size = Size(200, 100);

    test('linear: start and end handles are unit x 0 and 1', () {
      final b = gradientBasis(
        ir.GradientHandles(start: pt(0.5, 0), end: pt(0.5, 1)),
        size,
      );
      expect(b.origin, const Offset(100, 0));
      expect(b.toBox(0, 0), const Offset(100, 0));
      expect(b.toBox(1, 0), const Offset(100, 100));
      expect(b.toBox(0.5, 0), const Offset(100, 50));
    });

    test('handles are normalised: the same handles scale with the box', () {
      final h = ir.GradientHandles(start: pt(0, 0), end: pt(1, 1));
      final a = gradientBasis(h, const Size(200, 100));
      final b = gradientBasis(h, const Size(400, 300));
      expect(a.toBox(1, 0), const Offset(200, 100));
      expect(b.toBox(1, 0), const Offset(400, 300));
    });

    test('an unset width handle is perpendicular in pixel space', () {
      final b = gradientBasis(
        ir.GradientHandles(start: pt(0, 0), end: pt(1, 0)),
        size,
      );
      expect(b.u, const Offset(200, 0));
      expect(b.v, const Offset(0, 200)); // same length as u, turned 90° cw
    });

    test('radial: centre, radius along the end handle, width handle axis', () {
      final b = gradientBasis(
        ir.GradientHandles(
          start: pt(0.5, 0.5),
          end: pt(1, 0.5),
          width: pt(0.5, 1),
        ),
        size,
      );
      expect(b.origin, const Offset(100, 50));
      expect(b.u, const Offset(100, 0));
      expect(b.v, const Offset(0, 50));
      expect(b.toBox(0, 1), const Offset(100, 100));
      // The inverse takes box points back to unit space.
      expect(b.toUnit(const Offset(200, 50)), const Offset(1, 0));
      expect(b.toUnit(const Offset(100, 0)), const Offset(0, -1));
    });

    test('a rotated radial keeps its axes from the handles', () {
      final b = gradientBasis(
        ir.GradientHandles(
          start: pt(0.5, 0.5),
          end: pt(0.5, 0),
          width: pt(1, 0.5),
        ),
        size,
      );
      expect(b.u, const Offset(0, -50));
      expect(b.v, const Offset(100, 0));
      expect(b.toBox(1, 0), const Offset(100, 0));
      expect(b.toBox(0, 1), const Offset(200, 50));
    });

    test('the matrix is the basis in column-major order', () {
      final b = gradientBasis(
        ir.GradientHandles(
          start: pt(0.5, 0.5),
          end: pt(1, 0.5),
          width: pt(0.5, 1),
        ),
        size,
      );
      final m = b.matrix;
      expect(m.sublist(0, 2), [100, 0]);
      expect(m.sublist(4, 6), [0, 50]);
      expect(m.sublist(12, 14), [100, 50]);
      expect(m[15], 1);
    });

    test('every kind but diamond builds a shader', () {
      const stops = [
        ir.ColorStop(position: 0, color: ir.StageColor.black),
        ir.ColorStop(position: 1, color: ir.StageColor.white),
      ];
      final handles = ir.GradientHandles(
        start: pt(0.5, 0.5),
        end: pt(1, 0.5),
        width: pt(0.5, 1),
      );
      for (final kind in ir.GradientKind.values) {
        final shader = gradientShader(
          ir.GradientPaint(id: 'g', stops: stops, kind: kind, handles: handles),
          size,
        );
        if (kind == ir.GradientKind.diamond) {
          expect(shader, isNull);
        } else {
          expect(shader, isNotNull, reason: '$kind');
        }
      }
    });

    test('stops are sorted, clamped, and carry the paint opacity', () {
      final s = normalizedStops(const [
        ir.ColorStop(
          position: 1.5,
          color: ir.StageColor(r: 1, g: 0, b: 0, a: 1),
        ),
        ir.ColorStop(
          position: -1,
          color: ir.StageColor(r: 0, g: 0, b: 1, a: 1),
        ),
      ], 0.5);
      expect(s.positions, [0, 1]);
      expect(s.colors.first.b, 1);
      expect(s.colors.last.r, 1);
      expect(s.colors.first.a, closeTo(0.5, 1e-9));
    });

    test('one stop becomes a flat gradient', () {
      final s = normalizedStops(const [
        ir.ColorStop(position: 0.3, color: ir.StageColor.white),
      ]);
      expect(s.colors, hasLength(2));
      expect(s.positions, [0, 1]);
    });
  });

  group('diamond gradient mesh', () {
    const size = Size(200, 100);
    final handles = ir.GradientHandles(
      start: pt(0.5, 0.5),
      end: pt(1, 0.5),
      width: pt(0.5, 1),
    );
    ir.GradientPaint paint(List<ir.ColorStop> stops) => ir.GradientPaint(
      id: 'd',
      kind: ir.GradientKind.diamond,
      stops: stops,
      handles: handles,
    );
    const white = ir.StageColor.white;
    const black = ir.StageColor.black;

    test('rings sit at the stop positions, at the handle distance', () {
      final mesh = diamondMesh(
        paint(const [
          ir.ColorStop(position: 0, color: white),
          ir.ColorStop(position: 0.5, color: black),
          ir.ColorStop(position: 1, color: white),
        ]),
        size,
      )!;
      // Rings: 0, 0.5, 1, then the outer ring that covers the box.
      expect(mesh.rings.take(3), [0, 0.5, 1]);
      expect(mesh.rings.last, greaterThanOrEqualTo(2));
      Offset v(int ring, int j) => Offset(
        mesh.positions[ring * 8 + j * 2],
        mesh.positions[ring * 8 + j * 2 + 1],
      );
      // Ring 1 (t = 0.5): the diamond's four tips.
      expect(v(1, 0), const Offset(150, 50));
      expect(v(1, 1), const Offset(100, 75));
      expect(v(1, 2), const Offset(50, 50));
      expect(v(1, 3), const Offset(100, 25));
      // Ring 2 (t = 1) reaches the end handle.
      expect(v(2, 0), const Offset(200, 50));
    });

    test('the outer ring covers every box corner', () {
      final mesh = diamondMesh(
        paint(const [
          ir.ColorStop(position: 0, color: white),
          ir.ColorStop(position: 1, color: black),
        ]),
        size,
      )!;
      final basis = gradientBasis(handles, size);
      final outer = mesh.rings.last;
      for (final c in [
        Offset.zero,
        const Offset(200, 0),
        const Offset(0, 100),
        const Offset(200, 100),
      ]) {
        final q = basis.toUnit(c)!;
        expect(q.dx.abs() + q.dy.abs(), lessThanOrEqualTo(outer));
      }
    });

    test('vertex colours are the stop colours; triangles index in range', () {
      final mesh = diamondMesh(
        paint(const [
          ir.ColorStop(position: 0.25, color: white),
          ir.ColorStop(position: 0.75, color: black),
        ]),
        size,
      )!;
      // A ring at 0 (flat colour up to the first stop), the two stops, outer.
      expect(mesh.rings.length, 4);
      expect(
        mesh.colors[0],
        const ui.Color(0xFFFFFFFF).toARGB32().toSigned(32),
      );
      expect(
        mesh.colors[8],
        const ui.Color(0xFF000000).toARGB32().toSigned(32),
      );
      expect(mesh.indices.every((i) => i < mesh.vertexCount), isTrue);
      expect(mesh.indices.length, (mesh.rings.length - 1) * 4 * 6);
    });

    test('a degenerate basis has no mesh', () {
      final m = diamondMesh(
        ir.GradientPaint(
          id: 'd',
          kind: ir.GradientKind.diamond,
          stops: const [ir.ColorStop(position: 0, color: white)],
          handles: ir.GradientHandles(start: pt(0.5, 0.5), end: pt(0.5, 0.5)),
        ),
        size,
      );
      expect(m, isNull);
    });

    test('rendered pixels follow the L1 norm of the unit space', () async {
      const box = Size(100, 100);
      final p = ir.GradientPaint(
        id: 'd',
        kind: ir.GradientKind.diamond,
        stops: const [
          ir.ColorStop(position: 0, color: white),
          ir.ColorStop(position: 1, color: black),
        ],
        handles: ir.GradientHandles(
          start: pt(0.5, 0.5),
          end: pt(1, 0.5),
          width: pt(0.5, 1),
        ),
      );
      final mesh = diamondMesh(p, box)!;
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final vertices = mesh.toVertices();
      canvas.drawVertices(vertices, ui.BlendMode.src, Paint());
      final image = await rec.endRecording().toImage(100, 100);
      final bytes = (await image.toByteData())!;
      double gray(int x, int y) => bytes.getUint8((y * 100 + x) * 4) / 255;
      // Unit coordinates are (dx / 50, dy / 50); the value is 1 - |x| - |y|.
      for (final (x, y) in [
        (50, 50),
        (75, 50),
        (50, 75),
        (62, 62),
        (30, 45),
        (50, 20),
      ]) {
        final d = ((x + 0.5 - 50).abs() + (y + 0.5 - 50).abs()) / 50;
        expect(
          gray(x, y),
          closeTo(math.max(0, 1 - d), 0.02),
          reason: '($x,$y)',
        );
      }
      // Beyond the last stop the colour is clamped to it.
      expect(gray(2, 2), closeTo(0, 0.01));
      vertices.dispose();
      image.dispose();
    });
  });

  group('stroke geometry (§5)', () {
    final box = StageOutline.box(
      const Size(100, 60),
      const ir.CornerRadius.uniform(),
    );

    test('inside grows inwards from the outline', () {
      final b = strokeBand(
        box,
        ir.StrokeAlign.inside,
        const SideWeights.uniform(10),
      );
      expect(b.outer.bounds, const Rect.fromLTRB(0, 0, 100, 60));
      expect(b.inner.bounds, const Rect.fromLTRB(10, 10, 90, 50));
    });

    test('centre straddles the outline', () {
      final b = strokeBand(
        box,
        ir.StrokeAlign.center,
        const SideWeights.uniform(10),
      );
      expect(b.outer.bounds, const Rect.fromLTRB(-5, -5, 105, 65));
      expect(b.inner.bounds, const Rect.fromLTRB(5, 5, 95, 55));
    });

    test('outside grows outwards from the outline', () {
      final b = strokeBand(
        box,
        ir.StrokeAlign.outside,
        const SideWeights.uniform(10),
      );
      expect(b.outer.bounds, const Rect.fromLTRB(-10, -10, 110, 70));
      expect(b.inner.bounds, const Rect.fromLTRB(0, 0, 100, 60));
    });

    test('per-side weights move each side by its own weight', () {
      const w = SideWeights(10, 2, 6, 0);
      final inside = strokeBand(box, ir.StrokeAlign.inside, w);
      expect(inside.inner.bounds, const Rect.fromLTRB(0, 10, 98, 54));
      final outside = strokeBand(box, ir.StrokeAlign.outside, w);
      expect(outside.outer.bounds, const Rect.fromLTRB(0, -10, 102, 66));
      final centre = strokeBand(box, ir.StrokeAlign.center, w);
      expect(centre.outer.bounds, const Rect.fromLTRB(0, -5, 101, 63));
      expect(centre.inner.bounds, const Rect.fromLTRB(0, 5, 99, 57));
    });

    test('the band path covers the stroke and not the hole', () {
      const w = SideWeights(10, 2, 6, 0);
      final path = strokeBandPath(box, ir.StrokeAlign.inside, w);
      expect(path.contains(const Offset(50, 5)), isTrue); // top band
      expect(path.contains(const Offset(99, 30)), isTrue); // right band
      expect(path.contains(const Offset(50, 57)), isTrue); // bottom band
      expect(path.contains(const Offset(1, 30)), isFalse); // left has none
      expect(path.contains(const Offset(50, 30)), isFalse); // the hole
      expect(path.contains(const Offset(50, -5)), isFalse); // outside
    });

    test('inside corner radii shrink concentrically', () {
      final round = StageOutline.box(
        const Size(100, 60),
        const ir.CornerRadius.uniform(20),
      );
      final b = strokeBand(
        round,
        ir.StrokeAlign.inside,
        const SideWeights.uniform(8),
      );
      for (final r in b.inner.radii!) {
        expect(r, const Radius.circular(12));
      }
      final o = strokeBand(
        round,
        ir.StrokeAlign.outside,
        const SideWeights.uniform(8),
      );
      for (final r in o.outer.radii!) {
        expect(r, const Radius.circular(28));
      }
    });

    test('a radius never goes negative when the stroke exceeds it', () {
      final round = StageOutline.box(
        const Size(100, 60),
        const ir.CornerRadius.uniform(4),
      );
      final b = strokeBand(
        round,
        ir.StrokeAlign.inside,
        const SideWeights.uniform(10),
      );
      for (final r in b.inner.radii!) {
        expect(r, Radius.zero);
      }
    });

    test('per-side weights make elliptical inner radii', () {
      final round = StageOutline.box(
        const Size(100, 60),
        const ir.CornerRadius.uniform(20),
      );
      final b = strokeBand(
        round,
        ir.StrokeAlign.inside,
        const SideWeights(10, 0, 0, 0),
      );
      expect(b.inner.radii![0], const Radius.elliptical(20, 10)); // top-left
      expect(b.inner.radii![2], const Radius.circular(20)); // bottom-right
    });

    test('side weights read from the IR', () {
      expect(
        sideWeights(const ir.StrokeWeight.uniform(3)),
        const SideWeights.uniform(3),
      );
      expect(
        sideWeights(
          const ir.StrokeWeight.perSide(top: 1, right: 2, bottom: 3, left: 4),
        ),
        const SideWeights(1, 2, 3, 4),
      );
      expect(sideWeights(const ir.StrokeWeight.uniform(-2)).isZero, isTrue);
    });

    test('inflating by a spread keeps corners concentric', () {
      final round = StageOutline.box(
        const Size(100, 60),
        const ir.CornerRadius.uniform(10),
      );
      final g = round.inflated(6)!;
      expect(g.bounds, const Rect.fromLTRB(-6, -6, 106, 66));
      expect(g.radii![0], const Radius.circular(16));
      final s = round.inflated(-4)!;
      expect(s.bounds, const Rect.fromLTRB(4, 4, 96, 56));
      expect(s.radii![0], const Radius.circular(6));
    });
  });

  group('dashes', () {
    double length(Path p) =>
        p.computeMetrics().fold(0.0, (a, m) => a + m.length);
    final line = Path()
      ..moveTo(0, 0)
      ..lineTo(100, 0);

    test('on/off lengths split the path', () {
      final d = dashPath(line, [10, 10]);
      expect(length(d), closeTo(50, 1e-4));
      expect(d.computeMetrics().length, 5);
    });

    test('an odd pattern repeats to be even', () {
      expect(length(dashPath(line, [10])), closeTo(50, 1e-4));
    });

    test('the phase shifts the pattern', () {
      final d = dashPath(line, [10, 10], phase: 5);
      expect(length(d), closeTo(50, 1e-4));
      expect(d.computeMetrics().length, 6);
    });

    test('an empty or all-zero pattern leaves the path alone', () {
      expect(dashPath(line, []), same(line));
      expect(dashPath(line, [0, 0]), same(line));
    });

    test('closed paths are dashed too', () {
      final box = Path()..addRect(const Rect.fromLTWH(0, 0, 40, 40));
      expect(length(dashPath(box, [8, 8])), closeTo(80, 1e-4));
    });
  });

  group('image filters (§6)', () {
    List<double> apply(List<double> m, List<double> rgba) {
      final out = <double>[];
      for (var row = 0; row < 4; row++) {
        var v = m[row * 5 + 4];
        for (var k = 0; k < 4; k++) {
          v += m[row * 5 + k] * rgba[k];
        }
        out.add(v);
      }
      return out;
    }

    test('no adjustments is no matrix', () {
      expect(imageFilterMatrix(const ir.ImageFilters()), isNull);
      expect(imageColorFilter(const ir.ImageFilters()), isNull);
    });

    test('exposure is a 2^e gain', () {
      final m = imageFilterMatrix(const ir.ImageFilters(exposure: 1))!;
      expect(m[0], closeTo(2, 1e-9));
      expect(m[6], closeTo(2, 1e-9));
      expect(m[12], closeTo(2, 1e-9));
      expect(m[18], 1); // alpha untouched
      final m2 = imageFilterMatrix(const ir.ImageFilters(exposure: -1))!;
      expect(m2[0], closeTo(0.5, 1e-9));
    });

    test('contrast pivots on mid grey', () {
      final m = imageFilterMatrix(const ir.ImageFilters(contrast: 0.5))!;
      expect(m[0], closeTo(1.5, 1e-9));
      expect(m[4], closeTo(-0.25, 1e-9));
      final mid = apply(m, [0.5, 0.5, 0.5, 1]);
      expect(mid[0], closeTo(0.5, 1e-9));
      final dark = apply(m, [0.2, 0.2, 0.2, 1]);
      expect(dark[0], closeTo(0.05, 1e-9));
    });

    test('full desaturation is Rec. 709 luma', () {
      final m = imageFilterMatrix(const ir.ImageFilters(saturation: -1))!;
      final c = apply(m, [1, 0, 0, 1]);
      expect(c[0], closeTo(0.2126, 1e-9));
      expect(c[1], closeTo(0.2126, 1e-9));
      expect(c[2], closeTo(0.2126, 1e-9));
      final g = apply(m, [0, 1, 0, 1]);
      expect(g[0], closeTo(0.7152, 1e-9));
    });

    test('saturation +1 doubles the distance from luma', () {
      final m = imageFilterMatrix(const ir.ImageFilters(saturation: 1))!;
      final c = apply(m, [1, 0, 0, 1]);
      expect(c[0], closeTo(0.2126 + 2 * (1 - 0.2126), 1e-9));
      expect(c[1], closeTo(0.2126 - 2 * 0.2126, 1e-9));
    });

    test('temperature warms red and cools blue; tint moves green', () {
      final t = imageFilterMatrix(const ir.ImageFilters(temperature: 0.5))!;
      expect(t[0], closeTo(1.1, 1e-9));
      expect(t[12], closeTo(0.9, 1e-9));
      expect(t[6], 1);
      final n = imageFilterMatrix(const ir.ImageFilters(tint: 0.5))!;
      expect(n[6], closeTo(0.9, 1e-9));
      expect(n[0], 1);
    });

    test('shadows lift the black point and keep white', () {
      final m = imageFilterMatrix(const ir.ImageFilters(shadows: 1))!;
      expect(apply(m, [0, 0, 0, 1])[0], closeTo(0.25, 1e-9));
      expect(apply(m, [1, 1, 1, 1])[0], closeTo(1, 1e-9));
    });

    test('highlights scale the white point and keep black', () {
      final m = imageFilterMatrix(const ir.ImageFilters(highlights: -1))!;
      expect(apply(m, [1, 1, 1, 1])[0], closeTo(0.75, 1e-9));
      expect(apply(m, [0, 0, 0, 1])[0], closeTo(0, 1e-9));
    });

    test('adjustments compose in order: exposure, then contrast', () {
      final m = imageFilterMatrix(
        const ir.ImageFilters(exposure: 1, contrast: 0.5),
      )!;
      // 0.25 -> exposure 0.5 -> contrast 0.5.
      expect(apply(m, [0.25, 0.25, 0.25, 1])[0], closeTo(0.5, 1e-9));
      // 0.4 -> 0.8 -> 1.5*(0.8-0.5)+0.5 = 0.95.
      expect(apply(m, [0.4, 0.4, 0.4, 1])[0], closeTo(0.95, 1e-9));
    });

    test('the Flutter filter scales offsets to 0-255', () {
      final f = imageColorFilter(const ir.ImageFilters(contrast: 0.5));
      expect(f, isNotNull);
      final matrix = Float64List.fromList(
        imageFilterMatrix(const ir.ImageFilters(contrast: 0.5))!,
      );
      expect(matrix[4], closeTo(-0.25, 1e-9));
    });
  });
}
