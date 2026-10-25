import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/shell/toolbar.dart';

void main() {
  testWidgets('the shape button keeps the last shape; the menu offers all '
      'five', (tester) async {
    var tool = EditorTool.move;
    late StateSetter set;
    await tester.pumpWidget(
      MaterialApp(
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, s) {
              set = s;
              return Align(
                alignment: Alignment.topLeft,
                child: ShapeToolButton(
                  tool: tool,
                  onSelect: (t) => set(() => tool = t),
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Rectangle'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Rectangle'));
    await tester.pump();
    expect(tool, EditorTool.rectangle);

    await tester.tap(find.bySemanticsLabel('Shape tools'));
    await tester.pumpAndSettle();
    for (final l in ['Rectangle', 'Line', 'Ellipse', 'Polygon', 'Star']) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    await tester.tap(find.text('Star'));
    await tester.pumpAndSettle();
    expect(tool, EditorTool.star);
    // The button now holds the star.
    set(() => tool = EditorTool.move);
    await tester.pump();
    expect(find.bySemanticsLabel('Star'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Star'));
    await tester.pump();
    expect(tool, EditorTool.star);
  });
}
