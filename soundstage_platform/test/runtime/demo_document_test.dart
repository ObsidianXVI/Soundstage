// The static demo document renders through the dev harness without
// exceptions, faults or horizontal overflow at 390, 834 and 1440 wide.
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/demo_harness.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

Future<ir.StageDocument> loadDemo() async {
  final text = await rootBundle.loadString(kDemoDocumentAsset);
  return ir.StageDocument.fromJsonMigrating(
    jsonDecode(text) as Map<String, Object?>,
  );
}

List<RenderStageBox> allStageBoxes(WidgetTester tester) {
  final out = <RenderStageBox>[];
  void visit(RenderObject o) {
    if (o is RenderStageBox) out.add(o);
    o.visitChildren(visit);
  }

  tester.binding.renderViews.forEach(visit);
  return out;
}

// `flutter test --platform chrome` never completes a `rootBundle` load, so
// these run on the VM only. The same document is checked in Chrome through
// the app (chrome-devtools screenshots, `_dev/screens/t0.4/`).
void main() {
  // Loaded inside the first test (real async), not in setUpAll: asset
  // loading from setUpAll never completes under `--platform chrome`.
  ir.StageDocument? cached;
  Future<ir.StageDocument> demo(WidgetTester tester) async =>
      cached ??= (await tester.runAsync(loadDemo))!;

  testWidgets(
    'the demo document is valid and resolves without diagnostics',
    skip: kIsWeb,
    (tester) async {
      final doc = await demo(tester);
      for (final width in [390.0, 834.0, 1440.0]) {
        final r = ir.resolveDocument(
          doc,
          ir.ResolveContext(viewportWidth: width),
        );
        expect(r.diagnostics, isEmpty, reason: '$width: ${r.diagnostics}');
        expect(r.scenes, hasLength(3));
      }
    },
  );

  for (final (width, height, bp) in [
    (390.0, 844.0, 'mobile'),
    (834.0, 1112.0, 'tablet'),
    (1440.0, 900.0, 'desktop'),
  ]) {
    testWidgets('renders at $width × $height ($bp)', skip: kIsWeb, (
      tester,
    ) async {
      final doc = await demo(tester);
      setViewport(tester, Size(width, height));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [demoDocumentProvider.overrideWith((ref) async => doc)],
          child: const MaterialApp(home: Scaffold(body: DemoHarness())),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(tester.takeException(), isNull);

      final boxes = allStageBoxes(tester);
      expect(boxes, isNotEmpty);
      for (final b in boxes) {
        expect(b.hasLayoutFault, isFalse, reason: b.nodeId);
        expect(b.hasPaintFault, isFalse, reason: b.nodeId);
        expect(b.placeholder, isFalse, reason: b.nodeId);
      }

      // No text overflows the viewport horizontally.
      for (final t in boxes.whereType<RenderStageText>()) {
        if (!t.common.visible) continue;
        final r = MatrixUtils.transformRect(
          t.getTransformTo(null),
          Offset.zero & t.size,
        );
        expect(r.left, greaterThanOrEqualTo(-0.5), reason: t.nodeId);
        expect(r.right, lessThanOrEqualTo(width + 0.5), reason: t.nodeId);
        // Laid-out text fits its box width (no clipped wrapping).
        expect(
          t.textLayout.size.width,
          lessThanOrEqualTo(t.size.width + 0.5),
          reason: t.nodeId,
        );
      }

      // Every flow-scene node stays inside the viewport width.
      final essay = stageBox(tester, 'essay-root');
      expect(essay.size.width, width);
      for (final id in [
        'essay-col',
        'tags',
        'cards',
        'baseline-row',
        'shapes-row',
      ]) {
        final r = globalRect(tester, id);
        expect(r.left, greaterThanOrEqualTo(0), reason: id);
        expect(r.right, lessThanOrEqualTo(width), reason: id);
      }

      // Sections of the flow scene stack without overlapping, and each
      // hugging section contains its last child.
      final groups = [
        'essay-col',
        'tags-group',
        'cards-group',
        'baseline-group',
        'shapes-group',
      ].map((id) => globalRect(tester, id)).toList();
      for (var i = 1; i < groups.length; i++) {
        expect(groups[i].top, greaterThanOrEqualTo(groups[i - 1].bottom));
      }
      for (final (group, last) in [
        ('tags-group', 'tags'),
        ('cards-group', 'cards'),
        ('cards', 'card-dunes'),
        ('baseline-group', 'baseline-row'),
        ('shapes-group', 'shapes-row'),
      ]) {
        expect(
          globalRect(tester, last).bottom,
          lessThanOrEqualTo(globalRect(tester, group).bottom + 0.5),
          reason: '$last overflows $group',
        );
      }

      // The pinned hero fills the viewport.
      expect(stageBox(tester, 'hero-root').size, Size(width, height));

      // The mobile patch stacks the cards; wider breakpoints keep a row.
      final forest = globalRect(tester, 'card-forest');
      final sea = globalRect(tester, 'card-sea');
      if (bp == 'mobile') {
        expect(sea.top, greaterThan(forest.bottom));
        expect(sea.width, 320); // its max width
      } else {
        expect(sea.top, forest.top);
        expect(sea.left, greaterThan(forest.right));
      }

      // The quote card stays centred (centre constraints).
      final quote = globalRect(tester, 'quote-card');
      final quoteRoot = globalRect(tester, 'quote-root');
      expect(quote.center.dx, closeTo(quoteRoot.center.dx, 0.5));
      expect(quote.center.dy, closeTo(quoteRoot.center.dy, 0.5));
    });
  }
}
