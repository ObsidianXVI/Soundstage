import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/panels/tokens_panel.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'panels_harness.dart';

const _red = ir.StageColor(r: 1, g: 0, b: 0);

/// [panelsDoc] plus collection c1 (modes light, dark) with colour `brand/red`
/// (vc) and number `space` (vn), and a frame bound to vc.
ir.StageDocument _tokensDoc() {
  final doc = panelsDoc();
  final s = doc.scenes.first;
  return doc.copyWith(
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
          variables: [
            ir.Variable(
              id: 'vc',
              name: 'brand/red',
              type: ir.VariableType.color,
              valuesByMode: {
                'light': ir.IrValue.color(_red),
                'dark': ir.IrValue.color(_red),
              },
            ),
            ir.Variable(
              id: 'vn',
              name: 'space',
              type: ir.VariableType.number,
              valuesByMode: {
                'light': ir.IrValue.number(8),
                'dark': ir.IrValue.number(16),
              },
            ),
          ],
        ),
      ],
    ),
    scenes: [
      s.copyWith(
        root: s.root.copyWith(
          children: [
            ...s.root.children,
            const ir.FrameNode(
              common: ir.NodeCommon(
                id: 'bound',
                width: 10,
                height: 10,
                bindings: {'opacity': ir.TokenRef(variableId: 'vn')},
              ),
            ),
          ],
        ),
      ),
      ...doc.scenes.skip(1),
    ],
  );
}

ir.Variable _var(ProviderContainer c, String name) => c.doc.tokens.collections
    .expand((x) => x.variables)
    .singleWhere((v) => v.name == name);

Future<void> _secondaryTap(WidgetTester tester, Finder f) async {
  final g = await tester.startGesture(
    tester.getCenter(f),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await g.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('from nothing: create a collection, add a colour variable and '
      'name it into a group', (tester) async {
    final c = await pumpPanel(tester, const TokensPanel(), doc: panelsDoc());
    expect(find.text('No tokens yet'), findsOneWidget);
    await tester.tap(find.text('New collection'));
    await tester.pumpAndSettle();
    final col = c.doc.tokens.collections.single;
    expect(col.name, 'Collection');
    expect(col.modes.single.name, 'Default');

    await tester.tap(find.byKey(const ValueKey('tokens-add-variable')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Colour'));
    await tester.pumpAndSettle();
    final v = c.doc.tokens.collections.single.variables.single;
    expect(v.type, ir.VariableType.color);
    // The new row opens for renaming; a slash groups it.
    final editor = find.descendant(
      of: find.byKey(ValueKey('variable-${v.id}')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(editor.first, 'brand/primary');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      c.doc.tokens.collections.single.variables.single.name,
      'brand/primary',
    );
    expect(find.text('brand'), findsOneWidget);
    expect(find.text('primary'), findsOneWidget);
  });

  testWidgets('values edit per mode, one undo step each', (tester) async {
    final c = await pumpPanel(tester, const TokensPanel(), doc: _tokensDoc());
    final field = find.descendant(
      of: find.byKey(const ValueKey('variable-value-vn-light')),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(_var(c, 'space').valuesByMode['light'], const ir.IrValue.number(12));
    expect(_var(c, 'space').valuesByMode['dark'], const ir.IrValue.number(16));

    // Show the dark mode.
    await tester.tap(find.byKey(const ValueKey('tokens-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('variable-value-vn-dark')),
      findsOneWidget,
    );
    expect(c.ctl.undo(), isTrue);
    expect(_var(c, 'space').valuesByMode['light'], const ir.IrValue.number(8));
  });

  testWidgets('breakpoint modes map breakpoints to modes', (tester) async {
    final c = await pumpPanel(tester, const TokensPanel(), doc: _tokensDoc());
    final bp = c.doc.breakpoints.first;
    await tester.tap(find.byKey(ValueKey('tokens-bp-mode-${bp.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect(c.doc.tokens.collections.single.breakpointModes, {bp.id: 'dark'});
  });

  testWidgets('add a mode through the prompt', (tester) async {
    final c = await pumpPanel(tester, const TokensPanel(), doc: _tokensDoc());
    await tester.tap(find.byKey(const ValueKey('tokens-mode-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add mode…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(SsDialog),
        matching: find.byType(EditableText),
      ),
      'Contrast',
    );
    await tester.tap(find.widgetWithText(SsButton, 'Add'));
    await tester.pumpAndSettle();
    final modes = c.doc.tokens.collections.single.modes;
    expect(modes.map((m) => m.name), ['Light', 'Dark', 'Contrast']);
    // New mode copies the default values.
    expect(
      _var(c, 'space').valuesByMode[modes.last.id],
      const ir.IrValue.number(8),
    );
  });

  testWidgets('an alias shows its target; deleting a used variable asks and '
      'keeps the values', (tester) async {
    final c = await pumpPanel(tester, const TokensPanel(), doc: _tokensDoc());
    // Alias: duplicate brand/red, then point the copy at it.
    await _secondaryTap(tester, find.byKey(const ValueKey('variable-vc')));
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    final copy = _var(c, 'brand/red copy');
    await _secondaryTap(tester, find.byKey(ValueKey('variable-${copy.id}')));
    await tester.tap(find.text('Set alias…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Theme / brand/red'));
    await tester.pumpAndSettle();
    expect(
      _var(c, 'brand/red copy').valuesByMode['light'],
      const ir.IrValue.tokenRef(ir.TokenRef(variableId: 'vc')),
    );
    expect(
      find.descendant(
        of: find.byKey(ValueKey('variable-value-${copy.id}-light')),
        matching: find.text('red'),
      ),
      findsOneWidget,
    );

    await _secondaryTap(tester, find.byKey(const ValueKey('variable-vn')));
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.textContaining('used by 1 property'), findsOneWidget);
    await tester.tap(find.widgetWithText(SsButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(
      c.doc.tokens.collections.single.variables.any((v) => v.id == 'vn'),
      isFalse,
    );
    final bound = ir.DocumentIndex.of(c.doc).node('bound')!;
    expect(bound.common.bindings, isEmpty);
    expect(bound.common.opacity, 8);
  });
}
