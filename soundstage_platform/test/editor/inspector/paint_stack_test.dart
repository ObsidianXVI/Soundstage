import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/sections/paint_stack.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';
import 'paint_test_utils.dart';

const _red = ir.StageColor(r: 1, g: 0, b: 0);
const _blue = ir.StageColor(r: 0, g: 0, b: 1);

ir.Appearance _fills(List<ir.Paint> fills) => ir.Appearance(fills: fills);

ir.StageDocument _doc({List<ir.Paint>? fills, List<ir.Paint>? otherFills}) =>
    inspectorDoc([
      rect(
        'a',
        appearance: _fills(
          fills ??
              const [
                ir.Paint.solid(id: 'p1', color: _red),
                ir.Paint.solid(id: 'p2', color: _blue),
              ],
        ),
      ),
      rect(
        'b',
        x: 200,
        appearance: _fills(
          otherFills ??
              fills ??
              const [
                ir.Paint.solid(id: 'p1', color: _red),
                ir.Paint.solid(id: 'p2', color: _blue),
              ],
        ),
      ),
    ]);

List<String> idsOf(ProviderContainer c, String id) => [
  for (final p in fillsOf(c, id)) p.id,
];

Future<void> openMenu(WidgetTester tester, String paintId) =>
    tapKey(tester, 'paint-menu:$paintId');

