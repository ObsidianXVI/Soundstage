import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/sections/auto_layout_padding.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

const _pad8 = ir.EdgeInsetsValue(top: 8, right: 8, bottom: 8, left: 8);

ir.FrameNode _frame(
  String id, {
  ir.AutoLayout? autoLayout,
  Map<String, ir.Patch> patches = const {},
  List<ir.Node> children = const [],
  double x = 0,
}) => ir.FrameNode(
  common: ir.NodeCommon(
    id: id,
    name: id,
    x: x,
    width: 300,
    height: 200,
    breakpointOverrides: patches,
  ),
  autoLayout: autoLayout,
  children: children,
);

ir.StageDocument _doc() => inspectorDoc([
  _frame(
    'h',
    autoLayout: const ir.AutoLayout(gap: ir.Gap.fixed(10), padding: _pad8),
    patches: const {
      'mobile': {'autoLayout.gap': ir.IrValue.gap(ir.Gap.fixed(20))},
    },
    children: [rect('h1'), rect('h2')],
  ),
  _frame(
    'v',
    x: 400,
    autoLayout: const ir.AutoLayout(
      direction: ir.LayoutDirection.vertical,
      gap: ir.Gap.auto(),
      padding: ir.EdgeInsetsValue(top: 4, bottom: 4, left: 16, right: 16),
    ),
  ),
  _frame(
    'free',
    x: 800,
    children: [
      rect('c1', x: 10, y: 10, w: 40, h: 40),
      rect('c2', x: 70, y: 10, w: 40, h: 40),
    ],
  ),
  _frame('free2', x: 900),
]);

ir.AutoLayout? _al(ProviderContainer c, String id) =>
    (nodeOf(c, id) as ir.FrameNode).autoLayout;

SsNumberField _number(WidgetTester tester, String key) => tester.widget(
  find.descendant(
    of: find.byKey(ValueKey<String>(key)),
    matching: find.byType(SsNumberField),
    matchRoot: true,
  ),
);

/// Collects layout errors (other sections' too) instead of failing on the
/// first; the returned function lists those raised inside the widget keyed
/// [section] (its key appears in the error's creator chain).
List<String> Function(String section) captureLayoutErrors() {
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.toString());
  addTearDown(() => FlutterError.onError = previous);
  return (section) => [
    for (final e in errors)
      if (e.contains(section)) e,
  ];
}

Future<void> _pump(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 400));

