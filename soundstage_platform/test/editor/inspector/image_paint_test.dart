import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';
import 'paint_test_utils.dart';

// Assets with https URIs are not loadable in the editor yet, so the
// previews show the dominant-colour placeholder (no decoding in tests).
const _assets = {
  'img1': ir.Asset(
    id: 'img1',
    kind: ir.AssetKind.image,
    uri: 'https://example.com/hills.jpg',
    name: 'Hills',
    width: 1600,
    height: 900,
    placeholder: ir.AssetPlaceholder(
      dominantColor: ir.StageColor(r: 0.2, g: 0.5, b: 0.3),
    ),
  ),
  'img2': ir.Asset(
    id: 'img2',
    kind: ir.AssetKind.image,
    uri: 'https://example.com/beach.jpg',
    name: 'Beach',
    width: 800,
    height: 800,
  ),
  'snd': ir.Asset(
    id: 'snd',
    kind: ir.AssetKind.audio,
    uri: 'https://example.com/a.mp3',
    name: 'Song',
  ),
};

ir.StageDocument _doc([ir.ImagePaint? paint]) => inspectorDoc([
  rect(
    'a',
    w: 200,
    h: 100,
    appearance: ir.Appearance(
      fills: [paint ?? const ir.ImagePaint(id: 'i', assetId: 'img1')],
    ),
  ),
]).copyWith(assets: _assets);

ir.ImagePaint _i(ProviderContainer c) =>
    fillsOf(c, 'a').single as ir.ImagePaint;

int _undo(ProviderContainer c) =>
    c.read(editorControllerProvider.notifier).history.undoDepth;

Future<ProviderContainer> _open(
  WidgetTester tester,
  ir.StageDocument doc, {
  double width = 288,
}) async {
  final c = await pumpPaints(tester, doc, select: {'a'}, width: width);
  await tapKey(tester, 'paint-swatch:i');
  return c;
}

/// The global point at normalised ([x], [y]) of the preview.
Offset _previewAt(WidgetTester tester, double x, double y) {
  final f = find.byKey(const ValueKey('image-preview:i'));
  final tl = tester.getTopLeft(f);
  final s = tester.getSize(f);
  return Offset(tl.dx + x * s.width, tl.dy + y * s.height);
}

Future<void> _mode(WidgetTester tester, String label) =>
    tapOn(tester, find.text(label).last);

