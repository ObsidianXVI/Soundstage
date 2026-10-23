import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'intents.dart';

/// A key combination as data, so it can both fire an intent and be shown in
/// menus, tooltips and the help overlay.
///
/// [mod] is Cmd on macOS and Ctrl elsewhere.
@immutable
class ShortcutKey {
  const ShortcutKey(
    this.key, {
    this.mod = false,
    this.shift = false,
    this.alt = false,
    this.character,
  });

  final LogicalKeyboardKey key;
  final bool mod;
  final bool shift;
  final bool alt;

  /// Fires on the typed character (for `?`, which needs Shift on most
  /// layouts) instead of a physical key.
  final String? character;

  ShortcutActivator activator({required bool mac}) {
    if (character != null) return CharacterActivator(character!);
    return SingleActivator(
      key,
      meta: mod && mac,
      control: mod && !mac,
      shift: shift,
      alt: alt,
    );
  }

  /// Display text: `⌘⇧Z` on macOS, `Ctrl+Shift+Z` elsewhere.
  String label({required bool mac}) {
    if (character != null) return character!;
    final k = character ?? _keyLabel(key);
    if (mac) {
      return '${mod ? '⌘' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}$k';
    }
    return [if (mod) 'Ctrl', if (alt) 'Alt', if (shift) 'Shift', k].join('+');
  }

  /// Bare keys (no modifier) conflict with typing into text fields.
  bool get isBare =>
      !mod && !alt && (character != null || !_isNonPrintable(key));

  static bool _isNonPrintable(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.escape ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.f2 ||
      k == LogicalKeyboardKey.delete ||
      k == LogicalKeyboardKey.backspace;

  static String _keyLabel(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.arrowUp) return '↑';
    if (k == LogicalKeyboardKey.arrowDown) return '↓';
    if (k == LogicalKeyboardKey.arrowLeft) return '←';
    if (k == LogicalKeyboardKey.arrowRight) return '→';
    if (k == LogicalKeyboardKey.escape) return 'Esc';
    if (k == LogicalKeyboardKey.enter) return 'Enter';
    if (k == LogicalKeyboardKey.backspace) return '⌫';
    if (k == LogicalKeyboardKey.delete) return 'Del';
    if (k == LogicalKeyboardKey.bracketLeft) return '[';
    if (k == LogicalKeyboardKey.bracketRight) return ']';
    if (k == LogicalKeyboardKey.equal) return '=';
    if (k == LogicalKeyboardKey.minus) return '-';
    if (k == LogicalKeyboardKey.f2) return 'F2';
    return k.keyLabel.toUpperCase();
  }
}

/// One entry of the shortcut table.
@immutable
class ShortcutDef {
  const ShortcutDef({
    required this.id,
    required this.label,
    required this.group,
    required this.intent,
    required this.keys,
  });

  final String id;
  final String label;
  final String group;
  final Intent intent;

  /// Alternative key combinations (the first is the one displayed).
  final List<ShortcutKey> keys;
}

const _a = LogicalKeyboardKey.keyA;

