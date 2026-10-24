import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/sections/paint_stack.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

const _red = ir.StageColor(r: 1, g: 0, b: 0, a: 1);
const _paint = ir.Paint.solid(id: 'sp1', color: _red);

ir.Appearance _stroked({
  ir.StrokeWeight weight = const ir.StrokeWeight.uniform(),
  ir.StrokeJoin join = ir.StrokeJoin.miter,
  List<double> dash = const [],
  String? styleId,
}) => ir.Appearance(
  strokes: ir.Stroke(
    paints: const [_paint],
    weight: weight,
    join: join,
    dash: dash,
  ),
  strokeStyleId: styleId,
);

ir.StageDocument _doc() =>
    inspectorDoc([
      rect('a', appearance: _stroked()),
      rect('b', appearance: _stroked(weight: const ir.StrokeWeight.uniform(4))),
      rect('none'),
      rect('dashed', appearance: _stroked(dash: const [6, 2])),
      rect('bevel', appearance: _stroked(join: ir.StrokeJoin.bevel)),
      rect(
        'm',
        appearance: _stroked(),
        patches: const {
          'mobile': {
            'strokes.weight': ir.IrValue.strokeWeight(
              ir.StrokeWeight.uniform(9),
            ),
          },
        },
      ),
      ir.ShapeNode(
        common: const ir.NodeCommon(id: 'ell', width: 40, height: 40),
        geometry: const ir.ShapeGeometry.ellipse(),
        appearance: _stroked(),
      ),
      rect('styled', appearance: _stroked(styleId: 'ps')),
    ]).copyWith(
      tokens: const ir.TokenSystem(
        paintStyles: {
          'ps': ir.PaintStyleDef(
            name: 'Brand line',
            paints: [ir.Paint.solid(id: 'st1', color: _red)],
          ),
        },
      ),
    );

SsNumberField _num(WidgetTester t, String path) =>
    t.widget<SsNumberField>(find.byKey(ValueKey<String>('field:$path')));

