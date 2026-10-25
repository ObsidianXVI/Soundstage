import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

void main() {
  testWidgets('add a grid, edit its tracks, place a child, remove it', (
    tester,
  ) async {
    final c = await pumpInspector(
      tester,
      inspectorDoc([
        box('g', children: [rect('a'), rect('b')]),
      ]),
      select: {'g'},
      height: 1800,
    );
    await tester.tap(find.byKey(const ValueKey('grid:add')));
    await tester.pumpAndSettle();
    var g = (nodeOf(c, 'g') as ir.FrameNode).grid!;
    expect(g.columns, const [ir.GridTrack.flex(), ir.GridTrack.flex()]);
    expect(g.columnGap, 16);

    await tester.tap(find.byKey(const ValueKey('grid.columns:add')));
    await tester.pumpAndSettle();
    // Column 1 becomes fixed.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('grid.columns:0')),
        matching: find.text('Flex'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixed').last);
    await tester.pumpAndSettle();
    g = (nodeOf(c, 'g') as ir.FrameNode).grid!;
    expect(g.columns, const [
      ir.GridTrack.fixed(120),
      ir.GridTrack.flex(),
      ir.GridTrack.flex(),
    ]);
    // A child picks its cell.
    c.ctl.select({'b'});
    await tester.pumpAndSettle();
    expect(find.text('Grid cell'), findsOneWidget);
    final col = find.descendant(
      of: find.byKey(const ValueKey('field:layoutChild.grid.column:null')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(col, '3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(nodeOf(c, 'b').common.layoutChild.grid.column, 2);

    c.ctl.select({'g'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('grid:remove')));
    await tester.pumpAndSettle();
    expect((nodeOf(c, 'g') as ir.FrameNode).grid, isNull);
  });
}
