import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
        UndoIntent,
        RedoIntent,
        CopyNodesIntent,
        CutNodesIntent,
        PasteNodesIntent,
        DuplicateIntent,
        DeleteNodesIntent,
        SelectAllIntent,
        GroupIntent,
        UngroupIntent,
        NudgeIntent,
        SelectToolIntent,
        ZoomInIntent,
        ZoomOutIntent,
        ZoomToFitIntent,
        ToggleLeftPanelIntent,
        ToggleRightPanelIntent,
        ToggleTimelineIntent,
        PreviewIntent,
        ShowShortcutHelpIntent,
        SaveIntent,
        RenameIntent,
      ]),
    );
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
            UndoIntent: EditorAction<UndoIntent>((_) => log.add('undo')),
            SelectToolIntent: EditorAction<SelectToolIntent>(
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

  testWidgets('bare-key shortcuts stand down while typing in a text field', (
    tester,
  ) async {
    final log = <String>[];
    await pumpChrome(
      tester,
      EditorShortcuts(
        mac: false,
        child: Actions(
          actions: {
            SelectToolIntent: EditorAction<SelectToolIntent>(
              (i) => log.add('tool:${i.tool.name}'),
            ),
            UndoIntent: EditorAction<UndoIntent>((_) => log.add('undo')),
          },
          child: const SizedBox(width: 200, child: TextField(autofocus: true)),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    expect(log, isEmpty);
    // Modifier shortcuts still work.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(log, ['undo']);
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