/// The editor's shortcut table. Cmd on macOS, Ctrl elsewhere (see
/// [ShortcutKey.mod]).
const List<ShortcutDef> kEditorShortcuts = <ShortcutDef>[
  // Edit
  ShortcutDef(
    id: 'undo',
    label: 'Undo',
    group: 'Edit',
    intent: UndoIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyZ, mod: true)],
  ),
  ShortcutDef(
    id: 'redo',
    label: 'Redo',
    group: 'Edit',
    intent: RedoIntent(),
    keys: [
      ShortcutKey(LogicalKeyboardKey.keyZ, mod: true, shift: true),
      ShortcutKey(LogicalKeyboardKey.keyY, mod: true),
    ],
  ),
  ShortcutDef(
    id: 'copy',
    label: 'Copy',
    group: 'Edit',
    intent: CopyNodesIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyC, mod: true)],
  ),
  ShortcutDef(
    id: 'cut',
    label: 'Cut',
    group: 'Edit',
    intent: CutNodesIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyX, mod: true)],
  ),
  ShortcutDef(
    id: 'paste',
    label: 'Paste',
    group: 'Edit',
    intent: PasteNodesIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyV, mod: true)],
  ),
  ShortcutDef(
    id: 'duplicate',
    label: 'Duplicate',
    group: 'Edit',
    intent: DuplicateIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyD, mod: true)],
  ),
  ShortcutDef(
    id: 'delete',
    label: 'Delete',
    group: 'Edit',
    intent: DeleteNodesIntent(),
    keys: [
      ShortcutKey(LogicalKeyboardKey.backspace),
      ShortcutKey(LogicalKeyboardKey.delete),
    ],
  ),
  ShortcutDef(
    id: 'selectAll',
    label: 'Select all',
    group: 'Edit',
    intent: SelectAllIntent(),
    keys: [ShortcutKey(_a, mod: true)],
  ),
  ShortcutDef(
    id: 'rename',
    label: 'Rename',
    group: 'Edit',
    intent: RenameIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.f2)],
  ),
  ShortcutDef(
    id: 'save',
    label: 'Save',
    group: 'Edit',
    intent: SaveIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyS, mod: true)],
  ),
  // Selection
  ShortcutDef(
    id: 'selectParent',
    label: 'Select parent',
    group: 'Selection',
    intent: SelectParentIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.escape)],
  ),
  ShortcutDef(
    id: 'selectChildren',
    label: 'Select children',
    group: 'Selection',
    intent: SelectChildrenIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.enter)],
  ),
  ShortcutDef(
    id: 'nudgeLeft',
    label: 'Nudge left',
    group: 'Selection',
    intent: NudgeIntent(-1, 0),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowLeft)],
  ),
  ShortcutDef(
    id: 'nudgeRight',
    label: 'Nudge right',
    group: 'Selection',
    intent: NudgeIntent(1, 0),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowRight)],
  ),
  ShortcutDef(
    id: 'nudgeUp',
    label: 'Nudge up',
    group: 'Selection',
    intent: NudgeIntent(0, -1),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowUp)],
  ),
  ShortcutDef(
    id: 'nudgeDown',
    label: 'Nudge down',
    group: 'Selection',
    intent: NudgeIntent(0, 1),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowDown)],
  ),
  ShortcutDef(
    id: 'nudgeLeftBig',
    label: 'Nudge left by 10',
    group: 'Selection',
    intent: NudgeIntent(-10, 0, large: true),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowLeft, shift: true)],
  ),
  ShortcutDef(
    id: 'nudgeRightBig',
    label: 'Nudge right by 10',
    group: 'Selection',
    intent: NudgeIntent(10, 0, large: true),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowRight, shift: true)],
  ),
  ShortcutDef(
    id: 'nudgeUpBig',
    label: 'Nudge up by 10',
    group: 'Selection',
    intent: NudgeIntent(0, -10, large: true),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowUp, shift: true)],
  ),
  ShortcutDef(
    id: 'nudgeDownBig',
    label: 'Nudge down by 10',
    group: 'Selection',
    intent: NudgeIntent(0, 10, large: true),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowDown, shift: true)],
  ),
  // Structure
  ShortcutDef(
    id: 'group',
    label: 'Group',
    group: 'Arrange',
    intent: GroupIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyG, mod: true)],
  ),
  ShortcutDef(
    id: 'ungroup',
    label: 'Ungroup',
    group: 'Arrange',
    intent: UngroupIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyG, mod: true, shift: true)],
  ),
  ShortcutDef(
    id: 'frameSelection',
    label: 'Frame selection',
    group: 'Arrange',
    intent: FrameSelectionIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyG, mod: true, alt: true)],
  ),
  ShortcutDef(
    id: 'bringForward',
    label: 'Bring forward',
    group: 'Arrange',
    intent: BringForwardIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.bracketRight, mod: true)],
  ),
  ShortcutDef(
    id: 'sendBackward',
    label: 'Send backward',
    group: 'Arrange',
    intent: SendBackwardIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.bracketLeft, mod: true)],
  ),
  ShortcutDef(
    id: 'bringToFront',
    label: 'Bring to front',
    group: 'Arrange',
    intent: BringForwardIntent(toFront: true),
    keys: [ShortcutKey(LogicalKeyboardKey.bracketRight, mod: true, alt: true)],
  ),
  ShortcutDef(
    id: 'sendToBack',
    label: 'Send to back',
    group: 'Arrange',
    intent: SendBackwardIntent(toBack: true),
    keys: [ShortcutKey(LogicalKeyboardKey.bracketLeft, mod: true, alt: true)],
  ),
  ShortcutDef(
    id: 'toggleVisibility',
    label: 'Show / hide',
    group: 'Arrange',
    intent: ToggleVisibilityIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyH, mod: true, shift: true)],
  ),
  ShortcutDef(
    id: 'toggleLock',
    label: 'Lock / unlock',
    group: 'Arrange',
    intent: ToggleLockIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyL, mod: true, shift: true)],
  ),
  // Tools
  ShortcutDef(
    id: 'toolMove',
    label: 'Move',
    group: 'Tools',
    intent: SelectToolIntent(EditorTool.move),
    keys: [ShortcutKey(LogicalKeyboardKey.keyV)],
  ),
  ShortcutDef(
    id: 'toolFrame',
    label: 'Frame',
    group: 'Tools',
    intent: SelectToolIntent(EditorTool.frame),
    keys: [ShortcutKey(LogicalKeyboardKey.keyF)],
  ),
  ShortcutDef(
    id: 'toolText',
    label: 'Text',
    group: 'Tools',
    intent: SelectToolIntent(EditorTool.text),
    keys: [ShortcutKey(LogicalKeyboardKey.keyT)],
  ),
  ShortcutDef(
    id: 'toolRectangle',
    label: 'Rectangle',
    group: 'Tools',
    intent: SelectToolIntent(EditorTool.rectangle),
    keys: [ShortcutKey(LogicalKeyboardKey.keyR)],
  ),
  ShortcutDef(
    id: 'toolEllipse',
    label: 'Ellipse',
    group: 'Tools',
    intent: SelectToolIntent(EditorTool.ellipse),
    keys: [ShortcutKey(LogicalKeyboardKey.keyO)],
  ),
  ShortcutDef(
    id: 'toolLine',
    label: 'Line',
    group: 'Tools',
    intent: SelectToolIntent(EditorTool.line),
    keys: [ShortcutKey(LogicalKeyboardKey.keyL)],
  ),
  ShortcutDef(
    id: 'toolHand',
    label: 'Hand',
    group: 'Tools',
    intent: SelectToolIntent(EditorTool.hand),
    keys: [ShortcutKey(LogicalKeyboardKey.keyH)],
  ),
  // View
  ShortcutDef(
    id: 'zoomIn',
    label: 'Zoom in',
    group: 'View',
    intent: ZoomInIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.equal, mod: true)],
  ),
  ShortcutDef(
    id: 'zoomOut',
    label: 'Zoom out',
    group: 'View',
    intent: ZoomOutIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.minus, mod: true)],
  ),
  ShortcutDef(
    id: 'zoom100',
    label: 'Zoom to 100%',
    group: 'View',
    intent: ZoomTo100Intent(),
    keys: [ShortcutKey(LogicalKeyboardKey.digit0, shift: true)],
  ),
  ShortcutDef(
    id: 'zoomFit',
    label: 'Zoom to fit',
    group: 'View',
    intent: ZoomToFitIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.digit1, shift: true)],
  ),
  ShortcutDef(
    id: 'zoomSelection',
    label: 'Zoom to selection',
    group: 'View',
    intent: ZoomToSelectionIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.digit2, shift: true)],
  ),
  ShortcutDef(
    id: 'toggleLeft',
    label: 'Toggle left panel',
    group: 'View',
    intent: ToggleLeftPanelIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.digit1, alt: true)],
  ),
  ShortcutDef(
    id: 'toggleRight',
    label: 'Toggle inspector',
    group: 'View',
    intent: ToggleRightPanelIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.digit2, alt: true)],
  ),
  ShortcutDef(
    id: 'toggleTimeline',
    label: 'Toggle timeline',
    group: 'View',
    intent: ToggleTimelineIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.digit3, alt: true)],
  ),
  ShortcutDef(
    id: 'preview',
    label: 'Preview story',
    group: 'View',
    intent: PreviewIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.enter, mod: true, alt: true)],
  ),
  ShortcutDef(
    id: 'help',
    label: 'Keyboard shortcuts',
    group: 'Help',
    intent: ShowShortcutHelpIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.slash, shift: true, character: '?')],
  ),
];

