import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/design_system/design_system.dart'
    show isTextInputFocus, releaseFocusToAncestor;
import 'package:soundstage_platform/editor/core/commands/node_commands.dart'
    show ReorderDirection;
import 'package:soundstage_platform/editor/core/editor_state.dart';
import 'package:soundstage_platform/editor/core/shortcuts.dart';

import '../text/text_edit_controller.dart' show primaryFocusIsStageText;
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
    this.offMacOnly = false,
  });

  final LogicalKeyboardKey key;
  final bool mod;
  final bool shift;
  final bool alt;

  /// Fires on the typed character (for `?`, which needs Shift on most
  /// layouts) instead of a physical key.
  final String? character;

  /// Bound only off macOS (Ctrl+Y redo, which macOS doesn't use).
  final bool offMacOnly;

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

  /// Keys without Cmd/Ctrl conflict with typing into a text field: letters
  /// and `?` type, Alt+digit types a symbol on macOS, and arrows, Tab,
  /// Enter, Escape, Backspace and Delete edit or move the caret.
  bool get isBare => !mod;

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

/// The editor's one shortcut table: document and selection intents
/// (`EditorIntent`, turned into commands by `actionForIntent`) and the
/// shell's UI intents ([ShellIntent]). Cmd on macOS, Ctrl elsewhere (see
/// [ShortcutKey.mod]). Every entry is wired: the help overlay lists exactly
/// what works.
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
      ShortcutKey(LogicalKeyboardKey.keyY, mod: true, offMacOnly: true),
    ],
  ),
  ShortcutDef(
    id: 'copy',
    label: 'Copy',
    group: 'Edit',
    intent: CopyIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyC, mod: true)],
  ),
  ShortcutDef(
    id: 'cut',
    label: 'Cut',
    group: 'Edit',
    intent: CutIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyX, mod: true)],
  ),
  ShortcutDef(
    id: 'paste',
    label: 'Paste',
    group: 'Edit',
    intent: PasteIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyV, mod: true)],
  ),
  ShortcutDef(
    id: 'pasteReplace',
    label: 'Paste to replace',
    group: 'Edit',
    intent: PasteReplaceIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyV, mod: true, shift: true)],
  ),
  ShortcutDef(
    id: 'duplicate',
    label: 'Duplicate',
    group: 'Edit',
    intent: DuplicateSelectionIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyD, mod: true)],
  ),
  ShortcutDef(
    id: 'delete',
    label: 'Delete',
    group: 'Edit',
    intent: DeleteSelectionIntent(),
    keys: [
      ShortcutKey(LogicalKeyboardKey.backspace),
      ShortcutKey(LogicalKeyboardKey.delete),
    ],
  ),
  ShortcutDef(
    id: 'rename',
    label: 'Rename',
    group: 'Edit',
    intent: RenameSelectionIntent(),
    keys: [
      ShortcutKey(LogicalKeyboardKey.keyR, mod: true),
      ShortcutKey(LogicalKeyboardKey.f2),
    ],
  ),
  ShortcutDef(
    id: 'save',
    label: 'Save now',
    group: 'Edit',
    intent: SaveIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyS, mod: true)],
  ),
  // Selection
  ShortcutDef(
    id: 'selectAll',
    label: 'Select all',
    group: 'Selection',
    intent: SelectAllIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyA, mod: true)],
  ),
  ShortcutDef(
    id: 'selectNone',
    label: 'Select none',
    group: 'Selection',
    intent: SelectNoneIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyA, mod: true, shift: true)],
  ),
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
    id: 'selectNext',
    label: 'Select next sibling',
    group: 'Selection',
    intent: SelectSiblingIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.tab)],
  ),
  ShortcutDef(
    id: 'selectPrevious',
    label: 'Select previous sibling',
    group: 'Selection',
    intent: SelectSiblingIntent(backwards: true),
    keys: [ShortcutKey(LogicalKeyboardKey.tab, shift: true)],
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
    intent: NudgeIntent(-10, 0),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowLeft, shift: true)],
  ),
  ShortcutDef(
    id: 'nudgeRightBig',
    label: 'Nudge right by 10',
    group: 'Selection',
    intent: NudgeIntent(10, 0),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowRight, shift: true)],
  ),
  ShortcutDef(
    id: 'nudgeUpBig',
    label: 'Nudge up by 10',
    group: 'Selection',
    intent: NudgeIntent(0, -10),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowUp, shift: true)],
  ),
  ShortcutDef(
    id: 'nudgeDownBig',
    label: 'Nudge down by 10',
    group: 'Selection',
    intent: NudgeIntent(0, 10),
    keys: [ShortcutKey(LogicalKeyboardKey.arrowDown, shift: true)],
  ),
  // Arrange
  ShortcutDef(
    id: 'group',
    label: 'Group',
    group: 'Arrange',
    intent: GroupSelectionIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyG, mod: true)],
  ),
  ShortcutDef(
    id: 'ungroup',
    label: 'Ungroup',
    group: 'Arrange',
    intent: UngroupSelectionIntent(),
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
    id: 'addAutoLayout',
    label: 'Add auto layout',
    group: 'Arrange',
    intent: AddAutoLayoutIntent(),
    keys: [ShortcutKey(LogicalKeyboardKey.keyA, shift: true)],
  ),
  ShortcutDef(
    id: 'bringForward',
    label: 'Bring forward',
    group: 'Arrange',
    intent: ReorderSelectionIntent(ReorderDirection.forward),
    keys: [ShortcutKey(LogicalKeyboardKey.bracketRight, mod: true)],
  ),
  ShortcutDef(
    id: 'sendBackward',
    label: 'Send backward',
    group: 'Arrange',
    intent: ReorderSelectionIntent(ReorderDirection.backward),
    keys: [ShortcutKey(LogicalKeyboardKey.bracketLeft, mod: true)],
  ),
  ShortcutDef(
    id: 'bringToFront',
    label: 'Bring to front',
    group: 'Arrange',
    intent: ReorderSelectionIntent(ReorderDirection.front),
    keys: [ShortcutKey(LogicalKeyboardKey.bracketRight, mod: true, alt: true)],
  ),
  ShortcutDef(
    id: 'sendToBack',
    label: 'Send to back',
    group: 'Arrange',
    intent: ReorderSelectionIntent(ReorderDirection.back),
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
    id: 'toolImage',
    label: 'Place image',
    group: 'Tools',
    intent: SelectToolIntent(EditorTool.image),
    keys: [ShortcutKey(LogicalKeyboardKey.keyK, mod: true, shift: true)],
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
    keys: [
      ShortcutKey(LogicalKeyboardKey.digit0, mod: true),
      ShortcutKey(LogicalKeyboardKey.digit0, shift: true),
    ],
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
  // Help
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
      for (final k in def.keys)
        if (!(isMac && k.offMacOnly)) k.activator(mac: isMac): def.intent,
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

/// Whether [intent] fires from a key without Cmd/Ctrl, which must not
/// trigger while typing into a text field.
bool intentIsTextSensitive(Intent intent) {
  for (final d in kEditorShortcuts) {
    if (identical(d.intent, intent)) return d.keys.any((k) => k.isBare);
  }
  return false;
}

/// The document and selection intents of the table, one per type (the
/// `Actions` map is keyed by type).
Iterable<Type> get editorIntentTypes => {
  for (final d in kEditorShortcuts)
    if (d.intent is EditorIntent) d.intent.runtimeType,
};

/// True when the primary focus is inside an editable text.
bool primaryFocusIsTextInput() {
  if (primaryFocusIsStageText()) return true;
  return isTextInputFocus(FocusManager.instance.primaryFocus);
}

/// True when the primary focus is a text field of the editor's chrome (an
/// inspector field, a rename box), not the in-place text editing of the
/// canvas, which has its own handling.
bool primaryFocusIsChromeTextInput() {
  if (primaryFocusIsStageText()) return false;
  return isTextInputFocus(FocusManager.instance.primaryFocus);
}

/// Hands focus back from a chrome text field to the editor's shortcut
/// focus (a canvas or Layers pointer down), Figma-style. Leaves in-place
/// text editing and non-text focus alone. A pointer down at
/// [globalPosition] inside the focused field itself (a click that moves the
/// caret) keeps the focus.
void reclaimShortcutFocus([Offset? globalPosition]) {
  if (!primaryFocusIsChromeTextInput()) return;
  final node = FocusManager.instance.primaryFocus;
  if (node == null) return;
  if (globalPosition != null && node.rect.contains(globalPosition)) return;
  releaseFocusToAncestor(node);
}