void main() {
  const tall = 1800.0;

  group('auto layout: reading', () {
    testWidgets('reads the gap at each breakpoint', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      expect(find.text('Auto layout'), findsOneWidget);
      expect(_number(tester, 'field:autoLayout.gap').value, 10);
      c.read(editorControllerProvider.notifier).setEditingBreakpoint('mobile');
      await tester.pump();
      expect(_number(tester, 'field:autoLayout.gap').value, 20);
      expect(find.byKey(const ValueKey('override-tint')), findsWidgets);
    });

    testWidgets('a frame without auto layout shows the hint and "+"', (
      tester,
    ) async {
      await pumpInspector(tester, _doc(), select: {'free'}, height: tall);
      expect(find.byKey(const ValueKey('auto-layout:hint')), findsOneWidget);
      expect(find.byKey(const ValueKey('auto-layout:add')), findsOneWidget);
      expect(find.byKey(const ValueKey('field:autoLayout.gap')), findsNothing);
    });

    testWidgets('two frames that disagree read Mixed', (tester) async {
      await pumpInspector(tester, _doc(), select: {'h', 'v'}, height: tall);
      expect(_number(tester, 'field:autoLayout.gap').mixed, isTrue);
      final dir = tester.widget<SsSegmented<String>>(
        find.byKey(const ValueKey('field:autoLayout.direction')),
      );
      expect(dir.selected, isNull);
      // Every frame has auto layout: the header offers removal.
      expect(find.byKey(const ValueKey('auto-layout:remove')), findsOneWidget);
    });

    testWidgets('a mixed selection edits only the auto-layout frames', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h', 'free'},
        height: tall,
      );
      expect(find.byKey(const ValueKey('auto-layout:add')), findsOneWidget);
      expect(_number(tester, 'field:autoLayout.gap').mixed, isFalse);
      await typeInto(tester, 'autoLayout.gap', '6');
      expect(_al(c, 'h')!.gap, const ir.Gap.fixed(6));
      expect(_al(c, 'free'), isNull);
    });
  });

  group('auto layout: writing', () {
    testWidgets('typing the gap writes; This breakpoint writes a patch', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      await typeInto(tester, 'autoLayout.gap', '-4');
      expect(_al(c, 'h')!.gap, const ir.Gap.fixed(-4), reason: 'negative ok');
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.setEditScope(EditScope.thisBreakpoint);
      ctl.setEditingBreakpoint('mobile');
      await tester.pump();
      await typeInto(tester, 'autoLayout.gap', '30');
      expect(
        valueAt(c, 'h', 'autoLayout.gap', 'mobile'),
        const ir.IrValue.gap(ir.Gap.fixed(30)),
      );
      expect(
        valueAt(c, 'h', 'autoLayout.gap', 'desktop'),
        const ir.IrValue.gap(ir.Gap.fixed(-4)),
      );
    });

    testWidgets('a gap scrub is one undo step', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      final before = c.read(editorControllerProvider).document;
      final label = find.descendant(
        of: find.byKey(const ValueKey('field:autoLayout.gap')),
        matching: find.text('Gap'),
      );
      final g = await tester.startGesture(tester.getCenter(label));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      expect(_al(c, 'h')!.gap, isNot(const ir.Gap.fixed(10)));
      final ctl = c.read(editorControllerProvider.notifier);
      expect(ctl.undo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
      expect(ctl.history.canUndo, isFalse, reason: 'exactly one entry');
    });

    testWidgets('gap switches between a number and Auto', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      await tester.tap(find.byKey(const ValueKey('gap-menu:autoLayout.gap')));
      await _pump(tester);
      await tester.tap(find.text('Auto').last);
      await _pump(tester);
      expect(_al(c, 'h')!.gap, const ir.Gap.auto());
      final dd = find.byKey(const ValueKey('field:autoLayout.gap'));
      expect(tester.widget(dd), isA<SsDropdown<bool>>());
      expect(
        find.descendant(of: dd, matching: find.text('Auto')),
        findsOneWidget,
      );
      // The matrix shows space between.
      expect(
        tester
            .widget<SsAlignmentMatrix>(
              find.byKey(const ValueKey('field:autoLayout.align')),
            )
            .spaceBetween,
        isTrue,
      );
      await tester.tap(dd);
      await _pump(tester);
      await tester.tap(find.text('Fixed').last);
      await _pump(tester);
      expect(_al(c, 'h')!.gap, const ir.Gap.fixed(0));
      expect(_number(tester, 'field:autoLayout.gap').value, 0);
    });

    testWidgets('Space between writes an auto / zero gap', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      final toggle = find.byKey(const ValueKey('field:spaceBetween'));
      await tester.tap(toggle);
      await tester.pump();
      expect(_al(c, 'h')!.gap, const ir.Gap.auto());
      expect(tester.widget<SsToggle>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pump();
      expect(_al(c, 'h')!.gap, const ir.Gap.fixed(0));
    });

    testWidgets('direction and wrap; vertical turns wrap and baseline off', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      expect(
        find.byKey(const ValueKey('field:autoLayout.counterAxisGap')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('field:autoLayout.wrap')));
      await tester.pump();
      expect(_al(c, 'h')!.wrap, isTrue);
      expect(
        find.byKey(const ValueKey('field:autoLayout.counterAxisGap')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('field:autoLayout.rowAlign')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('field:baseline')));
      await tester.pump();
      expect(_al(c, 'h')!.counterAlign, ir.CounterAlign.baseline);

      await tester.tap(find.bySemanticsLabel('Vertical layout'));
      await tester.pump();
      final al = _al(c, 'h')!;
      expect(al.direction, ir.LayoutDirection.vertical);
      expect(al.wrap, isFalse);
      expect(al.counterAlign, ir.CounterAlign.start);
      c.read(editorControllerProvider.notifier).undo();
      expect(_al(c, 'h')!.wrap, isTrue, reason: 'one undo step');
      expect(_al(c, 'h')!.counterAlign, ir.CounterAlign.baseline);
    });

    testWidgets('baseline is disabled for vertical layouts', (tester) async {
      await pumpInspector(tester, _doc(), select: {'v'}, height: tall);
      final cb = tester.widget<SsCheckbox>(
        find.byKey(const ValueKey('field:baseline')),
      );
      expect(cb.onChanged, isNull);
      final wrap = tester.widget<SsIconButton>(
        find.byKey(const ValueKey('field:autoLayout.wrap')),
      );
      expect(wrap.onPressed, isNull);
    });

    testWidgets('checkboxes write their flags', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      await tester.tap(find.text('Include strokes in layout'));
      await tester.tap(find.text('Reverse z-index'));
      await tester.pump();
      expect(_al(c, 'h')!.strokesIncludedInLayout, isTrue);
      expect(_al(c, 'h')!.reverseZIndex, isTrue);
    });
  });

  group('auto layout: alignment matrix', () {
    SsAlignmentMatrix matrix(WidgetTester tester) =>
        tester.widget(find.byKey(const ValueKey('field:autoLayout.align')));

    testWidgets('horizontal: primary is the column, counter the row', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      final f = find.byKey(const ValueKey('field:autoLayout.align'));
      // Bottom-right cell of the 60 px matrix.
      await tester.tapAt(tester.getTopLeft(f) + const Offset(50, 50));
      await tester.pump();
      var al = _al(c, 'h')!;
      expect(al.primaryAlign, ir.PrimaryAlign.end);
      expect(al.counterAlign, ir.CounterAlign.end);
      // Top-centre.
      await tester.tapAt(tester.getTopLeft(f) + const Offset(30, 10));
      await tester.pump();
      al = _al(c, 'h')!;
      expect(al.primaryAlign, ir.PrimaryAlign.center);
      expect(al.counterAlign, ir.CounterAlign.start);
      expect(matrix(tester).horizontal, SsAlign3.center);
      expect(matrix(tester).vertical, SsAlign3.start);
      expect(matrix(tester).direction, Axis.horizontal);
    });

    testWidgets('vertical: primary is the row, counter the column', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'v'},
        height: tall,
      );
      expect(matrix(tester).direction, Axis.vertical);
      matrix(tester).onChanged!(SsAlign3.end, SsAlign3.center);
      await tester.pump();
      final al = _al(c, 'v')!;
      expect(al.primaryAlign, ir.PrimaryAlign.center, reason: 'row');
      expect(al.counterAlign, ir.CounterAlign.end, reason: 'column');
      expect(matrix(tester).horizontal, SsAlign3.end);
      expect(matrix(tester).vertical, SsAlign3.center);
    });

    testWidgets('baseline shows no counter cell', (tester) async {
      final doc = inspectorDoc([
        _frame(
          'b',
          autoLayout: const ir.AutoLayout(
            primaryAlign: ir.PrimaryAlign.end,
            counterAlign: ir.CounterAlign.baseline,
          ),
        ),
      ]);
      await pumpInspector(tester, doc, select: {'b'}, height: tall);
      expect(matrix(tester).horizontal, SsAlign3.end);
      expect(matrix(tester).vertical, isNull);
      final cb = tester.widget<SsCheckbox>(
        find.byKey(const ValueKey('field:baseline')),
      );
      expect(cb.value, isTrue);
    });
  });

  group('auto layout: padding', () {
    test('the mode follows the values', () {
      expect(paddingModeOf(8, 8, 8, 8), PaddingMode.uniform);
      expect(paddingModeOf(4, 16, 4, 16), PaddingMode.axes);
      expect(paddingModeOf(1, 2, 3, 4), PaddingMode.sides);
      expect(paddingModeOf(null, 2, 3, 4), PaddingMode.sides);
    });

    testWidgets('uniform writes all sides in one step; modes cycle', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      expect(fieldText('autoLayout.padding'), findsOneWidget);
      await typeInto(tester, 'autoLayout.padding', '12');
      expect(_al(c, 'h')!.padding, ir.EdgeInsetsValue.all(12));
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.undo();
      expect(_al(c, 'h')!.padding, _pad8, reason: 'one undo step');

      await tester.tap(find.byKey(const ValueKey('padding-mode')));
      await tester.pump();
      expect(fieldText('autoLayout.padding.h'), findsOneWidget);
      await typeInto(tester, 'autoLayout.padding.h', '3');
      expect(
        _al(c, 'h')!.padding,
        const ir.EdgeInsetsValue(top: 8, bottom: 8, left: 3, right: 3),
      );
      await tester.tap(find.byKey(const ValueKey('padding-mode')));
      await tester.pump();
      for (final s in ['top', 'right', 'bottom', 'left']) {
        expect(fieldText('autoLayout.padding.$s'), findsOneWidget);
      }
      await typeInto(tester, 'autoLayout.padding.top', '1');
      expect(_al(c, 'h')!.padding.top, 1);
      expect(_al(c, 'h')!.padding.bottom, 8);
      await tester.tap(find.byKey(const ValueKey('padding-mode')));
      await tester.pump();
      expect(fieldText('autoLayout.padding'), findsOneWidget);
      expect(
        _number(tester, 'field:autoLayout.padding').mixed,
        isTrue,
        reason: 'the sides differ',
      );
    });

    testWidgets('horizontal + vertical padding derives the axes mode', (
      tester,
    ) async {
      await pumpInspector(tester, _doc(), select: {'v'}, height: tall);
      expect(_number(tester, 'field:autoLayout.padding.h').value, 16);
      expect(_number(tester, 'field:autoLayout.padding.v').value, 4);
    });
  });

  group('auto layout: add and remove', () {
    testWidgets('"+" on one frame infers auto layout from its children', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'free'},
        height: tall,
      );
      await tester.tap(find.byKey(const ValueKey('auto-layout:add')));
      await tester.pump();
      final al = _al(c, 'free')!;
      expect(al.direction, ir.LayoutDirection.horizontal);
      expect(al.gap, const ir.Gap.fixed(20), reason: 'inferred');
      expect(find.byKey(const ValueKey('auto-layout:remove')), findsOneWidget);
      expect(_number(tester, 'field:autoLayout.gap').value, 20);
    });

    testWidgets('"+" on several frames adds the default auto layout', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'free', 'free2', 'h'},
        height: tall,
      );
      await tester.tap(find.byKey(const ValueKey('auto-layout:add')));
      await tester.pump();
      expect(_al(c, 'free'), const ir.AutoLayout());
      expect(_al(c, 'free2'), const ir.AutoLayout());
      expect(_al(c, 'h')!.gap, const ir.Gap.fixed(10), reason: 'kept');
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.undo();
      expect(_al(c, 'free'), isNull);
      expect(_al(c, 'free2'), isNull);
    });

    testWidgets('"-" removes auto layout and keeps the children placed', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      await tester.tap(find.byKey(const ValueKey('auto-layout:remove')));
      await tester.pump();
      expect(_al(c, 'h'), isNull);
      // Padding 8, gap 10, 100 wide children.
      expect(nodeOf(c, 'h1').common.x, 8);
      expect(nodeOf(c, 'h2').common.x, 118);
      expect(find.byKey(const ValueKey('auto-layout:hint')), findsOneWidget);
    });

    testWidgets('This breakpoint: "-" removes it on that breakpoint only', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'h'},
        height: tall,
      );
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.setEditScope(EditScope.thisBreakpoint);
      ctl.setEditingBreakpoint('mobile');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('auto-layout:remove')));
      await tester.pump();
      expect(
        valueAt(c, 'h', 'autoLayout', 'mobile'),
        const ir.IrValue.boolean(false),
      );
      expect(
        valueAt(c, 'h', 'autoLayout', 'desktop'),
        const ir.IrValue.boolean(true),
      );
    });
  });

  group('auto layout: narrow panel', () {
    for (final width in [288.0, 240.0]) {
      testWidgets('no overflow at $width px, wrapped, per-side padding', (
        tester,
      ) async {
        final doc = inspectorDoc([
          _frame(
            'w',
            autoLayout: const ir.AutoLayout(
              wrap: true,
              gap: ir.Gap.auto(),
              padding: ir.EdgeInsetsValue(top: 1, right: 2, bottom: 3, left: 4),
            ),
          ),
        ]);
        final overflowsIn = captureLayoutErrors();
        await pumpInspector(
          tester,
          doc,
          select: {'w'},
          width: width,
          height: tall,
        );
        expect(overflowsIn('section:auto_layout'), isEmpty);
        expect(
          find.byKey(const ValueKey('field:autoLayout.counterAxisGap')),
          findsOneWidget,
        );
        expect(fieldText('autoLayout.padding.left'), findsOneWidget);
      });
    }
  });
}