void main() {
  testWidgets('rows show the top paint first', (tester) async {
    await pumpPaints(tester, _doc(), select: {'a'});
    final top = tester.getTopLeft(find.byKey(const ValueKey('paint-row:p2')));
    final bottom = tester.getTopLeft(
      find.byKey(const ValueKey('paint-row:p1')),
    );
    expect(top.dy < bottom.dy, isTrue);
  });

  testWidgets('add appends a default solid on top, deterministically', (
    tester,
  ) async {
    final c = await pumpPaints(tester, _doc(), select: {'a'});
    await tapOn(tester, find.byKey(const ValueKey('add-paint:fills')));
    final fills = fillsOf(c, 'a');
    expect(fills.length, 3);
    final added = fills.last as ir.SolidPaint;
    expect(added.color, ir.StageColor.fromHex('#D9D9D9'));
    expect(ir.isGeneratedId(added.id), isTrue);
    // Deterministic: the same document always gives the same id.
    expect(added.id, freshPaintId(_doc()));
    expect(c.read(editorControllerProvider.notifier).history.undoDepth, 1);
  });

  testWidgets('remove writes the whole list without the paint', (tester) async {
    final c = await pumpPaints(tester, _doc(), select: {'a'});
    await tapOn(tester, find.byKey(const ValueKey('paint-remove:p2')));
    expect(idsOf(c, 'a'), ['p1']);
    expect(c.read(editorControllerProvider.notifier).history.undoDepth, 1);
  });

  testWidgets('move down and up from the row menu reorder the list', (
    tester,
  ) async {
    final c = await pumpPaints(tester, _doc(), select: {'a'});
    // p2 is on top: Move down puts it below p1 (IR: p2, p1).
    await openMenu(tester, 'p2');
    await tester.tap(find.text('Move down'));
    await tester.pump();
    await tester.pump();
    expect(idsOf(c, 'a'), ['p2', 'p1']);
    await openMenu(tester, 'p2');
    await tester.tap(find.text('Move up'));
    await tester.pump();
    await tester.pump();
    expect(idsOf(c, 'a'), ['p1', 'p2']);
    expect(c.read(editorControllerProvider.notifier).history.undoDepth, 2);
  });

  testWidgets('visibility toggles the per-paint path', (tester) async {
    final c = await pumpPaints(tester, _doc(), select: {'a'});
    await tapOn(tester, find.byKey(const ValueKey('paint-visible:p1')));
    expect(fillsOf(c, 'a').first.visible, isFalse);
    expect(fillsOf(c, 'a').last.visible, isTrue);
  });

  testWidgets('opacity edits the per-paint path at each breakpoint scope', (
    tester,
  ) async {
    final c = await pumpPaints(tester, _doc(), select: {'a'});
    await typeInto(tester, 'fills.p1.opacity', '40');
    expect(fillsOf(c, 'a').first.opacity, closeTo(0.4, 1e-9));
    final ctl = c.read(editorControllerProvider.notifier);
    ctl.setEditScope(EditScope.thisBreakpoint);
    ctl.setEditingBreakpoint('mobile');
    await tester.pump();
    await typeInto(tester, 'fills.p1.opacity', '25');
    expect(
      valueAt(c, 'a', 'fills.p1.opacity', 'mobile'),
      const ir.IrValue.number(0.25),
    );
    expect(
      valueAt(c, 'a', 'fills.p1.opacity', 'desktop'),
      const ir.IrValue.number(0.4),
    );
    expect(
      nodeOf(c, 'a').common.breakpointOverrides['mobile']!['fills.p1.opacity'],
      const ir.IrValue.number(0.25),
    );
  });

  testWidgets('reads follow the edited breakpoint; overrides show a badge', (
    tester,
  ) async {
    final doc = inspectorDoc([
      ir.ShapeNode(
        common: const ir.NodeCommon(
          id: 'a',
          width: 100,
          height: 50,
          breakpointOverrides: {
            'mobile': {'fills.p1.color': ir.IrValue.color(_blue)},
          },
        ),
        appearance: _fills(const [ir.Paint.solid(id: 'p1', color: _red)]),
      ),
    ]);
    final c = await pumpPaints(tester, doc, select: {'a'});
    String hex() => tester
        .widget<EditableText>(fieldText('fills.p1.color'))
        .controller
        .text;
    expect(hex(), 'FF0000');
    expect(find.byKey(const ValueKey('value-source-dot')), findsNothing);
    c.read(editorControllerProvider.notifier).setEditingBreakpoint('mobile');
    await tester.pump();
    expect(hex(), '0000FF');
    expect(find.byKey(const ValueKey('value-source-dot')), findsOneWidget);
  });

  testWidgets('hex typing writes the colour, keeping its alpha', (
    tester,
  ) async {
    final c = await pumpPaints(
      tester,
      _doc(
        fills: const [
          ir.Paint.solid(
            id: 'p1',
            color: ir.StageColor(r: 1, g: 0, b: 0, a: 0.5),
          ),
        ],
      ),
      select: {'a'},
    );
    await typeInto(tester, 'fills.p1.color', '00ff00');
    final p = fillsOf(c, 'a').single as ir.SolidPaint;
    expect(p.color.toHex(includeAlpha: true), '#00ff0080');
  });

  testWidgets('blend mode writes the per-paint path', (tester) async {
    final c = await pumpPaints(tester, _doc(), select: {'a'});
    await tapOn(tester, find.byKey(const ValueKey('paint-swatch:p1')));
    await tapOn(tester, find.byKey(const ValueKey('field:fills.p1.blendMode')));
    await tester.tap(find.text('Multiply').last);
    await tester.pump();
    await tester.pump();
    expect(fillsOf(c, 'a').first.blendMode, ir.BlendMode.multiply);
    expect(fillsOf(c, 'a').last.blendMode, ir.BlendMode.normal);
  });

  group('kind switch', () {
    Future<void> switchKind(
      WidgetTester tester,
      String id,
      String label, {
      bool detail = false,
    }) async {
      await tapOn(
        tester,
        find.byKey(
          ValueKey<String>(detail ? 'paint-kind-detail:$id' : 'paint-kind:$id'),
        ),
      );
      await tester.tap(find.text(label).last);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('solid → linear: colour to transparent, id kept', (
      tester,
    ) async {
      final c = await pumpPaints(tester, _doc(), select: {'a'});
      await tapOn(tester, find.byKey(const ValueKey('paint-swatch:p1')));
      await switchKind(tester, 'p1', 'Linear', detail: true);
      final g = fillsOf(c, 'a').first as ir.GradientPaint;
      expect(g.id, 'p1');
      expect(g.kind, ir.GradientKind.linear);
      expect(g.stops.first.color, _red);
      expect(g.stops.last.color, _red.withAlpha(0));
      expect(c.read(editorControllerProvider.notifier).history.undoDepth, 1);
    });

    testWidgets('gradient → gradient keeps stops and handles', (tester) async {
      const stops = [
        ir.ColorStop(position: 0, color: _red),
        ir.ColorStop(position: 0.7, color: _blue),
      ];
      const handles = ir.GradientHandles(
        start: ir.StagePoint(x: 0.1, y: 0.2),
        end: ir.StagePoint(x: 0.9, y: 0.8),
      );
      final c = await pumpPaints(
        tester,
        _doc(
          fills: const [
            ir.Paint.gradient(id: 'g', stops: stops, handles: handles),
          ],
        ),
        select: {'a'},
      );
      await switchKind(tester, 'g', 'Radial');
      final g = fillsOf(c, 'a').single as ir.GradientPaint;
      expect(g.kind, ir.GradientKind.radial);
      expect(g.stops, stops);
      expect(g.handles, handles);
      await switchKind(tester, 'g', 'Solid');
      final s = fillsOf(c, 'a').single as ir.SolidPaint;
      expect(s.color, _red);
      expect(s.id, 'g');
    });

    testWidgets('→ image keeps nothing but the id', (tester) async {
      final c = await pumpPaints(tester, _doc(), select: {'a'});
      await tapOn(tester, find.byKey(const ValueKey('paint-swatch:p1')));
      await switchKind(tester, 'p1', 'Image', detail: true);
      final i = fillsOf(c, 'a').first as ir.ImagePaint;
      expect(i.id, 'p1');
      expect(i.assetId, '');
      expect(find.byKey(const ValueKey('image-empty:p1')), findsOneWidget);
    });

    testWidgets('image is not offered when allowImage is false', (
      tester,
    ) async {
      // The stroke stack does not offer images.
      final doc = inspectorDoc([
        rect(
          's',
          appearance: const ir.Appearance(
            strokes: ir.Stroke(
              paints: [
                ir.Paint.gradient(
                  id: 'k',
                  stops: [
                    ir.ColorStop(position: 0, color: _red),
                    ir.ColorStop(position: 1, color: _blue),
                  ],
                ),
              ],
            ),
          ),
        ),
      ]);
      await pumpPaints(tester, doc, select: {'s'});
      final dd = tester.widget<SsDropdown<Object?>>(
        find.byKey(const ValueKey('paint-kind:k')),
      );
      expect(dd.items.map((i) => i.label), isNot(contains('Image')));
    });
  });

  group('multi-selection', () {
    testWidgets('identical stacks edit normally', (tester) async {
      final c = await pumpPaints(tester, _doc(), select: {'a', 'b'});
      expect(find.byKey(const ValueKey('paint-stack-mixed')), findsNothing);
      await tapOn(tester, find.byKey(const ValueKey('paint-visible:p2')));
      expect(fillsOf(c, 'a').last.visible, isFalse);
      expect(fillsOf(c, 'b').last.visible, isFalse);
    });

    testWidgets('different stacks show one Mixed row; Replace writes one', (
      tester,
    ) async {
      final c = await pumpPaints(
        tester,
        _doc(
          otherFills: const [ir.Paint.solid(id: 'q', color: _blue)],
        ),
        select: {'a', 'b'},
      );
      expect(find.byKey(const ValueKey('paint-stack-mixed')), findsOneWidget);
      expect(find.byKey(const ValueKey('paint-row:p1')), findsNothing);
      await tapOn(tester, find.byKey(const ValueKey('paint-stack-replace')));
      expect(fillsOf(c, 'a').length, 1);
      expect(fillsOf(c, 'a'), fillsOf(c, 'b'));
      expect(find.byKey(const ValueKey('paint-stack-mixed')), findsNothing);
    });
  });

  testWidgets('scrubbing opacity is a single undo step', (tester) async {
    final c = await pumpPaints(tester, _doc(), select: {'a'});
    final f = tester.widget<SsNumberField>(
      find.byKey(const ValueKey('field:fills.p1.opacity')),
    );
    f.onChangeStart!();
    for (var v = 90.0; v >= 50; v -= 10) {
      tester
          .widget<SsNumberField>(
            find.byKey(const ValueKey('field:fills.p1.opacity')),
          )
          .onChanged!(v);
      await tester.pump();
    }
    f.onChangeEnd!();
    expect(fillsOf(c, 'a').first.opacity, closeTo(0.5, 1e-9));
    final ctl = c.read(editorControllerProvider.notifier);
    expect(ctl.history.undoDepth, 1);
    ctl.undo();
    expect(fillsOf(c, 'a').first.opacity, 1);
  });

  for (final width in [288.0, 240.0]) {
    testWidgets('rows and the solid editor fit at $width px', (tester) async {
      await pumpPaints(tester, _doc(), select: {'a'}, width: width);
      await tester.tap(find.byKey(const ValueKey('paint-swatch:p1')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('paint-detail:p1')), findsOneWidget);
    });
  }
}
