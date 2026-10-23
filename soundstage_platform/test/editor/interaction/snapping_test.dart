import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/interaction/snapping.dart';

import 'interaction_harness.dart';

void main() {
  const a = Rect.fromLTWH(100, 100, 100, 100); // 100..200
  const b = Rect.fromLTWH(400, 100, 100, 100); // 400..500
  const art = Rect.fromLTWH(0, 0, 1000, 800);

  group('alignment', () {
    final index = SnapIndex(siblings: [a, b], artboard: art);

    test('the nearest edge within the threshold, at any zoom', () {
      // Left edge 3 px right of a's right edge (200); no y candidate near.
      const m = Rect.fromLTWH(203, 333, 50, 50);
      for (final (zoom, snaps) in [(1.0, true), (0.5, true), (2.0, false)]) {
        final r = index.snap(m, kSnapThresholdPx / zoom);
        expect(r.snappedX, snaps, reason: 'zoom $zoom');
        expect(r.offset.dx, snaps ? -3 : 0);
        expect(r.snappedY, isFalse);
      }
    });

    test('centres snap; guides span both boxes with the distance', () {
      // Centre x 452 → b's centre 450; top 301 → nothing.
      const m = Rect.fromLTWH(427, 301, 50, 50);
      final r = index.snap(m, 5);
      expect(r.offset, const Offset(-2, 0));
      // The aligned line, then the labelled gap to the aligned box.
      expect(r.guides, hasLength(2));
      final line = r.guides.first, gap = r.guides.last;
      expect(line.a, const Offset(450, 100));
      expect(line.b, const Offset(450, 351));
      expect(line.label, isNull);
      expect(gap.a, const Offset(450, 200));
      expect(gap.b, const Offset(450, 301));
      expect(gap.label, 101); // b's bottom (200) to the box's top (301)
    });

    test('the artboard edges and centre are candidates', () {
      final r = index.snap(const Rect.fromLTWH(3, 600, 10, 10), 5);
      expect(r.offset.dx, -3);
      final c = index.snap(const Rect.fromLTWH(497, 600, 10, 10), 5);
      expect(c.offset.dx, -2); // centre 502 → 500
    });

    test('resize: only the moving edges snap', () {
      final r = index.snap(
        const Rect.fromLTWH(300, 300, 97, 10),
        5,
        edges: const MovingEdges(right: true),
      );
      expect(r.offset.dx, 3);
      final l = index.snap(
        const Rect.fromLTWH(300, 300, 97, 10),
        5,
        edges: const MovingEdges(left: true),
      );
      expect(l.snappedX, isFalse);
    });

    test('pixel grid at high zoom moves unsnapped edges onto whole pixels', () {
      final r = index.snap(
        const Rect.fromLTWH(310.3, 350.6, 10, 10),
        kSnapThresholdPx / 8,
        pixelGrid: true,
      );
      expect(r.offset.dx, closeTo(-0.3, 1e-9));
      expect(r.offset.dy, closeTo(0.4, 1e-9));
      expect(r.guides, isEmpty);
    });

    test('a large index answers by binary search', () {
      final many = [
        for (var i = 0; i < 5000; i++)
          Rect.fromLTWH((i % 100) * 13.0, (i ~/ 100) * 17.0, 10, 10),
      ];
      final big = SnapIndex(siblings: many);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        big.snap(
          Rect.fromLTWH(i * 0.7, i * 0.3, 10, 10),
          5,
          edges: const MovingEdges(left: true, top: true),
        );
      }
      sw.stop();
      // Generous: a query is a few binary searches.
      expect(sw.elapsedMilliseconds, lessThan(500));
    });
  });

  group('smart spacing', () {
    test('markers only for pairs in the moving box\'s row', () {
      const far1 = Rect.fromLTWH(100, 600, 100, 50);
      const far2 = Rect.fromLTWH(250, 600, 100, 50); // gap 50, other row
      final index = SnapIndex(siblings: [a, b, far1, far2]);
      // Centred between a and b: gap 50 each, same as the far pair's.
      final r = index.snap(const Rect.fromLTWH(252, 120, 100, 50), 5);
      expect(r.gaps, hasLength(2));
      expect(r.gaps.every((g) => g.area.top < 300), isTrue);
    });

    test('centred between two neighbours, with both gap markers', () {
      final index = SnapIndex(siblings: [a, b]);
      // 100 wide between 200 and 400: centred at 250.
      final r = index.snap(const Rect.fromLTWH(252, 130, 100, 40), 5);
      expect(r.offset.dx, -2);
      expect(r.gaps, hasLength(2));
      expect(r.gaps.every((g) => g.horizontal && g.value == 50), isTrue);
    });

    test('an existing gap repeated next to a neighbour', () {
      const c = Rect.fromLTWH(300, 100, 100, 100); // gap 100 after a
      final index = SnapIndex(siblings: [a, c]);
      // After c (ends 400): left 503 → 500 (gap 100).
      final r = index.snap(const Rect.fromLTWH(503, 130, 50, 50), 5);
      expect(r.offset.dx, -3);
      expect(r.gaps.map((g) => g.value), everyElement(100));
      expect(r.gaps.length, greaterThanOrEqualTo(2)); // the new gap + a–c
    });

    test('vertical gaps', () {
      const top = Rect.fromLTWH(0, 0, 100, 100);
      const mid = Rect.fromLTWH(0, 150, 100, 100); // gap 50
      final index = SnapIndex(siblings: [top, mid]);
      final r = index.snap(const Rect.fromLTWH(20, 302, 60, 40), 5);
      expect(r.offset.dy, -2);
      expect(r.gaps.first.horizontal, isFalse);
    });

    test('alignment and spacing at the same place show both', () {
      // Centred between a and b (250) is also 50 + 200 from the artboard.
      final index = SnapIndex(
        siblings: [a, b],
        artboard: const Rect.fromLTWH(0, 0, 600, 800),
      );
      final r = index.snap(const Rect.fromLTWH(252, 130, 100, 40), 5);
      expect(r.offset, const Offset(-2, 0));
      expect(r.gaps, hasLength(2));
      expect(r.guides, isNotEmpty); // centre 300 = the artboard's centre
    });
  });

  group('measureBetween', () {
    test('apart horizontally: one line between facing edges', () {
      final m = measureBetween(a, b);
      expect(m, hasLength(1));
      expect(m.single.a, const Offset(200, 150));
      expect(m.single.b, const Offset(400, 150));
      expect(m.single.label, 200);
    });

    test('inside a parent: four distances to its edges', () {
      final m = measureBetween(a, art);
      expect(m.map((g) => g.label), [100, 800, 100, 600]);
    });

    test('apart diagonally: both axes, with dashed extensions', () {
      final m = measureBetween(a, const Rect.fromLTWH(400, 400, 50, 50));
      expect(m.where((g) => !g.dashed).map((g) => g.label), [200, 200]);
      expect(m.where((g) => g.dashed), hasLength(2));
    });

    test('overlapping: edge-to-edge distances', () {
      final m = measureBetween(a, const Rect.fromLTWH(150, 120, 100, 100));
      expect(m.map((g) => g.label), [50, 50, 20, 20]);
    });
  });

  group('on the canvas', () {
    testWidgets('a drag near a sibling snaps with guides; Cmd disables', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      final g = await h.press(h.desk(150, 150));
      // a's top 100 + 3 → snaps back to b's top (100); x free (153).
      await g.moveTo(h.desk(203, 153));
      await tester.pump();
      expect(h.common('a').y, 100);
      expect(h.canvas.interaction.guides, isNotEmpty);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(h.common('a').y, 103);
      expect(h.canvas.interaction.guides, isEmpty);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await g.up();
      await tester.pump();
      expect(h.canvas.interaction.guides, isEmpty, reason: 'cleared on drop');
    });

    for (final zoom in [0.5, 2.0]) {
      testWidgets('the threshold is 5 screen px at zoom $zoom', (tester) async {
        final h = await pumpCanvas(
          tester,
          camera: CanvasCamera(zoom: zoom, panX: 40, panY: 60),
        );
        // 4 screen px below b's top: snaps.
        await h.drag(h.desk(150, 150), h.desk(150, 150 + 4 / zoom));
        expect(h.common('a').y, 100);
        h.ctl.undo();
        await tester.pump();
        // 7 screen px: no snap.
        await h.drag(h.desk(150, 150), h.desk(150, 150 + 7 / zoom));
        expect(h.common('a').y, isNot(100));
      });
    }

    testWidgets('smart spacing between siblings shows pink gap markers', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      // b (400..500) and c (700..800): a (100 wide) centred between them
      // sits at 550; drag it there, 2 px off, away from other candidates.
      final g = await h.press(h.desk(150, 150));
      await g.moveTo(h.desk(400, 160));
      await tester.pump();
      await g.moveTo(h.desk(602, 160));
      await tester.pump();
      expect(h.common('a').x, 550);
      final m = h.canvas.interaction;
      expect(m.gaps, hasLength(2));
      expect(m.gaps.every((g) => g.value == 50), isTrue);
      await g.up();
      await tester.pump();
      expect(m.gaps, isEmpty);
    });

    testWidgets('pixel grid at ≥ 400%', (tester) async {
      final h = await pumpCanvas(
        tester,
        camera: const CanvasCamera(zoom: 8, panX: -400, panY: -400),
      );
      await h.drag(h.desk(150, 150), h.desk(151.3, 151.7));
      expect(h.common('a').x, 101);
      expect(h.common('a').y, 102);
    });

    testWidgets('Alt over another node measures from the selection', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'a'});
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      final g = await h.hoverAt(h.desk(450, 150));
      final m = h.canvas.interaction.measures;
      expect(m.map((e) => e.label), [200]);
      // Over the selection itself: distances to the parent.
      await g.moveTo(h.desk(150, 150));
      await tester.pump();
      expect(h.canvas.interaction.measures.map((e) => e.label), [
        100,
        800,
        100,
        600,
      ]);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pump();
      expect(h.canvas.interaction.measures, isEmpty);
      await g.removePointer();
    });
  });
}
