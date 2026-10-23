import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';

import 'fixtures.dart';

EditorIntent? _find(
  Map<ShortcutActivator, EditorIntent> map,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool control = false,
  bool shift = false,
  bool alt = false,
}) {
  for (final e in map.entries) {
    final a = e.key as SingleActivator;
    if (a.trigger == key &&
        a.meta == meta &&
        a.control == control &&
        a.shift == shift &&
        a.alt == alt) {
      return e.value;
    }
  }
  return null;
}

void main() {
  test('Cmd on Apple platforms, Ctrl elsewhere', () {
    final mac = editorShortcuts(apple: true);
    final win = editorShortcuts(apple: false);
    expect(_find(mac, LogicalKeyboardKey.keyZ, meta: true), isA<UndoIntent>());
    expect(
      _find(win, LogicalKeyboardKey.keyZ, control: true),
      isA<UndoIntent>(),
    );
    expect(
      _find(mac, LogicalKeyboardKey.keyZ, meta: true, shift: true),
      isA<RedoIntent>(),
    );
    expect(
      _find(win, LogicalKeyboardKey.keyY, control: true),
      isA<RedoIntent>(),
    );
    expect(_find(mac, LogicalKeyboardKey.keyY, meta: true), isNull);
  });

  test('the full Figma map', () {
    final m = editorShortcuts(apple: true);
    final expected = <(LogicalKeyboardKey, bool, bool, bool, Type)>[
      // key, cmd, shift, alt
      (LogicalKeyboardKey.delete, false, false, false, DeleteSelectionIntent),
      (
        LogicalKeyboardKey.backspace,
        false,
        false,
        false,
        DeleteSelectionIntent,
      ),
      (LogicalKeyboardKey.keyD, true, false, false, DuplicateSelectionIntent),
      (LogicalKeyboardKey.keyG, true, false, false, GroupSelectionIntent),
      (LogicalKeyboardKey.keyG, true, false, true, FrameSelectionIntent),
      (LogicalKeyboardKey.keyG, true, true, false, UngroupSelectionIntent),
      (LogicalKeyboardKey.keyA, false, true, false, AddAutoLayoutIntent),
      (LogicalKeyboardKey.keyA, true, false, false, SelectAllIntent),
      (LogicalKeyboardKey.keyA, true, true, false, SelectNoneIntent),
      (LogicalKeyboardKey.keyR, true, false, false, RenameSelectionIntent),
      (LogicalKeyboardKey.keyH, true, true, false, ToggleVisibilityIntent),
      (LogicalKeyboardKey.keyL, true, true, false, ToggleLockIntent),
      (LogicalKeyboardKey.escape, false, false, false, SelectParentIntent),
      (LogicalKeyboardKey.enter, false, false, false, SelectChildrenIntent),
      (LogicalKeyboardKey.tab, false, false, false, SelectSiblingIntent),
    ];
    for (final (key, cmd, shift, alt, type) in expected) {
      final i = _find(m, key, meta: cmd, shift: shift, alt: alt);
      expect(i.runtimeType, type, reason: '$key');
    }
    final nudge =
        _find(m, LogicalKeyboardKey.arrowLeft, shift: true)! as NudgeIntent;
    expect((nudge.dx, nudge.dy), (-10.0, 0.0));
    final down = _find(m, LogicalKeyboardKey.arrowDown)! as NudgeIntent;
    expect((down.dx, down.dy), (0.0, 1.0));
  });

  test('intents map to commands; nothing selected is no action', () {
    final c = editorContainer();
    expect(
      actionForIntent(const DeleteSelectionIntent(), c.st),
      isA<NoAction>(),
    );
    c.ctl.select({'a1'});
    final st = c.st;
    expect(
      (actionForIntent(const DeleteSelectionIntent(), st) as RunCommand)
          .command,
      isA<DeleteNodes>(),
    );
    expect(
      (actionForIntent(const UngroupSelectionIntent(), st) as RunCommand)
          .command,
      isA<UnwrapFrame>(),
    );
    expect(
      actionForIntent(const RenameSelectionIntent(), st),
      isA<BeginRename>(),
    );
    expect(actionForIntent(const UndoIntent(), st), isA<UndoAction>());
    expect(
      actionForIntent(const SelectParentIntent(), st),
      isA<NoAction>(),
      reason: 'no tree given',
    );
  });

  test('perform runs the intents through the controller', () {
    final c = editorContainer();
    c.ctl.select({'a1'});
    c.ctl.perform(const NudgeIntent(10, 0));
    expect(c.node('a1').common.x, 20);
    c.ctl.perform(const ToggleVisibilityIntent());
    expect(c.node('a1').common.visible, isFalse);
    c.ctl.perform(const ToggleVisibilityIntent());
    expect(c.node('a1').common.visible, isTrue);
    c.ctl.perform(const ToggleLockIntent());
    expect(c.node('a1').common.locked, isTrue);
    c.ctl.perform(const UndoIntent());
    expect(c.node('a1').common.locked, isFalse);
    c.ctl.perform(const RedoIntent());
    expect(c.node('a1').common.locked, isTrue);
    c.ctl.perform(const SelectParentIntent());
    expect(c.st.selection, {'a'});
    c.ctl.perform(const SelectAllIntent());
    expect(c.st.selection, {'a', 'b', 'inst', 'row'});
    c.ctl.perform(const SelectNoneIntent());
    expect(c.st.selection, isEmpty);
    expect(c.ctl.perform(const DuplicateSelectionIntent()), isA<NoAction>());
  });
}
