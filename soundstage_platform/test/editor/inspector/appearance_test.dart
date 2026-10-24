import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

ir.StageDocument _doc() => inspectorDoc([
  rect('a'),
  rect('b', opacity: 0.5),
  rect(
    'm',
    patches: const {
      'mobile': {'opacity': ir.IrValue.number(0.25)},
    },
  ),
  box('f'),
  const ir.ShapeNode(
    common: ir.NodeCommon(id: 'e', width: 40, height: 40),
    geometry: ir.ShapeGeometry.ellipse(),
  ),
]);

SsNumberField _num(WidgetTester t, String path) =>
    t.widget<SsNumberField>(find.byKey(ValueKey<String>('field:$path')));

SsDropdown<String> _blend(WidgetTester t) =>
    t.widget<SsDropdown<String>>(find.byKey(const ValueKey('field:blendMode')));

/// Layout errors not caused by the other sections (owned elsewhere).
bool _mine(String e) => !const [
  'frame_section',
  'header_section',
  'auto_layout_section',
  'layout_child_section',
  'fill_section',
  'paint_stack',
  'text_section',
].any(e.contains);

void main() {
  group('Appearance: opacity', () {
    testWidgets('reads at each breakpoint', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'m'});
      expect(_num(tester, 'opacity').value, 100);
      c.read(editorControllerProvider.notifier).setEditingBreakpoint('mobile');
      await tester.pump();
      expect(_num(tester, 'opacity').value, 25);
    });

    testWidgets('writes as a fraction; scope routes to a patch', (
      tester,
    ) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      await typeInto(tester, 'opacity', '30');
      expect(
        valueAt(c, 'a', 'opacity', 'desktop'),
        const ir.IrValue.number(0.3),
      );
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.setEditScope(EditScope.thisBreakpoint);
      ctl.setEditingBreakpoint('mobile');
      await tester.pump();
      await typeInto(tester, 'opacity', '60');
      expect(
        valueAt(c, 'a', 'opacity', 'mobile'),
        const ir.IrValue.number(0.6),
      );
      expect(
        valueAt(c, 'a', 'opacity', 'desktop'),
        const ir.IrValue.number(0.3),
      );
    });

    testWidgets('Mixed across two nodes; edit applies to both', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a', 'b'});
      expect(_num(tester, 'opacity').mixed, isTrue);
      await typeInto(tester, 'opacity', '40');
      expect(
        valueAt(c, 'a', 'opacity', 'desktop'),
        const ir.IrValue.number(0.4),
      );
      expect(
        valueAt(c, 'b', 'opacity', 'desktop'),
        const ir.IrValue.number(0.4),
      );
    });
  });

  group('Appearance: blend mode', () {
    testWidgets('unset reads as the kind default', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      expect(_blend(tester).value, 'normal');
      c.read(editorControllerProvider.notifier).select({'f'});
      await tester.pumpAndSettle();
      expect(_blend(tester).value, 'passThrough');
    });

    testWidgets('Pass through is offered for frames only', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      await tester.tap(find.byKey(const ValueKey('field:blendMode')));
      await tester.pumpAndSettle();
      expect(find.text('Multiply'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SsMenu),
          matching: find.text('Pass through'),
        ),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      c.read(editorControllerProvider.notifier).select({'f'});
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('field:blendMode')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SsMenu),
          matching: find.text('Pass through'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    });

    testWidgets('choosing writes the mode; the default clears it', (
      tester,
    ) async {
      final c = await pumpInspector(tester, _doc(), select: {'f'});
      await tester.tap(find.byKey(const ValueKey('field:blendMode')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Multiply'));
      await tester.pumpAndSettle();
      expect(
        valueAt(c, 'f', 'blendMode', 'desktop'),
        const ir.IrValue.enumValue('multiply'),
      );
      await tester.tap(find.byKey(const ValueKey('field:blendMode')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SsMenu),
          matching: find.text('Pass through'),
        ),
      );
      await tester.pumpAndSettle();
      expect(nodeOf(c, 'f').common.blendMode, isNull);
    });

    testWidgets('Mixed when nodes disagree', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a', 'b'});
      c
          .read(editorControllerProvider.notifier)
          .execute(
            SetProperty(
              ['a'],
              'blendMode',
              const ir.IrValue.enumValue('screen'),
            ),
          );
      await tester.pump();
      expect(_blend(tester).mixed, isTrue);
    });
  });

  group('Appearance: corner radius', () {
    testWidgets('uniform write, toggle to per-corner and back', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      await typeInto(tester, 'cornerRadius', '8');
      expect(
        valueAt(c, 'a', 'cornerRadius', 'desktop'),
        const ir.IrValue.cornerRadius(ir.CornerRadius.uniform(8)),
      );
      await tester.tap(find.byKey(const ValueKey('corner-mode')));
      await tester.pump();
      expect(
        valueAt(c, 'a', 'cornerRadius', 'desktop'),
        const ir.IrValue.cornerRadius(
          ir.CornerRadius.perCorner(tl: 8, tr: 8, br: 8, bl: 8),
        ),
      );
      expect(fieldText('cornerRadius.tl'), findsOneWidget);
      expect(fieldText('cornerRadius.bl'), findsOneWidget);
      await typeInto(tester, 'cornerRadius.tl', '4');
      expect(
        valueAt(c, 'a', 'cornerRadius.tl', 'desktop'),
        const ir.IrValue.number(4),
      );
      expect(
        valueAt(c, 'a', 'cornerRadius.br', 'desktop'),
        const ir.IrValue.number(8),
      );
      await tester.tap(find.byKey(const ValueKey('corner-mode')));
      await tester.pump();
      expect(
        valueAt(c, 'a', 'cornerRadius', 'desktop'),
        const ir.IrValue.cornerRadius(ir.CornerRadius.uniform(4)),
      );
    });

    testWidgets('a toggle is one undo step', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      final before = c.read(editorControllerProvider).document;
      await tester.tap(find.byKey(const ValueKey('corner-mode')));
      await tester.pump();
      expect(c.read(editorControllerProvider.notifier).undo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
    });

    testWidgets('a scrub is one undo step', (tester) async {
      final c = await pumpInspector(tester, _doc(), select: {'a'});
      final before = c.read(editorControllerProvider).document;
      final label = find.descendant(
        of: find.byKey(const ValueKey('field:cornerRadius')),
        matching: find.text('R'),
      );
      final g = await tester.startGesture(tester.getCenter(label));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      expect(
        valueAt(c, 'a', 'cornerRadius', 'desktop'),
        isNot(const ir.IrValue.cornerRadius(ir.CornerRadius.uniform(0))),
      );
      final ctl = c.read(editorControllerProvider.notifier);
      expect(ctl.undo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
      expect(ctl.history.canUndo, isFalse);
    });

    testWidgets('reads the breakpoint patch; Mixed across nodes', (
      tester,
    ) async {
      final doc = inspectorDoc([
        rect(
          'p',
          appearance: const ir.Appearance(
            cornerRadius: ir.CornerRadius.uniform(3),
          ),
        ),
        rect('q'),
      ]);
      final c = await pumpInspector(tester, doc, select: {'p', 'q'});
      expect(_num(tester, 'cornerRadius').mixed, isTrue);
      c.read(editorControllerProvider.notifier).select({'p'});
      await tester.pump();
      expect(_num(tester, 'cornerRadius').value, 3);
    });

    testWidgets('hidden for ellipses; smoothing writes a fraction', (
      tester,
    ) async {
      final c = await pumpInspector(tester, _doc(), select: {'e'});
      expect(find.byKey(const ValueKey('field:cornerRadius')), findsNothing);
      c.read(editorControllerProvider.notifier).select({'f'});
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('field:cornerRadius')), findsOneWidget);
      await typeInto(tester, 'cornerSmoothing', '60');
      expect(
        valueAt(c, 'f', 'cornerSmoothing', 'desktop'),
        const ir.IrValue.number(0.6),
      );
    });
  });

  testWidgets('fits 240 px wide, uniform and per-corner', (tester) async {
    final errors = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.toString());
    addTearDown(() => FlutterError.onError = prev);
    await pumpInspector(tester, _doc(), width: 240, select: {'f'});
    await tester.tap(find.byKey(const ValueKey('corner-mode')));
    await tester.pump();
    // Other sections are tested by their owners.
    expect(errors.where(_mine), isEmpty);
  });
}
