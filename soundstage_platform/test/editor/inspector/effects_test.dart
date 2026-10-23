import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

const ir.DropShadow _drop = ir.DropShadow(id: 'e1');
const _blur = ir.Effect.layerBlur(id: 'e2', radius: 6);
const _inner = ir.Effect.innerShadow(id: 'e3');

ir.StageDocument _doc() =>
    inspectorDoc([
      rect('a', appearance: const ir.Appearance(effects: [_drop, _blur])),
      rect('b', appearance: const ir.Appearance(effects: [_drop, _blur])),
      rect('c', appearance: const ir.Appearance(effects: [_inner])),
      rect('empty'),
      rect(
        'm',
        appearance: const ir.Appearance(effects: [_drop]),
        patches: const {
          'mobile': {'effects.e1.blur': ir.IrValue.number(20)},
        },
      ),
      rect(
        'styled',
        appearance: const ir.Appearance(effectStyleId: 'es', effects: [_inner]),
      ),
    ]).copyWith(
      tokens: const ir.TokenSystem(
        effectStyles: {
          'es': ir.EffectStyleDef(
            name: 'Soft glow',
            effects: [ir.Effect.layerBlur(id: 'g1', radius: 9)],
          ),
        },
      ),
    );

List<ir.Effect> _effects(ProviderContainer c, String id) =>
    (nodeOf(c, id) as ir.ShapeNode).appearance.effects;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Set<String> select = const {'a'},
  double width = 288,
}) => pumpInspector(tester, _doc(), width: width, height: 1800, select: select);

Future<void> _expand(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('effect-title:$id')));
  await tester.pumpAndSettle();
}

