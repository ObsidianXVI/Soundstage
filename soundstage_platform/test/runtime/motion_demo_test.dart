// Reads the demo with dart:io (the web test runner never completes a
// rootBundle load, see test/runtime/demo_document_test.dart).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

ir.StageDocument loadMotionDemo() => ir.StageDocument.fromJsonMigrating(
  jsonDecode(File('assets/demo/motion.stage.json').readAsStringSync())
      as Map<String, Object?>,
);

void main() {
  test('the motion demo validates and resolves without diagnostics', () {
    final doc = loadMotionDemo();
    expect(ir.validateDocument(doc), isEmpty);
    for (final w in [390.0, 1440.0]) {
      final r = ir.resolveDocument(doc, ir.ResolveContext(viewportWidth: w));
      expect(r.diagnostics, isEmpty, reason: 'at $w');
      final tiles = r.scenes.firstWhere((s) => s.id == 'tiles');
      expect(
        tiles.tracks.map((t) => t.target).toSet().length,
        greaterThanOrEqualTo(50),
      );
    }
  });

  for (final size in [const Size(1440, 900), const Size(390, 844)]) {
    testWidgets('the motion demo plays through at $size', (tester) async {
      final controller = StagePlayerController();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StagePlayer(
            document: loadMotionDemo(),
            viewportOverride: size,
            controller: controller,
            environment: const StageEnvironment(),
          ),
        ),
      );
      final scroll = controller.scrollController!;
      final max = scroll.position.maxScrollExtent;
      expect(max, greaterThan(size.height * 5));
      for (var y = 0.0; y <= max; y += size.height / 3) {
        scroll.jumpTo(y);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });
  }
}
