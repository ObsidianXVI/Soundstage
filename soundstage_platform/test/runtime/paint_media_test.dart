import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('image fill (§6)', () {
    const box = Size(200, 100);
    const image = Size(400, 400); // scales by 0.5 → 200 × 200

    test('covers the box, centred by default', () {
      expect(
        imageFillRect(box, image, const ir.StagePoint(x: 0.5, y: 0.5)),
        const Rect.fromLTWH(0, -50, 200, 200),
      );
    });
    test('keeps the focal point near the centre', () {
      expect(
        imageFillRect(box, image, const ir.StagePoint(x: 0.5, y: 0.4)),
        const Rect.fromLTWH(0, -30, 200, 200),
      );
    });
    test('clamps so the image never leaves a gap', () {
      expect(
        imageFillRect(box, image, const ir.StagePoint(x: 0.5, y: 0)),
        const Rect.fromLTWH(0, 0, 200, 200),
      );
      expect(
        imageFillRect(box, image, const ir.StagePoint(x: 0.5, y: 1)),
        const Rect.fromLTWH(0, -100, 200, 200),
      );
    });
  });

  group('media', () {
    test('asset:// URIs map to bundle paths', () {
      expect(
        bundledAssetPath('asset://assets/demo/a.png'),
        'assets/demo/a.png',
      );
      expect(bundledAssetPath('https://x/a.png'), isNull);
    });

    test('the smallest variant at least as wide as the target is picked', () {
      final resolver = StageAssetResolver();
      const asset = ir.Asset(
        id: 'a',
        kind: ir.AssetKind.image,
        uri: 'asset://full.png',
        width: 3000,
        variants: [
          ir.AssetVariant(width: 640, uri: 'asset://640.png', format: 'png'),
          ir.AssetVariant(width: 1280, uri: 'asset://1280.png', format: 'png'),
        ],
      );
      expect(resolver.uriFor(asset), 'asset://full.png');
      expect(resolver.uriFor(asset, targetWidth: 500), 'asset://640.png');
      expect(resolver.uriFor(asset, targetWidth: 700), 'asset://1280.png');
      expect(resolver.uriFor(asset, targetWidth: 2000), 'asset://full.png');
    });

    test('the image cache is a size-bounded LRU', () async {
      final cache = StageImageCache(maxBytes: 2 * 10 * 10 * 4);
      Future<ui.Image> img() => createTestImage(width: 10, height: 10);
      cache
        ..put('a', await img())
        ..put('b', await img());
      expect(cache.currentBytes, 800);
      // Touch "a" so "b" is the least recently used.
      expect(cache.obtain('a', img), isNotNull);
      cache.put('c', await img());
      expect(cache.containsImage('a'), isTrue);
      expect(cache.containsImage('b'), isFalse);
      expect(cache.containsImage('c'), isTrue);
      expect(cache.currentBytes, 800);
      cache.clear();
      expect(cache.currentBytes, 0);
    });

    test('a miss loads once and notifies when ready', () async {
      final cache = StageImageCache();
      final image = await createTestImage(width: 4, height: 4);
      var loads = 0;
      var ready = 0;
      Future<ui.Image> load() async {
        loads++;
        return image;
      }

      expect(cache.obtain('k', load, onReady: () => ready++), isNull);
      expect(cache.obtain('k', load, onReady: () => ready++), isNull);
      await pumpEventQueue();
      expect(loads, 1);
      expect(ready, 2);
      expect(cache.obtain('k', load), isNotNull);
      cache.clear();
    });
  });

  group('shapes', () {
    const size = Size(100, 50);
    Rect boundsOf(ir.ShapeGeometry g) => shapeOutline(g, size).path.getBounds();

    test('polygons and stars fill their box', () {
      expect(boundsOf(const ir.ShapeGeometry.polygon()), Offset.zero & size);
      final star = boundsOf(const ir.ShapeGeometry.star());
      expect(star.left, closeTo(0, 1e-9));
      expect(star.right, closeTo(100, 1e-9));
      expect(star.top, closeTo(0, 1e-9));
      expect(star.bottom, closeTo(50, 1e-9));
    });

    test('a quarter arc is a pie slice in the bottom-right quadrant', () {
      final p = shapeOutline(
        const ir.ShapeGeometry.ellipse(arcEnd: 90),
        size,
      ).path;
      expect(p.contains(const Offset(70, 35)), isTrue);
      expect(p.contains(const Offset(30, 35)), isFalse);
      expect(p.contains(const Offset(70, 15)), isFalse);
    });

    test('an inner radius cuts a ring', () {
      final p = shapeOutline(
        const ir.ShapeGeometry.ellipse(innerRadius: 0.5),
        size,
      ).path;
      expect(p.contains(const Offset(50, 25)), isFalse);
      expect(p.contains(const Offset(10, 25)), isTrue);
    });

    test('lines are open and rectangles are boxes', () {
      expect(shapeOutline(const ir.ShapeGeometry.line(), size).closed, isFalse);
      expect(
        shapeOutline(
          const ir.ShapeGeometry.rectangle(),
          size,
          cornerRadius: const ir.CornerRadius.uniform(999),
        ).rrect!.tlRadiusX,
        25, // clamped to half the shorter side
      );
    });

    test('stroke outsets: inside none, center half, outside all', () {
      const paints = [ir.Paint.solid(id: 's', color: ir.StageColor.black)];
      expect(
        strokeOutsetsOf(
          const ir.Stroke(paints: paints, weight: ir.StrokeWeight.uniform(4)),
        ),
        EdgeInsets.zero,
      );
      expect(
        strokeOutsetsOf(
          const ir.Stroke(
            paints: paints,
            weight: ir.StrokeWeight.uniform(4),
            align: ir.StrokeAlign.center,
          ),
        ),
        const EdgeInsets.all(2),
      );
      expect(
        strokeOutsetsOf(
          const ir.Stroke(
            paints: paints,
            weight: ir.StrokeWeight.perSide(left: 2, top: 4),
            align: ir.StrokeAlign.outside,
          ),
        ),
        const EdgeInsets.fromLTRB(2, 4, 0, 0),
      );
      expect(
        strokeOutsetsOf(
          const ir.Stroke(
            weight: ir.StrokeWeight.uniform(4),
            align: ir.StrokeAlign.outside,
          ),
        ),
        EdgeInsets.zero, // no paint, no stroke
      );
    });
  });
}