/// Whether the platform uses Cmd (macOS, iOS) rather than Ctrl.
bool isMacPlatform([TargetPlatform? platform]) {
  final p = platform ?? defaultTargetPlatform;
  return p == TargetPlatform.macOS || p == TargetPlatform.iOS;
}

/// The activator-to-intent map for `Shortcuts`.
Map<ShortcutActivator, Intent> buildShortcutMap({bool? mac}) {
  final isMac = mac ?? isMacPlatform();
  return <ShortcutActivator, Intent>{
    for (final def in kEditorShortcuts)
      for (final k in def.keys) k.activator(mac: isMac): def.intent,
  };
}

/// The displayed shortcut for the entry with [id], or null.
String? shortcutLabel(String id, {bool? mac}) {
  final isMac = mac ?? isMacPlatform();
  for (final d in kEditorShortcuts) {
    if (d.id == id) return d.keys.first.label(mac: isMac);
  }
  return null;
}

/// Whether [intent] fires from a bare key (no modifier), which must not
/// trigger while typing into a text field.
bool intentIsTextSensitive(Intent intent) {
  for (final d in kEditorShortcuts) {
    if (identical(d.intent, intent)) return d.keys.any((k) => k.isBare);
  }
  return false;
}

/// True when the primary focus is inside an editable text.
bool primaryFocusIsTextInput() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return false;
  if (ctx.widget is EditableText) return true;
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}
