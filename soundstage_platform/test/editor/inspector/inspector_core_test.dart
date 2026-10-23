import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

ir.StageDocument _doc() => inspectorDoc([
  rect('a', x: 10, y: 20, w: 100, h: 50),
  rect('b', x: 200, y: 20, w: 100, h: 50),
  rect(
    'm',
    x: 10,
    y: 300,
    patches: const {
      'mobile': {'x': ir.IrValue.number(33)},
    },
  ),
]);

void main() {
  group('inspector shell', () {
    testWidgets('nothing selected shows the scene settings', (tester) async {
      await pumpInspector(tester, _doc());
      expect(find.text('Scene settings'), findsOneWidget);
    });

    testWidgets('sections follow the selection, in Figma order', (
      tester,
    ) async {
      await pumpInspector(tester, _doc(), select: {'a'});
      final keys = [
        for (final k in ['header', 'frame'])
          tester.getTopLeft(find.byKey(ValueKey<String>('section:$k'))).dy,
      ];
      expect(keys[0] < keys[1], isTrue);
      expect(find.text('Position'), findsOneWidget);
    });

    testWidgets('collapsing a section is remembered across selections', (
      tester,
    ) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      expect(fieldText('x'), findsOneWidget);
      await tester.tap(find.text('Position'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(fieldText('x'), findsNothing);
      c.read(editorControllerProvider.notifier).select({'b'});
      await tester.pump(const Duration(milliseconds: 400));
      expect(fieldText('x'), findsNothing, reason: 'still collapsed for b');
      await tester.tap(find.text('Position'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(fieldText('x'), findsOneWidget);
    });
  });

  group('reading and writing', () {
    testWidgets('reads values at the edited breakpoint', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'m'});
      expect(
        tester
            .widget<SsNumberField>(find.byKey(const ValueKey('field:x')))
            .value,
        10,
      );
      c.read(editorControllerProvider.notifier).setEditingBreakpoint('mobile');
      await tester.pump();
      expect(
        tester
            .widget<SsNumberField>(find.byKey(const ValueKey('field:x')))
            .value,
        33,
      );
    });

    testWidgets('typing writes the value; arithmetic is evaluated', (
      tester,
    ) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      await typeInto(tester, 'x', '120/2');
      expect(valueAt(c, 'a', 'x', 'desktop'), const ir.IrValue.number(60));
      expect(valueAt(c, 'a', 'x', 'mobile'), const ir.IrValue.number(60));
    });

    testWidgets('scope Both writes the base; This breakpoint writes a patch', (
      tester,
    ) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.setEditScope(EditScope.thisBreakpoint);
      ctl.setEditingBreakpoint('mobile');
      await tester.pump();
      await typeInto(tester, 'x', '77');
      expect(valueAt(c, 'a', 'x', 'mobile'), const ir.IrValue.number(77));
      expect(valueAt(c, 'a', 'x', 'desktop'), const ir.IrValue.number(10));
      expect(
        (nodeOf(c, 'a').common.breakpointOverrides['mobile'] ?? {})['x'],
        const ir.IrValue.number(77),
      );
    });

    testWidgets('holding Alt flips the scope for one commit', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.setEditingBreakpoint('mobile');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await typeInto(tester, 'x', '55');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      // Scope was Both; Alt flipped it to This breakpoint.
      expect(valueAt(c, 'a', 'x', 'mobile'), const ir.IrValue.number(55));
      expect(valueAt(c, 'a', 'x', 'desktop'), const ir.IrValue.number(10));
      expect(c.read(editorControllerProvider).scopeFlipped, isFalse);
      expect(c.read(editorControllerProvider).editScope, EditScope.both);
      // Without Alt it is Both again.
      await typeInto(tester, 'x', '66');
      expect(valueAt(c, 'a', 'x', 'desktop'), const ir.IrValue.number(66));
    });

    testWidgets('multi-select shows Mixed and edits apply to all', (
      tester,
    ) async {
      final c = await pumpInspector(tester, _doc(), select: {'a', 'b'});
      expect(find.text('2 layers'), findsOneWidget);
      expect(
        tester
            .widget<SsNumberField>(find.byKey(const ValueKey('field:x')))
            .mixed,
        isTrue,
      );
      expect(
        tester
            .widget<SsNumberField>(find.byKey(const ValueKey('field:y')))
            .mixed,
        isFalse,
      );
      await typeInto(tester, 'x', '5');
      expect(valueAt(c, 'a', 'x', 'desktop'), const ir.IrValue.number(5));
      expect(valueAt(c, 'b', 'x', 'desktop'), const ir.IrValue.number(5));
    });

    testWidgets('a scrub is one undo step', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      final label = find.descendant(
        of: find.byKey(const ValueKey('field:x')),
        matching: find.text('X'),
      );
      final before = c.read(editorControllerProvider).document;
      final g = await tester.startGesture(tester.getCenter(label));
      for (var i = 0; i < 12; i++) {
        await g.moveBy(const Offset(4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      final after = c.read(editorControllerProvider).document;
      expect(
        valueAt(c, 'a', 'x', 'desktop'),
        isNot(const ir.IrValue.number(10)),
      );
      final ctl = c.read(editorControllerProvider.notifier);
      expect(ctl.undo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
      expect(ctl.redo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, after),
        isTrue,
      );
      expect(ctl.history.canUndo, isTrue);
      ctl.undo();
      expect(ctl.history.canUndo, isFalse, reason: 'exactly one entry');
    });
  });

  group('value sources', () {
    testWidgets('a breakpoint override shows a tinted badge', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'m'});
      // Desktop has no patch: no badge.
      expect(find.byKey(const ValueKey('value-source-dot')), findsNothing);
      c.read(editorControllerProvider.notifier).setEditingBreakpoint('mobile');
      await tester.pump();
      expect(find.byKey(const ValueKey('value-source-dot')), findsOneWidget);
      expect(find.byKey(const ValueKey('override-tint')), findsOneWidget);
    });

    testWidgets('right-click offers reset, which removes the patch', (
      tester,
    ) async {
      final c = await pumpInspector(tester, _doc(), select: {'m'});
      c.read(editorControllerProvider.notifier).setEditingBreakpoint('mobile');
      await tester.pump();
      final g = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('field:x'))),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pump();
      await tester.pump();
      expect(find.text('Mobile override'), findsOneWidget);
      await tester.tap(find.text('Reset to inherited'));
      await tester.pump();
      await tester.pump();
      expect(valueAt(c, 'm', 'x', 'mobile'), const ir.IrValue.number(10));
      expect(find.byKey(const ValueKey('value-source-dot')), findsNothing);
    });
  });

  group('position', () {
    testWidgets('typing a width on a Hug node makes it Fixed', (tester) async {
      final doc = inspectorDoc([
        rect(
          'h',
          layoutChild: const ir.LayoutChild(horizontalSizing: ir.Sizing.hug),
        ),
      ]);
      final c = await pumpInspector(tester, doc, select: {'h'});
      await typeInto(tester, 'width', '80');
      expect(nodeOf(c, 'h').common.width, 80);
      expect(
        nodeOf(c, 'h').common.layoutChild.horizontalSizing,
        ir.Sizing.fixed,
      );
    });

    testWidgets('constraints widget shows for children of a free frame', (
      tester,
    ) async {
      await pumpInspector(tester, _doc(), select: {'a'});
      expect(find.byType(SsConstraintsWidget), findsOneWidget);
    });

    testWidgets('constraints choose and write', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      final w = tester.widget<SsConstraintsWidget>(
        find.byType(SsConstraintsWidget),
      );
      w.onChanged!(SsHConstraint.leftRight, SsVConstraint.top);
      await tester.pump();
      expect(
        nodeOf(c, 'a').common.layoutChild.constraints.horizontal,
        ir.HorizontalConstraint.leftRight,
      );
    });

    testWidgets('Ignore auto layout appears inside auto layout', (
      tester,
    ) async {
      final doc = inspectorDoc([
        box(
          'row',
          autoLayout: const ir.AutoLayout(),
          children: [rect('c1'), rect('c2')],
        ),
      ]);
      final c = await pumpInspector(tester, doc, select: {'c1'});
      expect(find.text('Ignore auto layout'), findsOneWidget);
      expect(find.byType(SsConstraintsWidget), findsNothing);
      await tester.tap(find.text('Ignore auto layout'));
      await tester.pump();
      await tester.pump();
      expect(
        nodeOf(c, 'c1').common.layoutChild.positioning,
        ir.Positioning.absolute,
      );
      expect(find.byType(SsConstraintsWidget), findsOneWidget);
    });

    testWidgets('clip content is a frame option', (tester) async {
      final doc = inspectorDoc([box('f'), rect('r')]);
      await pumpInspector(tester, doc, select: {'f'});
      expect(find.text('Clip content'), findsOneWidget);
    });
  });

  group('align and distribute', () {
    testWidgets('align left on a multi-selection', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a', 'b'});
      await tester.tap(find.byKey(const ValueKey('align:left')));
      await tester.pump();
      expect(nodeOf(c, 'a').common.x, 10);
      expect(nodeOf(c, 'b').common.x, 10);
    });

    testWidgets('a single node aligns to its parent', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      await tester.tap(find.byKey(const ValueKey('align:right')));
      await tester.pump();
      expect(nodeOf(c, 'a').common.x, 900); // 1000 - 100
    });

    testWidgets('distribute needs three and equalises the gaps', (
      tester,
    ) async {
      final doc = inspectorDoc([
        rect('p', x: 0, w: 100),
        rect('q', x: 120, w: 100),
        rect('r', x: 500, w: 100),
      ]);
      final c = await pumpInspector(tester, doc, select: {'p', 'q', 'r'});
      await tester.tap(find.byKey(const ValueKey('distribute:h')));
      await tester.pump();
      expect(nodeOf(c, 'q').common.x, 250);
      expect(nodeOf(c, 'p').common.x, 0);
      expect(nodeOf(c, 'r').common.x, 500);
    });
  });
}
