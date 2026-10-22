// The T0.8 spike story resolves cleanly at 390, 834 and 1440, its card grid
// wraps as designed, and its zoom origin tracks the focal crop.
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/sound_demo.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

// Like the other demo tests: the web test runner never completes a
// `rootBundle` load, so the VM runs these.
void main() {
  ir.StageDocument? cached;
  Future<ir.StageDocument> spike(WidgetTester tester) async =>
      cached ??= (await tester.runAsync(() async {
        final text = await rootBundle.loadString(kSpikeDemoAsset);
        return ir.StageDocument.fromJsonMigrating(
          jsonDecode(text) as Map<String, Object?>,
        );
      }))!;

  testWidgets('resolves without diagnostics at every width', skip: kIsWeb, (
    tester,
  ) async {
    final doc = await spike(tester);
    expect(doc.scenes.map((s) => s.id), [
      'hero',
      'lyric',
      'things',
      'lamp',
      'fin',
    ]);
    for (final w in [390.0, 834.0, 1440.0]) {
      final r = ir.resolveDocument(doc, ir.ResolveContext(viewportWidth: w));
      expect(r.diagnostics, isEmpty, reason: '$w: ${r.diagnostics}');
    }
  });

  for (final (width, height, columns, bp) in [
    (390.0, 844.0, 1, 'mobile'),
    (834.0, 1112.0, 2, 'tablet'),
    (1440.0, 900.0, 3, 'desktop'),
  ]) {
    testWidgets(
      'card grid wraps to $columns column(s) at $width',
      skip: kIsWeb,
      (tester) async {
        final doc = await spike(tester);
        setViewport(tester, Size(width, height));
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: StagePlayer(
              document: doc,
              mode: StageRenderMode.edit,
              initialSceneId: 'things',
            ),
          ),
        );
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        final cards = [for (var i = 1; i <= 6; i++) globalRect(tester, 'c$i')];
        final firstRow = cards.where((c) => c.top == cards.first.top).toList();
        expect(firstRow.length, columns, reason: bp);
        for (final c in cards) {
          expect(c.width, inInclusiveRange(340, 460), reason: bp);
          expect(c.left, greaterThanOrEqualTo(0));
          expect(c.right, lessThanOrEqualTo(width));
        }
        // Rows do not overlap.
        for (var i = columns; i < cards.length; i++) {
          expect(cards[i].top, greaterThan(cards[i - columns].top));
        }
        // Cards in a row share a width (they fill the row).
        if (columns > 1) {
          expect(firstRow.first.width, closeTo(firstRow.last.width, 0.5));
        }
      },
    );

    testWidgets('lamp zoom origin is the focal point at $width', skip: kIsWeb, (
      tester,
    ) async {
      final doc = await spike(tester);
      final r = ir.resolveDocument(
        doc,
        ir.ResolveContext(viewportWidth: width),
      );
      final lamp = r.scenes.firstWhere((s) => s.id == 'lamp');
      final img = lamp.root.children.firstWhere(
        (c) => c.id.endsWith('lamp-img'),
      );
      final m = img.node.common.motion;
      // The `fill` crop of a 2400x1200 image focused at (0.70, 0.405).
      final scale = (width / 2400) > (height / 1200)
          ? width / 2400
          : height / 1200;
      double place(double box, double len, double f) =>
          (box / 2 - f * len).clamp(box - len, 0.0);
      final fx =
          (place(width, 2400 * scale, 0.70) + 0.70 * 2400 * scale) / width;
      final fy =
          (place(height, 1200 * scale, 0.405) + 0.405 * 1200 * scale) / height;
      expect(m.originX, closeTo(fx, 1e-9), reason: bp);
      expect(m.originY, closeTo(fy, 1e-9), reason: bp);
      // The subject stays inside the frame at every width.
      expect(fx, inInclusiveRange(0.3, 0.8));
      expect(fy, inInclusiveRange(0.2, 0.7));
    });
  }
}
