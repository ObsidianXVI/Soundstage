import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../inspector/inspector_harness.dart';

// "Add preset…" in the Motion section (m2.md "Motion presets"): the dialog
// asks for the preset, direction, clock and range, amount and easing, and
// the result is ordinary tracks in one undo step.

Finder _key(String k) => find.byKey(ValueKey<String>(k));

ir.StageDocument _doc() {
  final d = inspectorDoc([rect('r1', x: 10, y: 20), rect('r2')]);
  final s = d.scenes.single;
  return d.copyWith(
    scenes: [
      s.copyWith(
        clocks: [
          ...s.clocks,
          const ir.Clock.timeline(id: 'tl', duration: 5),
        ],
      ),
    ],
  );
}

List<ir.Track> _tracks(ProviderContainer c) =>
    c.read(editorControllerProvider).document.scenes.single.tracks;

List<double> _values(ir.Track t) => [
  for (final k in t.keyframes) (k.value as ir.NumberValue).value,
];

Future<ProviderContainer> _open(
  WidgetTester tester, {
  Set<String> select = const {'r1'},
}) async {
  final c = await pumpInspector(tester, _doc(), select: select, height: 1000);
  await tester.tap(_key('motion-add-preset'));
  await tester.pumpAndSettle();
  expect(_key('motion-preset-dialog'), findsOneWidget);
  return c;
}

Future<void> _pick(WidgetTester tester, String dropdown, String label) async {
  await tester.tap(_key(dropdown));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String text) async {
  final f = find.descendant(of: _key(key), matching: find.byType(EditableText));
  await tester.tap(f);
  await tester.pump();
  await tester.enterText(f, text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

void main() {
  testWidgets('defaults: fade in over the first 30 % of the scene, one undo', (
    tester,
  ) async {
    final c = await _open(tester);
    await tester.tap(_key('preset-apply'));
    await tester.pumpAndSettle();
    final t = _tracks(c).single;
    expect((t.target, t.property, t.clockId), ('r1', 'opacity', 'clk1'));
    expect([for (final k in t.keyframes) k.t], [0, 0.3]);
    expect(_values(t), [0, 1]);
    final st = c.read(editorControllerProvider);
    expect(st.history.undoLabel, 'Add fade preset');
    c.read(editorControllerProvider.notifier).undo();
    expect(_tracks(c), isEmpty);
  });

  testWidgets('rise, Out, with a distance, over a chosen range', (
    tester,
  ) async {
    final c = await _open(tester);
    await _pick(tester, 'preset-kind', 'Rise');
    expect(_key('preset-amount'), findsOneWidget);
    await tester.tap(find.text('Out'));
    await tester.pump();
    expect(_key('preset-out-start'), findsOneWidget);
    expect(_key('preset-in-start'), findsNothing);
    await _type(tester, 'preset-amount', '60');
    await _type(tester, 'preset-out-start', '50');
    await tester.tap(_key('preset-apply'));
    await tester.pumpAndSettle();
    final t = _tracks(c).single;
    expect(t.property, 'motion.translateY');
    expect([for (final k in t.keyframes) k.t], [0.5, 1]);
    expect(_values(t), [0, 60]);
    // Out defaults to ease-in.
    expect(
      t.keyframes.first.easing,
      const ir.Easing.preset(ir.EasingPreset.easeIn),
    );
  });

  testWidgets('a timeline clock uses seconds and 0.6 s ranges', (tester) async {
    final c = await _open(tester);
    await _pick(tester, 'preset-clock', 'Timeline · 5 s');
    await tester.tap(find.text('In-out'));
    await tester.pump();
    expect(find.text('s'), findsWidgets);
    await tester.tap(_key('preset-apply'));
    await tester.pumpAndSettle();
    final t = _tracks(c).single;
    expect(t.clockId, 'tl');
    expect([for (final k in t.keyframes) k.t], [0, 0.6, 4.4, 5]);
    expect(_values(t), [0, 1, 1, 0]);
    // The timeline shows the clock the preset wrote to.
    expect(c.read(editorControllerProvider).activeClockId, 'tl');
  });

  testWidgets('parallax has no direction and runs on the scroll clock', (
    tester,
  ) async {
    final c = await _open(tester);
    await _pick(tester, 'preset-clock', 'Timeline · 5 s');
    await _pick(tester, 'preset-kind', 'Parallax');
    expect(_key('preset-direction'), findsNothing);
    expect(find.text('Range'), findsOneWidget);
    await tester.tap(_key('preset-apply'));
    await tester.pumpAndSettle();
    final t = _tracks(c).single;
    expect(t.clockId, 'clk1');
    expect(t.property, 'motion.translateY');
    expect([for (final k in t.keyframes) k.t], [0, 1]);
    expect(_values(t), [-80, 80]);
  });

  testWidgets('an unusable range is explained and cannot be applied', (
    tester,
  ) async {
    await _open(tester);
    await _type(tester, 'preset-in-end', '0');
    expect(_key('preset-error'), findsOneWidget);
    expect(find.text('The In range must end after it starts.'), findsOneWidget);
    await tester.tap(_key('preset-apply'));
    await tester.pumpAndSettle();
    expect(_key('motion-preset-dialog'), findsOneWidget);
  });

  testWidgets('every selected node gets the preset in one step; Cancel adds '
      'nothing', (tester) async {
    final c = await _open(tester, select: {'r1', 'r2'});
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(_tracks(c), isEmpty);
    expect(_key('motion-preset-dialog'), findsNothing);

    await tester.tap(_key('motion-add-preset'));
    await tester.pumpAndSettle();
    await _pick(tester, 'preset-kind', 'Scale');
    await tester.tap(_key('preset-apply'));
    await tester.pumpAndSettle();
    // scaleX and scaleY for both nodes.
    expect(_tracks(c), hasLength(4));
    expect({for (final t in _tracks(c)) t.target}, {'r1', 'r2'});
    c.read(editorControllerProvider.notifier).undo();
    expect(_tracks(c), isEmpty);
  });

  testWidgets('This breakpoint writes breakpoint-specific tracks', (
    tester,
  ) async {
    final c = await pumpInspector(tester, _doc(), select: {'r1'}, height: 1000);
    c
        .read(editorControllerProvider.notifier)
        .setEditScope(EditScope.thisBreakpoint);
    await tester.pump();
    await tester.tap(_key('motion-add-preset'));
    await tester.pumpAndSettle();
    await tester.tap(_key('preset-apply'));
    await tester.pumpAndSettle();
    expect(_tracks(c).single.breakpoints, ['desktop']);
  });
}
