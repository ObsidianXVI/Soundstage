import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/sections/layout_child_section.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

const _h = 'layoutChild.horizontalSizing';
const _v = 'layoutChild.verticalSizing';

ir.StageDocument _doc() => inspectorDoc([
  box(
    'row',
    autoLayout: const ir.AutoLayout(),
    children: [
      rect(
        'a',
        w: 100,
        h: 40,
        patches: const {
          'mobile': {_h: ir.IrValue.enumValue('fill')},
        },
      ),
      rect(
        'b',
        w: 120,
        h: 60,
        layoutChild: const ir.LayoutChild(horizontalSizing: ir.Sizing.fill),
      ),
      rect(
        'abs',
        layoutChild: const ir.LayoutChild(positioning: ir.Positioning.absolute),
      ),
    ],
  ),
  box(
    'free',
    x: 400,
    children: [
      box(
        'nested',
        autoLayout: const ir.AutoLayout(),
        layoutChild: const ir.LayoutChild(
          horizontalSizing: ir.Sizing.hug,
          verticalSizing: ir.Sizing.hug,
        ),
      ),
    ],
  ),
]);

SsSegmented<String> _seg(WidgetTester tester, String path) =>
    tester.widget(find.byKey(ValueKey<String>('field:$path')));

Map<String, bool> _enabled(WidgetTester tester, String path) => {
  for (final s in _seg(tester, path).segments) s.value: s.enabled,
};

ir.LayoutChild _lc(ProviderContainer c, String id) =>
    nodeOf(c, id).common.layoutChild;

Future<void> _pump(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 400));

