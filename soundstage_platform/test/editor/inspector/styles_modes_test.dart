import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

const _green = ir.StageColor(r: 0, g: 1, b: 0);

ir.StageDocument _doc() =>
    inspectorDoc([
      box(
        'f',
        appearance: const ir.Appearance(
          fills: [ir.Paint.solid(id: 'p1', color: _green)],
        ),
      ),
      box('g'),
    ]).copyWith(
      tokens: const ir.TokenSystem(
        collections: [
          ir.VariableCollection(
            id: 'c1',
            name: 'Theme',
            modes: [
              ir.TokenMode(id: 'light', name: 'Light'),
              ir.TokenMode(id: 'dark', name: 'Dark'),
            ],
            defaultModeId: 'light',
          ),
        ],
      ),
    );

Future<void> _menu(WidgetTester tester, String stylePath) async {
  await tester.tap(find.byKey(ValueKey('style-picker-$stylePath')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('create a colour style from a fill, apply it to another frame, '
      'detach it', (tester) async {
    final c = await pumpInspector(tester, _doc(), select: {'f'});
    await _menu(tester, 'fillStyleId');
    await tester.tap(find.text('Create colour style…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(SsDialog),
        matching: find.byType(EditableText),
      ),
      'Brand',
    );
    await tester.tap(find.widgetWithText(SsButton, 'Create'));
    await tester.pumpAndSettle();
    final styles = c.doc.tokens.paintStyles;
    expect(styles.values.single.name, 'Brand');
    final id = styles.keys.single;
    expect((nodeOf(c, 'f') as ir.FrameNode).appearance.fillStyleId, id);
    expect(find.byKey(const ValueKey('fill-style')), findsOneWidget);
    // One undo step removes the style and the reference.
    expect(c.ctl.undo(), isTrue);
    expect(c.doc.tokens.paintStyles, isEmpty);
    expect(c.ctl.redo(), isTrue);

    c.ctl.select({'g'});
    await tester.pumpAndSettle();
    await _menu(tester, 'fillStyleId');
    await tester.tap(find.text('Brand'));
    await tester.pumpAndSettle();
    expect((nodeOf(c, 'g') as ir.FrameNode).appearance.fillStyleId, id);

    await _menu(tester, 'fillStyleId');
    await tester.tap(find.text('Detach style'));
    await tester.pumpAndSettle();
    final g = nodeOf(c, 'g') as ir.FrameNode;
    expect(g.appearance.fillStyleId, isNull);
    expect((g.appearance.fills.single as ir.SolidPaint).color, _green);
  });

  testWidgets('a frame and a scene pick modes per collection', (tester) async {
    final c = await pumpInspector(tester, _doc(), select: {'f'});
    expect(find.text('Modes'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mode-override-c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect((nodeOf(c, 'f') as ir.FrameNode).modeOverrides, {'c1': 'dark'});
    await tester.tap(find.byKey(const ValueKey('mode-override-c1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto').last);
    await tester.pumpAndSettle();
    expect((nodeOf(c, 'f') as ir.FrameNode).modeOverrides, isEmpty);
  });

  testWidgets('no Modes section without a multi-mode collection', (
    tester,
  ) async {
    await pumpInspector(tester, inspectorDoc([box('f')]), select: {'f'});
    expect(find.text('Modes'), findsNothing);
  });
}
