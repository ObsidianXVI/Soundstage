// Scene settings live in the Inspector only (DECISIONS; m1.md T1.6): with
// nothing selected it shows the active scene's settings.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/inspector.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../panels/panels_harness.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  double height = 700,
  double width = 264,
}) => pumpPanel(
  tester,
  const Inspector(),
  doc: threeScenesDoc(),
  height: height,
  width: width,
);

ir.Scene _scene(ProviderContainer c, String id) =>
    c.doc.scenes.firstWhere((s) => s.id == id);

Finder _field(String semanticLabel) => find.descendant(
  of: find.byWidgetPredicate(
    (w) =>
        (w is SsNumberField && w.semanticLabel == semanticLabel) ||
        (w is SsColorField && w.semanticLabel == semanticLabel),
  ),
  matching: find.byType(EditableText),
);

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.tap(_field(label));
  await tester.pump();
  await tester.enterText(_field(label), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

/// Undo restores the document; redo re-applies.
void _expectUndoRedo(ProviderContainer c, ir.StageDocument before) {
  final after = c.doc;
  expect(c.ctl.undo(), isTrue);
  expect(identical(c.doc, before), isTrue);
  expect(c.ctl.redo(), isTrue);
  expect(identical(c.doc, after), isTrue);
}

void main() {
  group('settings', () {
    testWidgets('are for the active scene and follow it', (tester) async {
      final c = await _pump(tester);
      expect(find.text('Scene settings'), findsOneWidget);
      expect(_field('Scroll length'), findsOneWidget);
      c.ctl.setActiveScene('s3');
      await tester.pump();
      // A flow scene has no scroll length.
      expect(_field('Scroll length'), findsNothing);
      expect(_field('Poster clock'), findsOneWidget);
    });

    testWidgets(
      'kind switches pinned and flow; scroll length shows for pinned',
      (tester) async {
        final c = await _pump(tester);
        final before = c.doc;
        await tester.tap(
          find.descendant(
            of: find.byType(SsSegmented<ir.SceneKind>),
            matching: find.text('Flow'),
          ),
        );
        await tester.pump();
        expect(_scene(c, 's1').kind, ir.SceneKind.flow);
        expect(_field('Scroll length'), findsNothing);
        _expectUndoRedo(c, before);
        c.ctl.undo();
        await tester.pump();
        expect(_field('Scroll length'), findsOneWidget);

        // To pinned from a flow scene with no length gives it one.
        c.ctl.setActiveScene('s3');
        await tester.pump();
        await tester.tap(
          find.descendant(
            of: find.byType(SsSegmented<ir.SceneKind>),
            matching: find.text('Pinned'),
          ),
        );
        await tester.pump();
        expect(_scene(c, 's3').kind, ir.SceneKind.pinned);
        expect(_scene(c, 's3').scrollLength, 1);
        expect(_field('Scroll length'), findsOneWidget);
      },
    );

    testWidgets('scroll length edits and undoes', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _type(tester, 'Scroll length', '3');
      expect(_scene(c, 's1').scrollLength, 3);
      expect(c.st.history.undoLabel, 'Change scene settings');
      _expectUndoRedo(c, before);
      await _type(tester, 'Scroll length', '-4');
      expect(_scene(c, 's1').scrollLength, 0, reason: 'clamped at 0');
    });

    testWidgets('background sets, edits and clears a solid fill', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      expect(_scene(c, 's1').background, isEmpty);
      await _type(tester, 'Scene background', 'ff0000');
      var bg = _scene(c, 's1').background;
      expect(bg, hasLength(1));
      final paint = bg.single as ir.SolidPaint;
      expect(paint.color.toHex(), '#ff0000');
      _expectUndoRedo(c, before);

      await _type(tester, 'Scene background', '00ff00');
      bg = _scene(c, 's1').background;
      expect(bg, hasLength(1));
      expect((bg.single as ir.SolidPaint).color.toHex(), '#00ff00');
      expect(bg.single.id, paint.id, reason: 'the paint keeps its id');
      await tester.pump();
      final withBg = c.doc;
      await tester.tap(find.bySemanticsLabel('Clear background'));
      await tester.pump();
      expect(_scene(c, 's1').background, isEmpty);
      _expectUndoRedo(c, withBg);
    });

    testWidgets('export mode', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await tester.tap(
        find.descendant(
          of: find.byType(SsSegmented<ir.SceneExportMode>),
          matching: find.text('Poster'),
        ),
      );
      await tester.pump();
      expect(_scene(c, 's1').exportAs, ir.SceneExportMode.poster);
      _expectUndoRedo(c, before);
      await tester.tap(
        find.descendant(
          of: find.byType(SsSegmented<ir.SceneExportMode>),
          matching: find.text('Text'),
        ),
      );
      await tester.pump();
      expect(_scene(c, 's1').exportAs, ir.SceneExportMode.text);
      // The poster clock is moot for a text export.
      final clock = tester.widget<SsNumberField>(
        find.byWidgetPredicate(
          (w) => w is SsNumberField && w.semanticLabel == 'Poster clock',
        ),
      );
      expect(clock.enabled, isFalse);
    });

    testWidgets('poster clock edits within 0 to 1 and resets', (tester) async {
      final c = await _pump(tester);
      expect(_scene(c, 's1').posterClock, isNull);
      final before = c.doc;
      await _type(tester, 'Poster clock', '0.25');
      expect(_scene(c, 's1').posterClock, 0.25);
      _expectUndoRedo(c, before);
      await _type(tester, 'Poster clock', '7');
      expect(_scene(c, 's1').posterClock, 1);
      await tester.pump();
      final set = c.doc;
      await tester.tap(find.bySemanticsLabel('Reset poster clock'));
      await tester.pump();
      expect(_scene(c, 's1').posterClock, isNull);
      _expectUndoRedo(c, set);
    });

    testWidgets('a scrub is one undo step', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      c.ctl.beginGesture();
      for (final v in [1.5, 2.0, 2.5]) {
        c.ctl.execute(UpdateSceneSettings('s1', scrollLength: v));
      }
      c.ctl.endGesture();
      await tester.pump();
      expect(_scene(c, 's1').scrollLength, 2.5);
      c.ctl.undo();
      expect(identical(c.doc, before), isTrue);
    });
  });

  testWidgets(
    'settings scroll and nothing overflows in a short, narrow inspector',
    (tester) async {
      await _pump(tester, height: 260, width: 220);
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -200),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a later scene picks its transition; the first has none', (
    tester,
  ) async {
    final c = await _pump(tester, height: 1400);
    final first = c.doc.scenes.first.id;
    c.ctl.setActiveScene(first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scene-transition')), findsNothing);
    final second = c.doc.scenes[1].id;
    c.ctl.setActiveScene(second);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scene-transition')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Crossfade').last);
    await tester.pumpAndSettle();
    expect(
      _scene(c, second).transitionIn,
      const ir.SceneTransition(
        kind: ir.SceneTransitionKind.crossfade,
        amount: 0.5,
      ),
    );
    await _type(tester, 'Transition length in screens', '1');
    expect(_scene(c, second).transitionIn.amount, 1);
  });
}
