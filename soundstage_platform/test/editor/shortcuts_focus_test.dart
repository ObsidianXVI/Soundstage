import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/shortcuts/editor_shortcuts.dart';
import 'package:soundstage_platform/editor/shortcuts/shortcut_map.dart';
import 'package:soundstage_platform/editor/text/text_edit_controller.dart';

import '../design_system/harness.dart';

Future<void> _chord(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

void main() {
  testWidgets('B2: Cmd chords never reach the editor from a chrome field', (
    tester,
  ) async {
    final log = <String>[];
    await pumpChrome(
      tester,
      EditorShortcuts(
        mac: false,
        onEditorIntent: (i) => log.add(i.runtimeType.toString()),
        child: const SizedBox(width: 200, child: TextField(autofocus: true)),
      ),
    );
    await tester.pump();
    await _chord(tester, LogicalKeyboardKey.keyA);
    await _chord(tester, LogicalKeyboardKey.keyD);
    await _chord(tester, LogicalKeyboardKey.keyZ);
    await _chord(tester, LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(log, isEmpty);
    // Once focus is off the field, the same chord selects all.
    FocusManager.instance.primaryFocus!.unfocus();
    await tester.pump();
    expect(primaryFocusIsChromeTextInput(), isFalse);
  });

  testWidgets('B2: on-canvas text editing keeps its Cmd chords', (
    tester,
  ) async {
    final log = <String>[];
    final node = StageTextFocusNode();
    addTearDown(node.dispose);
    await pumpChrome(
      tester,
      EditorShortcuts(
        mac: false,
        onEditorIntent: (i) => log.add(i.runtimeType.toString()),
        child: Focus(focusNode: node, autofocus: true, child: const SizedBox()),
      ),
    );
    await tester.pump();
    expect(primaryFocusIsStageText(), isTrue);
    expect(primaryFocusIsChromeTextInput(), isFalse);
    await _chord(tester, LogicalKeyboardKey.keyZ);
    expect(log, ['UndoIntent']);
  });

  testWidgets('B1: a canvas pointer down returns focus to the shortcuts', (
    tester,
  ) async {
    final log = <String>[];
    await pumpChrome(
      tester,
      EditorShortcuts(
        mac: false,
        onEditorIntent: (i) => log.add(i.runtimeType.toString()),
        child: const Focus(
          autofocus: true,
          child: Column(
            children: [SizedBox(width: 200, child: TextField(autofocus: true))],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(primaryFocusIsChromeTextInput(), isTrue);
    // A click inside the field itself keeps the caret.
    reclaimShortcutFocus(tester.getCenter(find.byType(TextField)));
    await tester.pump();
    expect(primaryFocusIsChromeTextInput(), isTrue);
    reclaimShortcutFocus(const Offset(700, 500));
    await tester.pump();
    expect(primaryFocusIsTextInput(), isFalse);
    await _chord(tester, LogicalKeyboardKey.keyZ);
    expect(log, ['UndoIntent']);
  });

  testWidgets('B1: Enter in a number field commits once and frees focus', (
    tester,
  ) async {
    final log = <String>[];
    final emits = <double>[];
    await pumpChrome(
      tester,
      EditorShortcuts(
        mac: false,
        onEditorIntent: (i) => log.add(i.runtimeType.toString()),
        child: Focus(
          autofocus: true,
          child: SizedBox(
            width: 120,
            child: SsNumberField(value: 10, onChanged: emits.add),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(primaryFocusIsChromeTextInput(), isTrue);
    await tester.enterText(find.byType(TextField), '42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(emits, [42.0]);
    expect(primaryFocusIsTextInput(), isFalse);
    await _chord(tester, LogicalKeyboardKey.keyZ);
    expect(log, ['UndoIntent']);
  });

  testWidgets('B1: Escape in a number field frees focus', (tester) async {
    await pumpChrome(
      tester,
      Focus(
        autofocus: true,
        child: SizedBox(
          width: 120,
          child: SsNumberField(value: 10, onChanged: (_) {}),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(primaryFocusIsChromeTextInput(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(primaryFocusIsTextInput(), isFalse);
  });
}