Future<void> _add(WidgetTester tester, String label) async {
  await tester.tap(find.byKey(const ValueKey('add-effect')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(SsMenu), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

Future<void> _rowMenu(WidgetTester tester, String id, String label) async {
  await tester.tap(find.byKey(ValueKey('effect-menu:$id')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.descendant(of: find.byType(SsMenu), matching: find.text(label)),
  );
  await tester.pumpAndSettle();
}

SsNumberField _num(WidgetTester t, String path) =>
    t.widget<SsNumberField>(find.byKey(ValueKey<String>('field:$path')));

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
  group('Effects stack', () {
    testWidgets('lists the top of the stack first', (tester) async {
      await _pump(tester);
      final top = tester.getTopLeft(find.byKey(const ValueKey('effect:e2'))).dy;
      final bottom = tester
          .getTopLeft(find.byKey(const ValueKey('effect:e1')))
          .dy;
      expect(top < bottom, isTrue);
      expect(find.text('Layer blur'), findsOneWidget);
      expect(find.text('Drop shadow'), findsOneWidget);
    });

    testWidgets('adds each kind on top with a fresh deterministic id', (
      tester,
    ) async {
      final c = await _pump(tester, select: {'empty'});
      await _add(tester, 'Drop shadow');
      await _add(tester, 'Inner shadow');
      await _add(tester, 'Layer blur');
      await _add(tester, 'Background blur');
      final list = _effects(c, 'empty');
      expect(list.map((e) => e.runtimeType.toString()).toList(), [
        'DropShadow',
        'InnerShadow',
        'LayerBlur',
        'BackgroundBlur',
      ]);
      expect(list.map((e) => e.id).toSet().length, 4);
      expect(list.first, ir.Effect.dropShadow(id: list.first.id));
      expect(list.last, ir.Effect.backgroundBlur(id: list.last.id));
    });

    testWidgets('an add is one undo step and applies to every node', (
      tester,
    ) async {
      final c = await _pump(tester, select: {'a', 'empty'});
      final before = c.read(editorControllerProvider).document;
      await _add(tester, 'Layer blur');
      expect(_effects(c, 'a').length, 3);
      expect(_effects(c, 'empty').length, 1);
      expect(c.read(editorControllerProvider.notifier).undo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
    });

    testWidgets('removes an effect and undoes', (tester) async {
      final c = await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('effect-remove:e2')));
      await tester.pumpAndSettle();
      expect(_effects(c, 'a'), [_drop]);
      c.read(editorControllerProvider.notifier).undo();
      expect(_effects(c, 'a'), [_drop, _blur]);
    });

    testWidgets('reorders with the row menu; edges are disabled', (
      tester,
    ) async {
      final c = await _pump(tester);
      await _rowMenu(tester, 'e1', 'Move up');
      expect(_effects(c, 'a'), [_blur, _drop]);
      await _rowMenu(tester, 'e1', 'Move down');
      expect(_effects(c, 'a'), [_drop, _blur]);
      // e2 is on top: Move up does nothing.
      await _rowMenu(tester, 'e2', 'Move up');
      expect(_effects(c, 'a'), [_drop, _blur]);
    });

    testWidgets('duplicates above the original with a new id', (tester) async {
      final c = await _pump(tester);
      await _rowMenu(tester, 'e1', 'Duplicate');
      final list = _effects(c, 'a');
      expect(list.length, 3);
      expect(list[0], _drop);
      expect(list[1].id, isNot('e1'));
      expect(list[1], _drop.copyWith(id: list[1].id));
      expect(list[2], _blur);
    });

    testWidgets('the eye toggles visibility through the per-id path', (
      tester,
    ) async {
      final c = await _pump(tester);
      await tester.tap(find.byKey(const ValueKey('effect-visible:e1')));
      await tester.pump();
      expect(
        valueAt(c, 'a', 'effects.e1.visible', 'desktop'),
        const ir.IrValue.boolean(false),
      );
      expect(_effects(c, 'a').first.visible, isFalse);
      await tester.tap(find.byKey(const ValueKey('effect-visible:e1')));
      await tester.pump();
      expect(_effects(c, 'a').first.visible, isTrue);
    });

    testWidgets('Mixed stacks show one row; Replace copies the first', (
      tester,
    ) async {
      final c = await _pump(tester, select: {'a', 'c'});
      expect(find.byKey(const ValueKey('effects-mixed')), findsOneWidget);
      expect(find.byKey(const ValueKey('effect:e1')), findsNothing);
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();
      expect(_effects(c, 'a'), [_drop, _blur]);
      expect(_effects(c, 'c'), [_drop, _blur]);
      expect(find.byKey(const ValueKey('effects-mixed')), findsNothing);
    });

    testWidgets('equal stacks across nodes are not Mixed', (tester) async {
      await _pump(tester, select: {'a', 'b'});
      expect(find.byKey(const ValueKey('effects-mixed')), findsNothing);
      expect(find.byKey(const ValueKey('effect:e1')), findsOneWidget);
    });
  });

  group('Effect fields', () {
    testWidgets('drop shadow fields write per-id paths', (tester) async {
      final c = await _pump(tester);
      await _expand(tester, 'e1');
      await typeInto(tester, 'effects.e1.blur', '12');
      await typeInto(tester, 'effects.e1.spread', '3');
      await typeInto(tester, 'effects.e1.offset.x', '5');
      await typeInto(tester, 'effects.e1.offset.y', '7');
      final d = _effects(c, 'a').first as ir.DropShadow;
      expect(d.blur, 12);
      expect(d.spread, 3);
      expect(d.offset, const ir.StagePoint(x: 5, y: 7));
      expect(
        valueAt(c, 'a', 'effects.e1.blur', 'desktop'),
        const ir.IrValue.number(12),
      );
      // The blur effect is untouched.
      expect(_effects(c, 'a').last, _blur);
    });

    testWidgets('show-behind is for drop shadows only', (tester) async {
      final c = await _pump(tester, select: {'c'});
      await _expand(tester, 'e3');
      expect(find.text('Show behind transparent areas'), findsNothing);
      c.read(editorControllerProvider.notifier).select({'a'});
      await tester.pumpAndSettle();
      await _expand(tester, 'e1');
      await tester.tap(find.text('Show behind transparent areas'));
      await tester.pump();
      expect(
        (_effects(c, 'a').first as ir.DropShadow).showBehindTransparentAreas,
        isTrue,
      );
    });

    testWidgets('blend mode dropdown writes the effect blend mode', (
      tester,
    ) async {
      final c = await _pump(tester);
      await _expand(tester, 'e1');
      await tester.tap(
        find.byKey(const ValueKey('field:effects.e1.blendMode')),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(SsMenu),
          matching: find.text('Pass through'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SsMenu),
          matching: find.text('Multiply'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        (_effects(c, 'a').first as ir.DropShadow).blendMode,
        ir.BlendMode.multiply,
      );
    });

    testWidgets('blur effects have a single radius', (tester) async {
      final c = await _pump(tester);
      await _expand(tester, 'e2');
      expect(
        find.byKey(const ValueKey('field:effects.e2.offset.x')),
        findsNothing,
      );
      await typeInto(tester, 'effects.e2.radius', '15');
      expect((_effects(c, 'a').last as ir.LayerBlur).radius, 15);
    });

    testWidgets('reads the breakpoint patch; scope routes writes', (
      tester,
    ) async {
      final c = await _pump(tester, select: {'m'});
      await _expand(tester, 'e1');
      expect(_num(tester, 'effects.e1.blur').value, 4);
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.setEditingBreakpoint('mobile');
      await tester.pump();
      expect(_num(tester, 'effects.e1.blur').value, 20);
      ctl.setEditScope(EditScope.thisBreakpoint);
      await typeInto(tester, 'effects.e1.blur', '30');
      expect(
        valueAt(c, 'm', 'effects.e1.blur', 'mobile'),
        const ir.IrValue.number(30),
      );
      expect(
        valueAt(c, 'm', 'effects.e1.blur', 'desktop'),
        const ir.IrValue.number(4),
      );
    });

    testWidgets('fields are Mixed across nodes and edits apply to all', (
      tester,
    ) async {
      final doc = inspectorDoc([
        rect('p', appearance: const ir.Appearance(effects: [_drop])),
        rect(
          'q',
          appearance: ir.Appearance(
            effects: [
              _drop.copyWith(blur: 9, offset: const ir.StagePoint(x: 2, y: 4)),
            ],
          ),
        ),
      ]);
      final c = await pumpInspector(
        tester,
        doc,
        height: 1800,
        select: {'p', 'q'},
      );
      await _expand(tester, 'e1');
      expect(_num(tester, 'effects.e1.blur').mixed, isTrue);
      expect(_num(tester, 'effects.e1.offset.x').mixed, isTrue);
      await typeInto(tester, 'effects.e1.offset.x', '10');
      expect(
        (_effects(c, 'p').first as ir.DropShadow).offset,
        const ir.StagePoint(x: 10, y: 4),
      );
      expect(
        (_effects(c, 'q').first as ir.DropShadow).offset,
        const ir.StagePoint(x: 10, y: 4),
      );
    });

    testWidgets('a blur scrub is one undo step', (tester) async {
      final c = await _pump(tester);
      await _expand(tester, 'e1');
      final before = c.read(editorControllerProvider).document;
      final blurLabel = find.descendant(
        of: find.byKey(const ValueKey('field:effects.e1.blur')),
        matching: find.text('Blur'),
      );
      final g = await tester.startGesture(tester.getCenter(blurLabel));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      expect((_effects(c, 'a').first as ir.DropShadow).blur, isNot(4));
      final ctl = c.read(editorControllerProvider.notifier);
      expect(ctl.undo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
      expect(ctl.history.canUndo, isFalse);
    });
  });

  group('Effect style', () {
    testWidgets('banner names the style; Detach copies the stack', (
      tester,
    ) async {
      final c = await _pump(tester, select: {'styled'});
      expect(find.text('Style: Soft glow'), findsOneWidget);
      // The style's stack is what shows.
      expect(find.text('Layer blur'), findsOneWidget);
      await tester.tap(find.text('Detach'));
      await tester.pumpAndSettle();
      final n = nodeOf(c, 'styled') as ir.ShapeNode;
      expect(n.appearance.effectStyleId, isNull);
      expect(n.appearance.effects.single.id, 'g1');
      expect(find.text('Style: Soft glow'), findsNothing);
      c.read(editorControllerProvider.notifier).undo();
      expect(
        (nodeOf(c, 'styled') as ir.ShapeNode).appearance.effectStyleId,
        'es',
      );
    });
  });

  testWidgets('fits 240 px wide with every effect expanded', (tester) async {
    final errors = <String>[];
    final prev = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.toString());
    addTearDown(() => FlutterError.onError = prev);
    final c = await _pump(tester, width: 240);
    await _expand(tester, 'e1');
    await _expand(tester, 'e2');
    c.read(editorControllerProvider.notifier).select({'c'});
    await tester.pumpAndSettle();
    await _expand(tester, 'e3');
    expect(errors.where(_mine), isEmpty);
  });
}
