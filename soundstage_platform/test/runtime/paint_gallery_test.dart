// The paint gallery renders through the dev harness without exceptions or
// faults at 390, 834 and 1440 wide (VM only: see demo_document_test.dart).
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

void main() {
  ir.StageDocument? cached;
  for (final (width, height) in [
    (390.0, 844.0),
    (834.0, 1112.0),
    (1440.0, 900.0),
  ]) {
    testWidgets('the paint gallery renders at $width', skip: kIsWeb, (
      tester,
    ) async {
      cached ??= (await tester.runAsync(() async {
        final text = await rootBundle.loadString(kDemoDocuments['gallery']!);
        return ir.StageDocument.fromJsonMigrating(
          jsonDecode(text) as Map<String, Object?>,
        );
      }))!;
      final doc = cached!;
      final r = ir.resolveDocument(
        doc,
        ir.ResolveContext(viewportWidth: width),
      );
      expect(r.diagnostics, isEmpty, reason: '${r.diagnostics}');
      setViewport(tester, Size(width, height));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [demoDocumentProvider.overrideWith((ref) async => doc)],
          child: const MaterialApp(home: Scaffold(body: DemoHarness())),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final boxes = <RenderStageBox>[];
      void visit(RenderObject o) {
        if (o is RenderStageBox) boxes.add(o);
        o.visitChildren(visit);
      }

      tester.binding.renderViews.forEach(visit);
      expect(boxes.length, greaterThan(200));
      for (final b in boxes) {
        expect(b.hasLayoutFault, isFalse, reason: b.nodeId);
        expect(b.hasPaintFault, isFalse, reason: b.nodeId);
      }
    });
  }
}