Finder _seg(String key, String label) => find.descendant(
  of: find.byKey(ValueKey<String>(key)),
  matching: find.text(label),
);

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
  group('Stroke section', () {
    testWidgets('wires the paint stack and the add button', (tester) async {
      await pumpInspector(tester, _doc(), height: 1800, select: {'a'});
      final stacks = tester
          .widgetList<PaintStackEditor>(find.byType(PaintStackEditor))
          .where((e) => e.stackPath == 'strokes.paints')
          .toList();
      expect(stacks, hasLength(1));
      expect(stacks.single.allowImage, isFalse);
      expect(
        tester
            .widgetList<AddPaintButton>(find.byType(AddPaintButton))
            .where((e) => e.stackPath == 'strokes.paints'),
        hasLength(1),
      );
    });

    testWidgets('geometry shows only when there are paints', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'none'},
      );
      expect(find.byKey(const ValueKey('field:strokes.weight')), findsNothing);
      c.read(editorControllerProvider.notifier).select({'a'});
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('field:strokes.weight')),
        findsOneWidget,
      );
    });

    testWidgets('weight reads per breakpoint and writes with scope', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'m'},
      );
      expect(_num(tester, 'strokes.weight').value, 1);
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.setEditingBreakpoint('mobile');
      await tester.pump();
      expect(_num(tester, 'strokes.weight').value, 9);
      ctl.setEditScope(EditScope.thisBreakpoint);
      await typeInto(tester, 'strokes.weight', '3');
      expect(
        valueAt(c, 'm', 'strokes.weight', 'mobile'),
        const ir.IrValue.strokeWeight(ir.StrokeWeight.uniform(3)),
      );
      expect(
        valueAt(c, 'm', 'strokes.weight', 'desktop'),
        const ir.IrValue.strokeWeight(ir.StrokeWeight.uniform(1)),
      );
    });

    testWidgets('weight is Mixed across nodes and applies to both', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'a', 'b'},
      );
      expect(_num(tester, 'strokes.weight').mixed, isTrue);
      await typeInto(tester, 'strokes.weight', '2');
      for (final id in ['a', 'b']) {
        expect(
          valueAt(c, id, 'strokes.weight', 'desktop'),
          const ir.IrValue.strokeWeight(ir.StrokeWeight.uniform(2)),
        );
      }
    });

    testWidgets('per-side round trip; one undo step', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'a'},
      );
      final before = c.read(editorControllerProvider).document;
      await tester.tap(find.byKey(const ValueKey('weight-mode')));
      await tester.pumpAndSettle();
      expect(
        valueAt(c, 'a', 'strokes.weight', 'desktop'),
        const ir.IrValue.strokeWeight(
          ir.StrokeWeight.perSide(top: 1, right: 1, bottom: 1, left: 1),
        ),
      );
      await typeInto(tester, 'strokes.weight.left', '5');
      expect(
        valueAt(c, 'a', 'strokes.weight.left', 'desktop'),
        const ir.IrValue.number(5),
      );
      expect(
        valueAt(c, 'a', 'strokes.weight.top', 'desktop'),
        const ir.IrValue.number(1),
      );
      await tester.tap(find.byKey(const ValueKey('weight-mode')));
      await tester.pump();
      expect(
        valueAt(c, 'a', 'strokes.weight', 'desktop'),
        const ir.IrValue.strokeWeight(ir.StrokeWeight.uniform(1)),
      );
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.undo();
      ctl.undo();
      ctl.undo();
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
    });

    testWidgets('per-side is not offered on ellipses', (tester) async {
      await pumpInspector(tester, _doc(), height: 1800, select: {'ell'});
      expect(find.byKey(const ValueKey('weight-mode')), findsNothing);
      expect(
        find.byKey(const ValueKey('field:strokes.weight')),
        findsOneWidget,
      );
    });

    testWidgets('a weight scrub is one undo step', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'a'},
      );
      final before = c.read(editorControllerProvider).document;
      final label = find.descendant(
        of: find.byKey(const ValueKey('field:strokes.weight')),
        matching: find.text('W'),
      );
      final g = await tester.startGesture(tester.getCenter(label));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      final ctl = c.read(editorControllerProvider.notifier);
      expect(ctl.undo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
      expect(ctl.history.canUndo, isFalse);
    });

    testWidgets('position, cap and join write enums', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'a'},
      );
      await tester.tap(_seg('field:strokes.align', 'Outside'));
      await tester.pump();
      expect(
        valueAt(c, 'a', 'strokes.align', 'desktop'),
        const ir.IrValue.enumValue('outside'),
      );
      await tester.tap(find.byKey(const ValueKey('field:strokes.cap')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(SsMenu), matching: find.text('Round')),
      );
      await tester.pumpAndSettle();
      expect(
        valueAt(c, 'a', 'strokes.cap', 'desktop'),
        const ir.IrValue.enumValue('round'),
      );
    });

    testWidgets('miter limit only for miter joins', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'a'},
      );
      expect(
        find.byKey(const ValueKey('field:strokes.miterLimit')),
        findsOneWidget,
      );
      await typeInto(tester, 'strokes.miterLimit', '6');
      expect(
        valueAt(c, 'a', 'strokes.miterLimit', 'desktop'),
        const ir.IrValue.number(6),
      );
      c.read(editorControllerProvider.notifier).select({'bevel'});
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('field:strokes.miterLimit')),
        findsNothing,
      );
    });

    testWidgets('dash toggle, lengths and clearing', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'a'},
      );
      expect(
        find.byKey(const ValueKey('field:strokes.dash.dash')),
        findsNothing,
      );
      await tester.tap(_seg('field:strokes.dash', 'Dashed'));
      await tester.pumpAndSettle();
      expect(
        valueAt(c, 'a', 'strokes.dash', 'desktop'),
        const ir.IrValue.numbers([8, 4]),
      );
      await typeInto(tester, 'strokes.dash.dash', '10');
      expect(
        valueAt(c, 'a', 'strokes.dash', 'desktop'),
        const ir.IrValue.numbers([10, 4]),
      );
      await typeInto(tester, 'strokes.dash.gap', '2');
      expect(
        valueAt(c, 'a', 'strokes.dash', 'desktop'),
        const ir.IrValue.numbers([10, 2]),
      );
      await typeInto(tester, 'strokes.dash.dash', '0');
      await typeInto(tester, 'strokes.dash.gap', '0');
      expect(
        valueAt(c, 'a', 'strokes.dash', 'desktop'),
        const ir.IrValue.numbers([]),
      );
      await tester.tap(_seg('field:strokes.dash', 'Dashed'));
      await tester.pump();
      await tester.tap(_seg('field:strokes.dash', 'Solid'));
      await tester.pump();
      expect(
        valueAt(c, 'a', 'strokes.dash', 'desktop'),
        const ir.IrValue.numbers([]),
      );
    });

    testWidgets('dash is Mixed across nodes', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'a', 'dashed'},
      );
      expect(
        tester
            .widget<SsSegmented<String>>(
              find.byKey(const ValueKey('field:strokes.dash')),
            )
            .selected,
        isNull,
      );
      expect(
        find.byKey(const ValueKey('field:strokes.dash.dash')),
        findsNothing,
      );
      await tester.tap(_seg('field:strokes.dash', 'Dashed'));
      await tester.pump();
      for (final id in ['a', 'dashed']) {
        expect(
          valueAt(c, id, 'strokes.dash', 'desktop'),
          const ir.IrValue.numbers([8, 4]),
        );
      }
    });

    testWidgets('a style shows a banner; Detach writes paints and clears it', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        height: 1800,
        select: {'styled'},
      );
      expect(find.text('Style: Brand line'), findsOneWidget);
      await tester.tap(find.text('Detach'));
      await tester.pump();
      final n = nodeOf(c, 'styled') as ir.ShapeNode;
      expect(n.appearance.strokeStyleId, isNull);
      expect(n.appearance.strokes.paints.single.id, 'st1');
      await tester.pumpAndSettle();
      expect(find.text('Style: Brand line'), findsNothing);
      c.read(editorControllerProvider.notifier).undo();
      expect(
        (nodeOf(c, 'styled') as ir.ShapeNode).appearance.strokeStyleId,
        'ps',
      );
    });

    testWidgets('fits 240 px wide', (tester) async {
      final errors = <String>[];
      final prev = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.toString());
      addTearDown(() => FlutterError.onError = prev);
      final c = await pumpInspector(
        tester,
        _doc(),
        width: 240,
        select: {'dashed'},
      );
      await tester.tap(find.byKey(const ValueKey('weight-mode')));
      await tester.pump();
      c.read(editorControllerProvider.notifier).select({'styled'});
      await tester.pumpAndSettle();
      expect(errors.where(_mine), isEmpty);
    });
  });
}