void main() {
  const tall = 1800.0;

  group('validSizings', () {
    Set<ir.Sizing> v(
      ir.NodeKind kind, {
      bool auto = false,
      bool parentAuto = false,
      bool inFlow = true,
      bool root = false,
      Axis axis = Axis.horizontal,
    }) => validSizings(
      kind: kind,
      hasAutoLayout: auto,
      parentHasAutoLayout: parentAuto,
      inFlow: inFlow,
      isRoot: root,
      axis: axis,
    );

    const fixed = ir.Sizing.fixed, hug = ir.Sizing.hug, fill = ir.Sizing.fill;

    test('roots have none', () {
      expect(v(ir.NodeKind.frame, auto: true, root: true), isEmpty);
    });

    test('a flow root with auto layout: Fixed or Hug in height only', () {
      Set<ir.Sizing> flow(Axis axis, {bool auto = true}) => validSizings(
        kind: ir.NodeKind.frame,
        hasAutoLayout: auto,
        parentHasAutoLayout: false,
        inFlow: true,
        isRoot: true,
        isFlowRoot: true,
        axis: axis,
      );
      expect(flow(Axis.vertical), {fixed, hug});
      expect(flow(Axis.horizontal), isEmpty);
      expect(flow(Axis.vertical, auto: false), isEmpty);
    });

    test('hug: auto-layout frames and text only', () {
      expect(v(ir.NodeKind.frame, auto: true), {fixed, hug});
      expect(v(ir.NodeKind.text), {fixed, hug});
      for (final k in [
        ir.NodeKind.frame,
        ir.NodeKind.shape,
        ir.NodeKind.video,
        ir.NodeKind.instance,
        ir.NodeKind.embed,
      ]) {
        expect(v(k), {fixed}, reason: '$k');
      }
    });

    test('fill: in-flow children of auto layout, any kind, both axes', () {
      for (final k in ir.NodeKind.values) {
        for (final axis in Axis.values) {
          expect(
            v(k, parentAuto: true, axis: axis).contains(fill),
            isTrue,
            reason: '$k $axis',
          );
        }
      }
      expect(v(ir.NodeKind.shape, parentAuto: true, inFlow: false), {fixed});
      expect(v(ir.NodeKind.shape, inFlow: true), {fixed});
      expect(v(ir.NodeKind.frame, auto: true, parentAuto: true), {
        fixed,
        hug,
        fill,
      });
    });
  });

  group('layout child: sizing', () {
    testWidgets('reads the sizing at each breakpoint', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'a'},
        height: tall,
      );
      expect(
        find.byKey(const ValueKey('section:layout_child')),
        findsOneWidget,
      );
      expect(_seg(tester, _h).selected, 'fixed');
      c.read(editorControllerProvider.notifier).setEditingBreakpoint('mobile');
      await tester.pump();
      expect(_seg(tester, _h).selected, 'fill');
    });

    testWidgets('a shape in auto layout offers Fixed and Fill, not Hug', (
      tester,
    ) async {
      await pumpInspector(tester, _doc(), select: {'a'}, height: tall);
      expect(_enabled(tester, _h), {'fixed': true, 'hug': false, 'fill': true});
      expect(_enabled(tester, _v), {'fixed': true, 'hug': false, 'fill': true});
      final hug = _seg(tester, _h).segments.firstWhere((s) => s.value == 'hug');
      expect(hug.semanticLabel, contains('auto-layout frames and text'));
    });

    testWidgets('Fill is disabled for a child of a non-auto-layout parent', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'nested'},
        height: tall,
      );
      expect(_enabled(tester, _h), {'fixed': true, 'hug': true, 'fill': false});
      final fill = _seg(
        tester,
        _h,
      ).segments.firstWhere((s) => s.value == 'fill');
      expect(fill.semanticLabel, contains('auto-layout parent'));
      // Tapping the disabled segment writes nothing.
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('field:$_h')),
          matching: find.text('Fill'),
        ),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(_lc(c, 'nested').horizontalSizing, ir.Sizing.hug);
    });

    testWidgets('writes, routed by scope', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'a'},
        height: tall,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('field:$_v')),
          matching: find.text('Fill'),
        ),
      );
      await tester.pump();
      expect(_lc(c, 'a').verticalSizing, ir.Sizing.fill);
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.setEditScope(EditScope.thisBreakpoint);
      ctl.setEditingBreakpoint('mobile');
      await tester.pump();
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('field:$_v')),
          matching: find.text('Fixed'),
        ),
      );
      await tester.pump();
      expect(
        valueAt(c, 'a', _v, 'mobile'),
        const ir.IrValue.enumValue('fixed'),
      );
      expect(
        valueAt(c, 'a', _v, 'desktop'),
        const ir.IrValue.enumValue('fill'),
      );
    });

    testWidgets('two children that disagree read Mixed', (tester) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'a', 'b'},
        height: tall,
      );
      expect(_seg(tester, _h).selected, isNull);
      expect(_seg(tester, _v).selected, 'fixed');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('field:$_h')),
          matching: find.text('Fixed'),
        ),
      );
      await tester.pump();
      expect(_lc(c, 'a').horizontalSizing, ir.Sizing.fixed);
      expect(_lc(c, 'b').horizontalSizing, ir.Sizing.fixed);
    });

    testWidgets('options intersect over the selection', (tester) async {
      await pumpInspector(
        tester,
        _doc(),
        select: {'a', 'nested'},
        height: tall,
      );
      // 'a' cannot hug; 'nested' cannot fill.
      expect(_enabled(tester, _h), {
        'fixed': true,
        'hug': false,
        'fill': false,
      });
    });

    testWidgets('hidden for scene roots and free-parent shapes', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'root'},
        height: tall,
      );
      expect(find.byKey(const ValueKey('section:layout_child')), findsNothing);
      c.read(editorControllerProvider.notifier).select({'abs'});
      await tester.pump();
      expect(find.byKey(const ValueKey('section:layout_child')), findsNothing);
    });
  });

  group('layout child: min / max', () {
    testWidgets('added from the menu at the current size, then removed', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'a'},
        height: tall,
      );
      expect(fieldText('layoutChild.minWidth'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('min-max:add')));
      await _pump(tester);
      expect(find.text('Max height'), findsOneWidget);
      await tester.tap(find.text('Min width'));
      await _pump(tester);
      expect(_lc(c, 'a').minWidth, 100);
      expect(fieldText('layoutChild.minWidth'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('min-max:add')));
      await _pump(tester);
      expect(find.text('Min width'), findsNothing, reason: 'already set');
      await tester.tap(find.text('Max height'));
      await _pump(tester);
      expect(_lc(c, 'a').maxHeight, 40);

      await typeInto(tester, 'layoutChild.minWidth', '80');
      expect(_lc(c, 'a').minWidth, 80);

      await tester.tap(find.bySemanticsLabel('Remove Min width'));
      await tester.pump();
      expect(_lc(c, 'a').minWidth, isNull);
      expect(fieldText('layoutChild.minWidth'), findsNothing);
      expect(_lc(c, 'a').maxHeight, 40);
    });

    testWidgets('each node starts from its own size; one undo step', (
      tester,
    ) async {
      final c = await pumpInspector(
        tester,
        _doc(),
        select: {'a', 'b'},
        height: tall,
      );
      await tester.tap(find.byKey(const ValueKey('min-max:add')));
      await _pump(tester);
      await tester.tap(find.text('Max width'));
      await _pump(tester);
      expect(_lc(c, 'a').maxWidth, 100);
      expect(_lc(c, 'b').maxWidth, 120);
      final ws = tester.widget<SsNumberField>(
        find.byKey(const ValueKey('field:layoutChild.maxWidth')),
      );
      expect(ws.mixed, isTrue);
      c.read(editorControllerProvider.notifier).undo();
      expect(_lc(c, 'a').maxWidth, isNull);
      expect(_lc(c, 'b').maxWidth, isNull);
    });

    testWidgets('a min-width scrub is one undo step', (tester) async {
      final doc = inspectorDoc([
        box(
          'row',
          autoLayout: const ir.AutoLayout(),
          children: [
            rect('a', layoutChild: const ir.LayoutChild(minWidth: 50)),
          ],
        ),
      ]);
      final c = await pumpInspector(tester, doc, select: {'a'}, height: tall);
      final before = c.read(editorControllerProvider).document;
      final label = find.descendant(
        of: find.byKey(const ValueKey('field:layoutChild.minWidth')),
        matching: find.text('Min W'),
      );
      final g = await tester.startGesture(tester.getCenter(label));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(4, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pump();
      expect(_lc(c, 'a').minWidth, isNot(50));
      final ctl = c.read(editorControllerProvider.notifier);
      expect(ctl.undo(), isTrue);
      expect(
        identical(c.read(editorControllerProvider).document, before),
        isTrue,
      );
      expect(ctl.history.canUndo, isFalse);
    });
  });

  group('layout child: narrow panel', () {
    for (final width in [288.0, 240.0]) {
      testWidgets('no overflow at $width px with all four limits', (
        tester,
      ) async {
        final doc = inspectorDoc([
          box(
            'row',
            autoLayout: const ir.AutoLayout(),
            children: [
              rect(
                'a',
                layoutChild: const ir.LayoutChild(
                  minWidth: 1,
                  maxWidth: 2,
                  minHeight: 3,
                  maxHeight: 4,
                ),
              ),
            ],
          ),
        ]);
        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.toString());
        addTearDown(() => FlutterError.onError = previous);
        await pumpInspector(
          tester,
          doc,
          select: {'a'},
          width: width,
          height: tall,
        );
        expect([
          for (final e in errors)
            if (e.contains('section:layout_child')) e,
        ], isEmpty);
        expect(fieldText('layoutChild.maxHeight'), findsOneWidget);
      });
    }
  });

  testWidgets('a flow scene root with auto layout can hug its height', (
    tester,
  ) async {
    final doc = inspectorDoc([rect('a')]);
    final flow = doc.copyWith(
      scenes: [
        doc.scenes.single.copyWith(
          kind: ir.SceneKind.flow,
          root: doc.scenes.single.root.copyWith(
            autoLayout: const ir.AutoLayout(
              direction: ir.LayoutDirection.vertical,
            ),
          ),
        ),
      ],
    );
    final c = await pumpInspector(tester, flow, select: {'root'}, height: tall);
    expect(find.byKey(const ValueKey('section:layout_child')), findsOneWidget);
    expect(find.byKey(const ValueKey('field:$_h')), findsNothing);
    expect(_enabled(tester, _v), {'fixed': true, 'hug': true, 'fill': false});
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('field:$_v')),
        matching: find.text('Hug'),
      ),
    );
    await tester.pump();
    expect(_lc(c, 'root').verticalSizing, ir.Sizing.hug);
  });

  testWidgets('a pinned scene root still has no Layout section', (
    tester,
  ) async {
    final doc = inspectorDoc([rect('a')]);
    await pumpInspector(
      tester,
      doc.copyWith(
        scenes: [
          doc.scenes.single.copyWith(
            root: doc.scenes.single.root.copyWith(
              autoLayout: const ir.AutoLayout(),
            ),
          ),
        ],
      ),
      select: {'root'},
      height: tall,
    );
    expect(find.byKey(const ValueKey('section:layout_child')), findsNothing);
  });
}