void main() {
  testWidgets('the asset chooser lists images and writes assetId', (
    tester,
  ) async {
    final c = await _open(tester, _doc());
    expect(find.text('Hills'), findsOneWidget);
    await tapKey(tester, 'image-asset:i');
    expect(find.text('Beach'), findsOneWidget);
    expect(find.text('Song'), findsNothing, reason: 'images only');
    expect(find.text('Upload…'), findsOneWidget);
    await tapOn(tester, find.text('Beach'));
    expect(_i(c).assetId, 'img2');
  });

  testWidgets('an empty image paint shows the dashed placeholder', (
    tester,
  ) async {
    final c = await _open(
      tester,
      _doc(const ir.ImagePaint(id: 'i', assetId: '')),
    );
    expect(find.byKey(const ValueKey('image-empty:i')), findsOneWidget);
    expect(find.byKey(const ValueKey('image-preview:i')), findsNothing);
    await tapKey(tester, 'image-empty:i');
    await tapOn(tester, find.text('Hills').last);
    expect(_i(c).assetId, 'img1');
  });

  testWidgets('scale modes show their own editors', (tester) async {
    final c = await _open(tester, _doc());
    expect(fieldText('fills.i.focalPoint.x'), findsOneWidget);
    expect(find.byKey(const ValueKey('image-preview:i')), findsOneWidget);
    await _mode(tester, 'Crop');
    expect(_i(c).scaleMode, ir.ImageScaleMode.crop);
    expect(fieldText('fills.i.focalPoint.x'), findsNothing);
    expect(fieldText('fills.i.cropRect.width'), findsOneWidget);
    expect(find.text('Reset crop'), findsOneWidget);
    await _mode(tester, 'Tile');
    expect(fieldText('fills.i.tileScale'), findsOneWidget);
    expect(find.byKey(const ValueKey('image-preview:i')), findsNothing);
    await _mode(tester, 'Fit');
    expect(fieldText('fills.i.focalPoint.y'), findsOneWidget);
  });

  testWidgets('clicking the preview sets the focal point', (tester) async {
    final c = await _open(tester, _doc());
    await tester.tapAt(_previewAt(tester, 0.25, 0.75));
    await tester.pump();
    final f = _i(c).focalPoint;
    expect(f.x, closeTo(0.25, 0.01));
    expect(f.y, closeTo(0.75, 0.01));
    expect(
      valueAt(c, 'a', 'fills.i.focalPoint', 'desktop'),
      isA<ir.PointValue>(),
    );
  });

  testWidgets('dragging the focal point is one undo step', (tester) async {
    final c = await _open(tester, _doc());
    final before = _undo(c);
    final g = await tester.startGesture(_previewAt(tester, 0.5, 0.5));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(-8, -4));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    expect(_i(c).focalPoint.x, lessThan(0.5));
    expect(_i(c).focalPoint.y, lessThan(0.5));
    expect(_undo(c), before + 1);
  });

  testWidgets('double-click resets the focal point to the centre', (
    tester,
  ) async {
    final c = await _open(
      tester,
      _doc(
        const ir.ImagePaint(
          id: 'i',
          assetId: 'img1',
          focalPoint: ir.StagePoint(x: 0.1, y: 0.1),
        ),
      ),
    );
    final p = _previewAt(tester, 0.8, 0.8);
    await tester.tapAt(p);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(p);
    await tester.pump();
    expect(_i(c).focalPoint, const ir.StagePoint(x: 0.5, y: 0.5));
  });

  testWidgets('focal fields type in %', (tester) async {
    final c = await _open(tester, _doc());
    await typeInto(tester, 'fills.i.focalPoint.x', '20');
    expect(_i(c).focalPoint, const ir.StagePoint(x: 0.2, y: 0.5));
  });

  testWidgets('crop fields write the rect; Reset crop clears it', (
    tester,
  ) async {
    final c = await _open(
      tester,
      _doc(
        const ir.ImagePaint(
          id: 'i',
          assetId: 'img1',
          scaleMode: ir.ImageScaleMode.crop,
        ),
      ),
    );
    await typeInto(tester, 'fills.i.cropRect.x', '10');
    await typeInto(tester, 'fills.i.cropRect.width', '50');
    expect(
      _i(c).cropRect,
      const ir.StageRect(x: 0.1, y: 0, width: 0.5, height: 1),
    );
    await tapKey(tester, 'image-reset-crop:i');
    expect(_i(c).cropRect, isNull);
  });

  testWidgets('dragging inside the crop rectangle moves it', (tester) async {
    final c = await _open(
      tester,
      _doc(
        const ir.ImagePaint(
          id: 'i',
          assetId: 'img1',
          scaleMode: ir.ImageScaleMode.crop,
          cropRect: ir.StageRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
        ),
      ),
    );
    final before = _undo(c);
    final size = tester.getSize(find.byKey(const ValueKey('image-preview:i')));
    final g = await tester.startGesture(_previewAt(tester, 0.5, 0.5));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(Offset(size.width * 0.02, 0));
      await tester.pump();
    }
    await g.up();
    await tester.pump();
    final r = _i(c).cropRect!;
    expect(r.x, greaterThan(0.25));
    expect(r.width, closeTo(0.5, 1e-6));
    expect(r.y, closeTo(0.25, 1e-6));
    expect(_undo(c), before + 1);
  });

  testWidgets('tile scale and rotation', (tester) async {
    final c = await _open(
      tester,
      _doc(
        const ir.ImagePaint(
          id: 'i',
          assetId: 'img1',
          scaleMode: ir.ImageScaleMode.tile,
        ),
      ),
    );
    await typeInto(tester, 'fills.i.tileScale', '2.5');
    expect(_i(c).tileScale, 2.5);
    await tapOn(tester, find.text('90°'));
    expect(_i(c).rotation, 90);
    await tapOn(tester, find.text('270°'));
    expect(_i(c).rotation, 270);
  });

  group('adjustments', () {
    Future<ProviderContainer> openAdjustments(WidgetTester tester) async {
      final c = await _open(tester, _doc());
      expect(
        find.byKey(const ValueKey('slider:fills.i.filters.exposure')),
        findsNothing,
        reason: 'collapsed by default',
      );
      await tapKey(tester, 'image-adjustments:i');
      return c;
    }

    testWidgets('all seven sliders; dragging is one undo step', (tester) async {
      final c = await openAdjustments(tester);
      for (final n in [
        'exposure',
        'contrast',
        'saturation',
        'temperature',
        'tint',
        'highlights',
        'shadows',
      ]) {
        expect(
          find.byKey(ValueKey<String>('slider:fills.i.filters.$n')),
          findsOneWidget,
        );
      }
      final before = _undo(c);
      final s = find.byKey(const ValueKey('slider:fills.i.filters.exposure'));
      final g = await tester.startGesture(tester.getCenter(s));
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(6, 0));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      expect(_i(c).filters.exposure, greaterThan(0));
      expect(_undo(c), before + 1);
      expect(find.text('Reset all'), findsOneWidget);
    });

    testWidgets('double-click resets a slider; Reset all clears them', (
      tester,
    ) async {
      final c = await openAdjustments(tester);
      final s = find.byKey(const ValueKey('slider:fills.i.filters.contrast'));
      final box = tester.getRect(s);
      // Clicks carry pointer timestamps (the double-click clock).
      var t = const Duration(seconds: 1);
      Future<void> click(Offset at, {int gapMs = 1000}) async {
        t += Duration(milliseconds: gapMs);
        final g = await tester.createGesture();
        await g.down(at, timeStamp: t);
        await g.up(timeStamp: t);
        await tester.pump();
      }

      await click(Offset(box.right - 4, box.center.dy));
      expect(_i(c).filters.contrast, greaterThan(0.8));
      await click(box.center);
      await click(box.center, gapMs: 50);
      expect(_i(c).filters.contrast, 0);
      await click(Offset(box.left + 2, box.center.dy));
      expect(_i(c).filters.contrast, lessThan(-0.8));
      await tapKey(tester, 'image-filters-reset:i');
      expect(_i(c).filters, const ir.ImageFilters());
      expect(find.text('Reset all'), findsNothing);
    });

    testWidgets('the disclosure is remembered while the row collapses', (
      tester,
    ) async {
      await openAdjustments(tester);
      await tapKey(tester, 'paint-swatch:i');
      await tapKey(tester, 'paint-swatch:i');
      expect(
        find.byKey(const ValueKey('slider:fills.i.filters.exposure')),
        findsOneWidget,
      );
    });
  });

  for (final width in [288.0, 240.0]) {
    for (final mode in ir.ImageScaleMode.values) {
      testWidgets('${mode.name} editor fits at $width px', (tester) async {
        await _open(
          tester,
          _doc(ir.ImagePaint(id: 'i', assetId: 'img1', scaleMode: mode)),
          width: width,
        );
        await tapKey(tester, 'image-adjustments:i');
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('empty image editor fits at $width px', (tester) async {
      await _open(
        tester,
        _doc(const ir.ImagePaint(id: 'i', assetId: '')),
        width: width,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
