import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/panels/scenes_panel.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'panels_harness.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  double height = 700,
  double width = 264,
}) => pumpPanel(
  tester,
  const ScenesPanel(),
  doc: threeScenesDoc(),
  height: height,
  width: width,
);

ir.Scene _scene(ProviderContainer c, String id) =>
    c.doc.scenes.firstWhere((s) => s.id == id);

final _rowEditor = find.descendant(
  of: find.byType(SsTreeRow),
  matching: find.byType(EditableText),
);

Finder _field(String semanticLabel) => find.descendant(
  of: find.byWidgetPredicate(
    (w) =>
        (w is SsNumberField && w.semanticLabel == semanticLabel) ||
        (w is SsColorField && w.semanticLabel == semanticLabel),
  ),
  matching: find.byType(EditableText),
);

Future<void> _openMenu(WidgetTester tester, String row) async {
  final g = await tester.startGesture(
    tester.getCenter(rowOf(row)),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await g.up();
  await tester.pump();
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
  testWidgets('lists scenes in order; the active one is highlighted', (
    tester,
  ) async {
    final c = await _pump(tester);
    expect(find.text('3 scenes'), findsOneWidget);
    final ys = [
      for (final n in ['One', 'Two', 'Three']) tester.getTopLeft(rowOf(n)).dy,
    ];
    expect(ys[0] < ys[1] && ys[1] < ys[2], isTrue);
    expect(rowWidget(tester, 'One').selected, isTrue);
    expect(rowWidget(tester, 'Two').selected, isFalse);
    Finder tag(String t) =>
        find.descendant(of: find.byType(SsTreeRow), matching: find.text(t));
    expect(tag('Pinned'), findsOneWidget);
    expect(tag('Flow'), findsNWidgets(2));
    // Selection in the old scene is cleared when another becomes active.
    c.ctl.select({'A'});
    await tester.tap(find.text('Two'));
    await tester.pump();
    expect(c.st.activeSceneId, 's2');
    expect(c.st.selection, isEmpty);
    expect(rowWidget(tester, 'Two').selected, isTrue);
    expect(rowWidget(tester, 'One').selected, isFalse);
    // An outside change shows too.
    c.ctl.setActiveScene('s3');
    await tester.pump();
    expect(rowWidget(tester, 'Three').selected, isTrue);
  });

  testWidgets('unnamed scenes are labelled by position', (tester) async {
    final c = await pumpPanel(tester, const ScenesPanel());
    c.ctl.execute(const UpdateSceneSettings('s1', name: ' '));
    await tester.pump();
    expect(find.text('Scene 1'), findsOneWidget);
  });

  group('add', () {
    testWidgets('the + menu adds a pinned or a flow scene after the active', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      await tester.tap(find.bySemanticsLabel('Add scene'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pinned scene'));
      await tester.pumpAndSettle();
      expect(c.doc.scenes, hasLength(4));
      expect(sceneIds(c.doc).first, 's1');
      final added = c.doc.scenes[1];
      expect(added.kind, ir.SceneKind.pinned);
      expect(added.name, 'Scene 4');
      expect(c.st.activeSceneId, added.id);
      expect(rowWidget(tester, 'Scene 4').selected, isTrue);
      _expectUndoRedo(c, before);

      c.ctl.undo();
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Add scene'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Flow scene'));
      await tester.pumpAndSettle();
      expect(c.doc.scenes[1].kind, ir.SceneKind.flow);
      expect(c.doc.scenes[1].scrollLength, 0);
    });
  });

  group('context menu', () {
    testWidgets('Duplicate copies the scene after it and activates it', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _openMenu(tester, 'Two');
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(c.doc.scenes.map((s) => s.name), [
        'One',
        'Two',
        'Two copy',
        'Three',
      ]);
      expect(c.st.activeSceneId, c.doc.scenes[2].id);
      expect(rowOf('Two copy'), findsOneWidget);
      _expectUndoRedo(c, before);
    });

    testWidgets('Add pinned / flow scene after the row', (tester) async {
      final c = await _pump(tester);
      await _openMenu(tester, 'One');
      await tester.tap(find.text('Add flow scene after'));
      await tester.pumpAndSettle();
      expect(c.doc.scenes[1].kind, ir.SceneKind.flow);
      expect(c.doc.scenes, hasLength(4));
      await _openMenu(tester, 'Three');
      await tester.tap(find.text('Add pinned scene after'));
      await tester.pumpAndSettle();
      expect(c.doc.scenes.last.kind, ir.SceneKind.pinned);
    });

    testWidgets('Delete asks first; cancel keeps, confirm deletes', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _openMenu(tester, 'Two');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete scene'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(identical(c.doc, before), isTrue);

      await _openMenu(tester, 'Two');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SsDialog),
          matching: find.text('Delete'),
        ),
      );
      await tester.pumpAndSettle();
      expect(sceneIds(c.doc), ['s1', 's3']);
      expect(rowOf('Two'), findsNothing);
      _expectUndoRedo(c, before);
    });

    testWidgets('the last scene cannot be deleted', (tester) async {
      final c = await pumpPanel(tester, const ScenesPanel());
      c.ctl.execute(const DeleteScene('s2'));
      await tester.pump();
      await _openMenu(tester, 'One');
      await tester.tap(find.text('Delete'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Delete scene'), findsNothing);
      expect(c.doc.scenes, hasLength(1));
    });

    testWidgets('Rename edits inline and writes the name', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _openMenu(tester, 'Two');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(_rowEditor, findsOneWidget);
      await tester.enterText(_rowEditor, 'Middle');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(_scene(c, 's2').name, 'Middle');
      expect(rowOf('Middle'), findsOneWidget);
      _expectUndoRedo(c, before);
    });
  });

  testWidgets('double-click and F2 rename', (tester) async {
    final c = await _pump(tester);
    await tester.tap(find.text('Three'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('Three'));
    await tester.pump();
    await tester.pump();
    expect(_rowEditor, findsOneWidget);
    await tester.enterText(_rowEditor, 'Finale');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(_scene(c, 's3').name, 'Finale');
    // Escape cancels an F2 rename.
    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pump();
    await tester.pump();
    await tester.enterText(_rowEditor, 'Nope');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(_scene(c, 's3').name, 'Finale');
  });

  testWidgets('Up and Down change the active scene', (tester) async {
    final c = await _pump(tester);
    await tester.tap(find.text('One'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(c.st.activeSceneId, 's2');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(c.st.activeSceneId, 's3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(c.st.activeSceneId, 's2');
  });

  group('drag to reorder', () {
    Future<void> drag(WidgetTester tester, Offset from, Offset to) async {
      final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await tester.pump();
      for (var i = 1; i <= 8; i++) {
        await g.moveTo(Offset.lerp(from, to, i / 8)!);
        await tester.pump();
      }
      await g.up();
      await tester.pump(const Duration(milliseconds: 50));
    }

    Offset at(WidgetTester tester, String label, double f) {
      final r = tester.getRect(rowOf(label));
      return Offset(r.left + 60, r.top + r.height * f);
    }

    testWidgets('dropping between rows moves the scene: one undo step', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      await drag(tester, at(tester, 'One', 0.5), at(tester, 'Three', 0.9));
      expect(sceneIds(c.doc), ['s2', 's3', 's1']);
      expect(c.st.history.undoLabel, 'Move scene');
      _expectUndoRedo(c, before);
      c.ctl.undo();
      expect(sceneIds(c.doc), ['s1', 's2', 's3']);
      await tester.pump();

      await drag(tester, at(tester, 'Three', 0.5), at(tester, 'One', 0.05));
      expect(sceneIds(c.doc), ['s3', 's1', 's2']);
    });

    testWidgets('dropping where it already is changes nothing', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await drag(tester, at(tester, 'Two', 0.5), at(tester, 'Two', 0.7));
      expect(identical(c.doc, before), isTrue);
      expect(c.st.history.canUndo, isFalse);
    });

    testWidgets('a plain click activates, a drag does not', (tester) async {
      final c = await _pump(tester);
      await drag(tester, at(tester, 'Two', 0.5), at(tester, 'Three', 0.9));
      expect(c.st.activeSceneId, 's1');
      final g = await tester.startGesture(
        at(tester, 'Three', 0.5),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(0, 1));
      await g.up();
      await tester.pump(const Duration(milliseconds: 50));
      expect(c.st.activeSceneId, 's3');
    });
  });

  testWidgets('the panel lists scenes only; settings are in the Inspector', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Scene settings'), findsNothing);
    expect(_field('Scroll length'), findsNothing);
  });
}
