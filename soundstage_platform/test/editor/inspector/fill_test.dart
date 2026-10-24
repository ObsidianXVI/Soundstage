import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';
import 'paint_test_utils.dart';

const _red = ir.StageColor(r: 1, g: 0, b: 0);
const _blue = ir.StageColor(r: 0, g: 0, b: 1);
const _green = ir.StageColor(r: 0, g: 1, b: 0);

ir.StageDocument _styled() =>
    inspectorDoc([
      rect(
        'a',
        appearance: const ir.Appearance(
          fills: [ir.Paint.solid(id: 'local', color: _red)],
          fillStyleId: 'st1',
        ),
      ),
    ]).copyWith(
      tokens: const ir.TokenSystem(
        paintStyles: {
          'st1': ir.PaintStyleDef(
            name: 'Brand/Primary',
            paints: [ir.Paint.solid(id: 's1', color: _blue)],
          ),
        },
      ),
    );

void main() {
  testWidgets('Fill shows for frames and shapes, not text', (tester) async {
    final doc = inspectorDoc([
      box('f'),
      rect('r'),
      const ir.Node.text(
        common: ir.NodeCommon(id: 't', width: 100, height: 20),
      ),
    ]);
    final c = await pumpPaints(tester, doc, select: {'f'});
    expect(find.byKey(const ValueKey('section:fill')), findsOneWidget);
    expect(find.text('Fill'), findsOneWidget);
    expect(find.byKey(const ValueKey('add-paint:fills')), findsOneWidget);
    c.read(editorControllerProvider.notifier).select({'r'});
    await tester.pump();
    expect(find.byKey(const ValueKey('section:fill')), findsOneWidget);
    c.read(editorControllerProvider.notifier).select({'t'});
    await tester.pump();
    expect(find.byKey(const ValueKey('section:fill')), findsNothing);
  });

  testWidgets('adding to an empty frame creates its first fill', (
    tester,
  ) async {
    final c = await pumpPaints(tester, inspectorDoc([box('f')]), select: {'f'});
    await tapKey(tester, 'add-paint:fills');
    expect(fillsOf(c, 'f').single, isA<ir.SolidPaint>());
    expect(find.byType(EditableText), findsWidgets);
  });

  testWidgets('a paint style shows a banner and its paints, read-only', (
    tester,
  ) async {
    await pumpPaints(tester, _styled(), select: {'a'});
    expect(find.byKey(const ValueKey('fill-style')), findsOneWidget);
    expect(find.text('Style: Brand/Primary'), findsOneWidget);
    // The style's paint is shown, not the (ignored) local one.
    expect(find.byKey(const ValueKey('paint-row:s1')), findsOneWidget);
    expect(find.byKey(const ValueKey('paint-row:local')), findsNothing);
    final ignore = find.ancestor(
      of: find.byKey(const ValueKey('paint-row:s1')),
      matching: find.byType(IgnorePointer),
    );
    expect(
      tester.widgetList<IgnorePointer>(ignore).any((w) => w.ignoring),
      isTrue,
    );
    final add = tester.widget<SsIconButton>(
      find.byKey(const ValueKey('add-paint:fills')),
    );
    expect(add.onPressed, isNull);
  });

  testWidgets('Detach keeps the style paints locally, in one undo step', (
    tester,
  ) async {
    final c = await pumpPaints(tester, _styled(), select: {'a'});
    await tapOn(tester, find.text('Detach'));
    final a = (nodeOf(c, 'a') as ir.ShapeNode).appearance;
    expect(a.fillStyleId, isNull);
    expect(a.fills, const [ir.Paint.solid(id: 's1', color: _blue)]);
    expect(find.byKey(const ValueKey('fill-style')), findsNothing);
    expect(c.read(editorControllerProvider.notifier).history.undoDepth, 1);
  });

  testWidgets('dragging a row by its handle reorders the stack', (
    tester,
  ) async {
    final doc = inspectorDoc([
      rect(
        'a',
        appearance: const ir.Appearance(
          fills: [
            ir.Paint.solid(id: 'p1', color: _red),
            ir.Paint.solid(id: 'p2', color: _blue),
            ir.Paint.solid(id: 'p3', color: _green),
          ],
        ),
      ),
    ]);
    final c = await pumpPaints(tester, doc, select: {'a'});
    // Shown top first: p3, p2, p1. Drag p3 below p1.
    final handle = find.byKey(const ValueKey('paint-menu:p3'));
    // A mouse drag: the inspector does not scroll on mouse drags, the
    // handle takes it.
    final g = await tester.startGesture(
      tester.getCenter(handle),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    // The drop animates before the list reports the move.
    await tester.pumpAndSettle();
    expect([for (final p in fillsOf(c, 'a')) p.id], ['p3', 'p1', 'p2']);
    expect(c.read(editorControllerProvider.notifier).history.undoDepth, 1);
  });
}
