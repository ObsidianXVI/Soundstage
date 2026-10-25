import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/shortcuts/editor_shortcuts.dart';
import 'package:soundstage_platform/editor/shortcuts/intents.dart';
import 'package:soundstage_platform/editor/shortcuts/shortcut_help.dart';
import 'package:soundstage_platform/editor/shortcuts/shortcut_map.dart';

import '../design_system/harness.dart';

void main() {
  test('every entry has an id, a label, a group and a key; ids are unique', () {
    final ids = <String>{};
    for (final d in kEditorShortcuts) {
      expect(d.label, isNotEmpty);
      expect(d.group, isNotEmpty);
      expect(d.keys, isNotEmpty);
      expect(ids.add(d.id), isTrue, reason: 'duplicate id ${d.id}');
    }
  });

  test('no two entries share a key combination', () {
    final seen = <String, String>{};
    for (final d in kEditorShortcuts) {
      for (final k in d.keys) {
        final label = k.label(mac: true);
        expect(
          seen[label],
          isNull,
          reason: '$label: ${seen[label]} vs ${d.id}',
        );
        seen[label] = d.id;
      }
    }
  });

  test('Cmd on macOS, Ctrl elsewhere', () {
    final mac = buildShortcutMap(mac: true);
    final other = buildShortcutMap(mac: false);
    final cmdZ = mac.keys.whereType<SingleActivator>().firstWhere(
      (a) => a.trigger == LogicalKeyboardKey.keyZ && !a.shift,
    );
    expect(cmdZ.meta, isTrue);
    expect(cmdZ.control, isFalse);
    final ctrlZ = other.keys.whereType<SingleActivator>().firstWhere(
      (a) => a.trigger == LogicalKeyboardKey.keyZ && !a.shift,
    );
    expect(ctrlZ.control, isTrue);
    expect(ctrlZ.meta, isFalse);
    expect(shortcutLabel('undo', mac: true), '⌘Z');
    expect(shortcutLabel('undo', mac: false), 'Ctrl+Z');
    expect(shortcutLabel('redo', mac: true), '⌘⇧Z');
    expect(shortcutLabel('redo', mac: false), 'Ctrl+Shift+Z');
    expect(shortcutLabel('help', mac: false), '?');
    expect(isMacPlatform(TargetPlatform.macOS), isTrue);
    expect(isMacPlatform(TargetPlatform.windows), isFalse);
  });

  test('the table defines the expected intents', () {
    final types = kEditorShortcuts.map((d) => d.intent.runtimeType).toSet();
    expect(
      types,
      containsAll(<Type>[
        // Core (document and selection) intents.
        UndoIntent,
        RedoIntent,
        DuplicateSelectionIntent,
        DeleteSelectionIntent,
        SelectAllIntent,
        SelectNoneIntent,
        GroupSelectionIntent,
        UngroupSelectionIntent,
        FrameSelectionIntent,
        AddAutoLayoutIntent,
        ReorderSelectionIntent,
        NudgeIntent,
        RenameSelectionIntent,
        ToggleVisibilityIntent,
        ToggleLockIntent,
        SelectParentIntent,
        SelectChildrenIntent,
        SelectSiblingIntent,
        // UI intents.
        SelectToolIntent,
        ZoomInIntent,
        ZoomOutIntent,
        ZoomTo100Intent,
        ZoomToFitIntent,
        ZoomToSelectionIntent,
        ToggleLeftPanelIntent,
        ToggleRightPanelIntent,
        ToggleTimelineIntent,
        PreviewIntent,
        ShowShortcutHelpIntent,
        SaveIntent,
      ]),
    );
    // Every intent is either a core intent (actionForIntent) or a UI one.
    for (final d in kEditorShortcuts) {
      expect(
        d.intent is EditorIntent || d.intent is ShellIntent,
        isTrue,
        reason: d.id,
      );
    }
  });

  test('zoom keys: Cmd+0 is 100%, Shift+1 fit, Shift+2 selection', () {
    expect(shortcutLabel('zoom100', mac: true), '⌘0');
    expect(shortcutLabel('zoomFit', mac: true), '⇧1');
    expect(shortcutLabel('zoomSelection', mac: false), 'Shift+2');
    expect(shortcutLabel('rename', mac: true), '⌘R');
  });

  testWidgets('core intents reach onEditorIntent; UI intents their actions', (
    tester,
  ) async {
    final log = <String>[];
    await pumpChrome(
      tester,
      EditorShortcuts(
        mac: false,
        onEditorIntent: (i) => log.add(i.runtimeType.toString()),
        actions: {
          ZoomToFitIntent: EditorShortcutAction<ZoomToFitIntent>(
            (_) => log.add('fit'),
          ),
        },
        child: const Focus(autofocus: true, child: SizedBox()),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(log, ['UndoIntent', 'GroupSelectionIntent', 'NudgeIntent', 'fit']);
  });

  testWidgets('a key fires its intent through Shortcuts and Actions', (
    tester,
  ) async {
    final log = <String>[];
    await pumpChrome(
      tester,
      EditorShortcuts(
        mac: false,
        child: Actions(
          actions: {
            UndoIntent: EditorShortcutAction<UndoIntent>(
              (_) => log.add('undo'),
            ),
            SelectToolIntent: EditorShortcutAction<SelectToolIntent>(
              (i) => log.add('tool:${i.tool.name}'),
            ),
          },
          child: const Focus(autofocus: true, child: SizedBox()),
        ),
      ),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    expect(log, ['undo', 'tool:text']);
  });

  testWidgets('shortcuts stand down while typing in a text field', (
    tester,
  ) async {
    final log = <String>[];
    await pumpChrome(
      tester,
      EditorShortcuts(
        mac: false,
        child: Actions(
          actions: {
            SelectToolIntent: EditorShortcutAction<SelectToolIntent>(
              (i) => log.add('tool:${i.tool.name}'),
            ),
            UndoIntent: EditorShortcutAction<UndoIntent>(
              (_) => log.add('undo'),
            ),
            DeleteSelectionIntent: EditorShortcutAction<DeleteSelectionIntent>(
              (_) => log.add('delete'),
            ),
          },
          child: const SizedBox(width: 200, child: TextField(autofocus: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(log, isEmpty);
    // Document chords stand down too: the field edits natively.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(log, isEmpty);
  });

  testWidgets('the help dialog lists the shortcuts and closes with Escape', (
    tester,
  ) async {
    late BuildContext ctx;
    await pumpChrome(
      tester,
      Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox();
        },
      ),
      size: const Size(1000, 800),
    );
    unawaited(showShortcutHelp(ctx, mac: false));
    await tester.pumpAndSettle();
    expect(find.byType(ShortcutHelpDialog), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);
    expect(find.text('Ctrl+Z'), findsOneWidget);
    expect(find.text('TOOLS'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsNothing);
  });
}
