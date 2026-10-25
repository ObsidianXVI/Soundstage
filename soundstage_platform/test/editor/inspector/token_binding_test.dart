import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/inspector/fields/token_binding.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

ir.StageDocument _doc() => inspectorDoc([rect('r')]).copyWith(
  tokens: const ir.TokenSystem(
    collections: [
      ir.VariableCollection(
        id: 'c1',
        name: 'Theme',
        modes: [ir.TokenMode(id: 'm', name: 'Default')],
        defaultModeId: 'm',
        variables: [
          ir.Variable(
            id: 'vn',
            name: 'fade/half',
            type: ir.VariableType.number,
            valuesByMode: {'m': ir.IrValue.number(0.5)},
          ),
          ir.Variable(
            id: 'vc',
            name: 'brand',
            type: ir.VariableType.color,
            valuesByMode: {
              'm': ir.IrValue.color(ir.StageColor(r: 1, g: 0, b: 0)),
            },
          ),
        ],
      ),
    ],
  ),
);

void main() {
  test('bindable types follow the registry', () {
    expect(bindableType('opacity'), ir.VariableType.number);
    expect(bindableType('visible'), ir.VariableType.boolean);
    expect(bindableType('name'), isNull);
    expect(bindableType('blendMode'), isNull);
    expect(bindableType('style.fontFamilyId'), ir.VariableType.fontFamily);
  });

  testWidgets('hover → bind → chip → detach keeps the value', (tester) async {
    final c = await pumpInspector(tester, _doc(), select: {'r'});
    final field = find.byKey(const ValueKey('field:opacity'));
    expect(field, findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(field));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bind-opacity')));
    await tester.pumpAndSettle();
    // Only number variables are offered.
    expect(find.byKey(const ValueKey('pick-variable-vc')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pick-variable-vn')));
    await tester.pumpAndSettle();

    expect(nodeOf(c, 'r').common.bindings, {
      'opacity': const ir.TokenRef(variableId: 'vn'),
    });
    expect(find.byKey(const ValueKey('bound-variable')), findsOneWidget);
    expect(find.text('fade / half'), findsOneWidget);
    expect(valueAt(c, 'r', 'opacity', 'desktop'), const ir.IrValue.number(0.5));

    await tester.tap(find.byKey(const ValueKey('detach-variable')));
    await tester.pumpAndSettle();
    expect(nodeOf(c, 'r').common.bindings, isEmpty);
    expect(nodeOf(c, 'r').common.opacity, 0.5);
    expect(find.byKey(const ValueKey('bound-variable')), findsNothing);
    // Bind and detach are one undo step each.
    expect(c.ctl.undo(), isTrue);
    expect(nodeOf(c, 'r').common.bindings, isNotEmpty);
  });
}
