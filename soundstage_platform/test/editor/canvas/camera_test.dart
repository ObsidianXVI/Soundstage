import 'dart:ui';

import 'package:flutter/rendering.dart' show MatrixUtils;
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

Matcher _near(Offset o) => isA<Offset>()
    .having((p) => p.dx, 'dx', closeTo(o.dx, 1e-9))
    .having((p) => p.dy, 'dy', closeTo(o.dy, 1e-9));

void main() {
  group('CanvasCamera', () {
    test('screen = world × zoom + pan, and back', () {
      const c = CanvasCamera(zoom: 2, panX: 10, panY: -5);
      expect(c.toScreen(const Offset(3, 4)), const Offset(16, 3));
      expect(c.toWorld(const Offset(16, 3)), const Offset(3, 4));
      expect(
        MatrixUtils.transformPoint(c.matrix, const Offset(3, 4)),
        const Offset(16, 3),
      );
      expect(
        c.rectToScreen(const Rect.fromLTWH(0, 0, 10, 10)),
        const Rect.fromLTWH(10, -5, 20, 20),
      );
    });

    test('zooming about a point keeps the world point under it', () {
      const c = CanvasCamera(zoom: 0.5, panX: 30, panY: 40);
      const focal = Offset(200, 150);
      final world = c.toWorld(focal);
      for (final z in [0.1, 1.0, 3.7, 20.0]) {
        final n = c.zoomedAbout(focal, z);
        expect(n.zoom, z);
        expect(n.toScreen(world), _near(focal));
      }
      final s = c.scaledAbout(focal, 4);
      expect(s.zoom, 2);
      expect(s.toScreen(world), _near(focal));
    });

    test('zoom is clamped to 2%–6400%, still about the pointer', () {
      const c = CanvasCamera();
      const focal = Offset(50, 50);
      final big = c.zoomedAbout(focal, 1000);
      expect(big.zoom, kMaxZoom);
      expect(big.toScreen(c.toWorld(focal)), _near(focal));
      final small = c.scaledAbout(focal, 1e-6);
      expect(small.zoom, kMinZoom);
      expect(small.toScreen(c.toWorld(focal)), _near(focal));
      expect(clampZoom(0.02), 0.02);
      expect(clampZoom(64), 64);
    });

    test('framing centres a rect and fits it inside the padding', () {
      const world = Rect.fromLTWH(0, 0, 2000, 900);
      const view = Size(1000, 800);
      final c = CanvasCamera.framing(world, view, padding: 50);
      // Width limits: (1000 - 100) / 2000.
      expect(c.zoom, closeTo(0.45, 1e-12));
      expect(c.toScreen(world.center), _near(const Offset(500, 400)));
      final s = c.rectToScreen(world);
      expect(s.left, closeTo(50, 1e-9));
      expect(s.right, closeTo(950, 1e-9));
      // Tall content is limited by the height.
      final tall = CanvasCamera.framing(
        const Rect.fromLTWH(100, 100, 100, 7000),
        view,
        padding: 50,
      );
      expect(tall.zoom, closeTo(700 / 7000, 1e-12));
      // maxZoom caps small content (initial fit stays at 100%).
      final tiny = CanvasCamera.framing(
        const Rect.fromLTWH(0, 0, 10, 10),
        view,
        maxZoom: 1,
      );
      expect(tiny.zoom, 1);
      // A selection rect at the other end of the zoom range is clamped.
      final speck = CanvasCamera.framing(
        const Rect.fromLTWH(5, 5, 0.01, 0.01),
        view,
      );
      expect(speck.zoom, kMaxZoom);
      expect(
        speck.toScreen(const Offset(5.005, 5.005)),
        _near(view.center(Offset.zero)),
      );
    });

    test('lerp interpolates zoom in log space and keeps the focal line', () {
      const a = CanvasCamera(zoom: 1);
      const focal = Offset(100, 100);
      final b = a.zoomedAbout(focal, 4);
      expect(CanvasCamera.lerp(a, b, 0, focal: focal), a);
      expect(CanvasCamera.lerp(a, b, 1, focal: focal), b);
      final mid = CanvasCamera.lerp(a, b, 0.5, focal: focal);
      expect(mid.zoom, closeTo(2, 1e-12));
      // Zooming about the focal point: it stays put all the way.
      expect(mid.toWorld(focal), _near(a.toWorld(focal)));
    });

    test('panning moves by screen pixels at any zoom', () {
      const c = CanvasCamera(zoom: 3);
      final p = c.panned(const Offset(12, -4));
      expect(p.toScreen(Offset.zero), const Offset(12, -4));
      expect(p.zoom, 3);
    });
  });

  group('artboard layout', () {
    test('1–3 artboards sit side by side, tops aligned, with the gap', () {
      expect(artboardOffsets([1440]), [0]);
      expect(artboardOffsets([1440, 390]), [0, 1440 + kArtboardGap]);
      expect(artboardOffsets([1440, 834, 390], gap: 100), [0, 1540, 2474]);
    });

    ir.Breakpoint bp(String id, {bool primary = false, double w = 100}) =>
        ir.Breakpoint(
          id: id,
          name: id,
          minWidth: w,
          designSize: ir.StageSize(width: w, height: 100),
          primary: primary,
        );

    test('one artboard per primary breakpoint, in document order', () {
      final doc = ir.StageDocument(
        id: 'd',
        breakpoints: [
          bp('desktop', primary: true, w: 1440),
          bp('tablet', w: 834),
          bp('mobile', primary: true, w: 390),
        ],
      );
      expect(artboardBreakpoints(doc).map((b) => b.id), ['desktop', 'mobile']);
      final three = doc.copyWith(
        breakpoints: [
          for (final b in doc.breakpoints) b.copyWith(primary: true),
        ],
      );
      expect(artboardBreakpoints(three).map((b) => b.id), [
        'desktop',
        'tablet',
        'mobile',
      ]);
      // Without a primary breakpoint, the first one gets the artboard.
      final none = doc.copyWith(
        breakpoints: [
          for (final b in doc.breakpoints) b.copyWith(primary: false),
        ],
      );
      expect(artboardBreakpoints(none).map((b) => b.id), ['desktop']);
    });
  });

  group('free width', () {
    test('clamped, and dropped at the design width', () {
      final c = CanvasController();
      addTearDown(c.dispose);
      c.setPreviewWidth('d', 10, designWidth: 1000);
      expect(c.previewWidthOf('d'), kMinPreviewWidth);
      c.setPreviewWidth('d', 1e6, designWidth: 1000);
      expect(c.previewWidthOf('d'), kMaxPreviewWidth);
      c.setPreviewWidth('d', 1000.2, designWidth: 1000);
      expect(c.previewWidthOf('d'), isNull);
      c.setPreviewWidth('d', 700, designWidth: 1000);
      expect(c.previewWidths.value, {'d': 700});
      c.resetPreviewWidth('d');
      expect(c.previewWidths.value, isEmpty);
    });

    test('zoom labels', () {
      expect(CanvasController.zoomLabel(1), '100%');
      expect(CanvasController.zoomLabel(0.4), '40%');
      expect(CanvasController.zoomLabel(0.02), '2.0%');
      expect(CanvasController.zoomLabel(64), '6400%');
    });
  });
}
