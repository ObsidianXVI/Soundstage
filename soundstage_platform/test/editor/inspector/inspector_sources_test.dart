import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

ir.StageDocument _doc() {
  final base = inspectorDoc([
    const ir.ShapeNode(
      common: ir.NodeCommon(
        id: 'tok',
        name: 'tok',
        width: 10,
        height: 10,
        x: 5,
        bindings: {'x': ir.TokenRef(variableId: 'vX')},
      ),
    ),
    const ir.InstanceNode(
      common: ir.NodeCommon(id: 'inst', name: 'inst', width: 50, height: 50),
      source: ir.InstanceSource.component('cmp'),
    ),
  ]);
  return base.copyWith(
    tokens: const ir.TokenSystem(
      collections: [
        ir.VariableCollection(
          id: 'col',
          name: 'Theme',
          modes: [ir.TokenMode(id: 'm', name: 'Mode')],
          defaultModeId: 'm',
          variables: [
            ir.Variable(
              id: 'vX',
              name: 'space/x',
              type: ir.VariableType.number,
              valuesByMode: {'m': ir.IrValue.number(40)},
            ),
          ],
        ),
      ],
    ),
    components: {
      'cmp': const ir.ComponentDef(
        id: 'cmp',
        name: 'Card',
        root: ir.FrameNode(
          common: ir.NodeCommon(id: 'cmpR', width: 50, height: 50),
          children: [
            ir.ShapeNode(
              common: ir.NodeCommon(id: 'cmpI', x: 7, width: 10, height: 10),
            ),
          ],
        ),
      ),
    },
  );
}

Future<void> _rightClick(WidgetTester tester, Finder f) async {
  final g = await tester.startGesture(
    tester.getCenter(f),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await g.up();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('a token-bound value shows a token marker, not an override', (
    tester,
  ) async {
    await pumpInspector(tester, _doc(), select: {'tok'});
    expect(find.byKey(const ValueKey('value-source-dot')), findsOneWidget);
    expect(find.byKey(const ValueKey('override-tint')), findsNothing);
    await _rightClick(tester, find.byKey(const ValueKey('field:x')));
    expect(find.text('Token: space/x'), findsOneWidget);
    // A token cannot be reset from here: the entry is disabled.
    final item = find.text('Reset to inherited');
    expect(item, findsOneWidget);
  });

  testWidgets('component values are marked; an instance override is purple '
      'and resets', (tester) async {
    final c = await pumpInspector(tester, _doc(), select: {'inst/cmpI'});
    // From the component: blue marker, no tint.
    expect(find.byKey(const ValueKey('value-source-dot')), findsWidgets);
    expect(find.byKey(const ValueKey('override-tint')), findsNothing);

    await typeInto(tester, 'x', '21');
    final inst = nodeOf(c, 'inst') as ir.InstanceNode;
    expect(inst.overrides['cmpI']?['x'], const ir.IrValue.number(21));
    expect(find.byKey(const ValueKey('override-tint')), findsOneWidget);

    await _rightClick(tester, find.byKey(const ValueKey('field:x')));
    expect(find.text('Instance override'), findsOneWidget);
    await tester.tap(find.text('Reset to inherited'));
    await tester.pump();
    await tester.pump();
    expect((nodeOf(c, 'inst') as ir.InstanceNode).overrides['cmpI'], isNull);
    expect(find.byKey(const ValueKey('override-tint')), findsNothing);
  });

  testWidgets('an override on one of several selected nodes is shown', (
    tester,
  ) async {
    final doc = inspectorDoc([
      rect('p'),
      rect(
        'q',
        patches: const {
          'mobile': {'x': ir.IrValue.number(9)},
        },
      ),
    ]);
    final c = await pumpInspector(tester, doc, select: {'p', 'q'});
    c.read(editorControllerProvider.notifier).setEditingBreakpoint('mobile');
    await tester.pump();
    expect(find.byKey(const ValueKey('override-tint')), findsOneWidget);
  });
}
