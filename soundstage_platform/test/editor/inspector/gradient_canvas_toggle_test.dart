import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';

import '../interaction/gradient_interaction_test.dart' as g;
import 'inspector_harness.dart';

void main() {
  testWidgets('the gradient editor toggles on-canvas editing', (tester) async {
    final c = await pumpInspector(tester, g.gradientDoc(), select: {'a'});
    await tester.tap(find.byKey(const ValueKey('paint-swatch:g')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('gradient-edit:g'));
    expect(toggle, findsOneWidget);
    await tester.tap(toggle);
    await tester.pump();
    final canvas = c.read(canvasControllerProvider);
    expect(
      canvas.gradientEdit.value,
      const GradientEditTarget('a', 'fills', 'g'),
    );
    await tester.tap(toggle);
    await tester.pump();
    expect(canvas.gradientEdit.value, isNull);
  });

  testWidgets('double-clicking a gradient swatch edits it on the canvas', (
    tester,
  ) async {
    final c = await pumpInspector(tester, g.gradientDoc(), select: {'a'});
    final swatch = find.byKey(const ValueKey('paint-swatch:g'));
    await tester.tap(swatch);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(swatch);
    await tester.pumpAndSettle();
    expect(
      c.read(canvasControllerProvider).gradientEdit.value,
      const GradientEditTarget('a', 'fills', 'g'),
    );
    expect(find.byKey(const ValueKey('gradient-edit:g')), findsOneWidget);
  });
}
