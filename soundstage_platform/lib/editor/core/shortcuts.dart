import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart'
    show Intent, ShortcutActivator, SingleActivator;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'command.dart';
import 'commands/node_commands.dart';
import 'commands/property_commands.dart';
import 'editor_state.dart';
import 'selection.dart';

// Command-level keyboard shortcuts (Figma's bindings). Pure intent →
// action mappings: the shell hosts the `Shortcuts`/`Actions` widgets with
// [editorShortcuts] and forwards intents to `EditorController.perform`.
// Text editing and canvas tools (V, F, T, …) bind in the shell.

/// A keyboard intent of the editor.
sealed class EditorIntent extends Intent {
  const EditorIntent();
}

class UndoIntent extends EditorIntent {
  const UndoIntent();
}

class RedoIntent extends EditorIntent {
  const RedoIntent();
}

class DeleteSelectionIntent extends EditorIntent {
  const DeleteSelectionIntent();
}

class DuplicateSelectionIntent extends EditorIntent {
  const DuplicateSelectionIntent();
}

/// Cmd+G: wrap the selection in a transparent "Group" frame.
class GroupSelectionIntent extends EditorIntent {
  const GroupSelectionIntent();
}

/// Cmd+Alt+G: wrap the selection in a frame.
class FrameSelectionIntent extends EditorIntent {
  const FrameSelectionIntent();
}

/// Cmd+Shift+G: ungroup (unwrap) the selected frames.
class UngroupSelectionIntent extends EditorIntent {
  const UngroupSelectionIntent();
}

/// Shift+A.
class AddAutoLayoutIntent extends EditorIntent {
  const AddAutoLayoutIntent();
}

/// Arrows (Shift: ×10).
class NudgeIntent extends EditorIntent {
  const NudgeIntent(this.dx, this.dy);

  final double dx, dy;
}

class SelectAllIntent extends EditorIntent {
  const SelectAllIntent();
}

class SelectNoneIntent extends EditorIntent {
  const SelectNoneIntent();
}

/// Cmd+R: start renaming the selected layer (a UI action).
class RenameSelectionIntent extends EditorIntent {
  const RenameSelectionIntent();
}

/// Cmd+Shift+H.
class ToggleVisibilityIntent extends EditorIntent {
  const ToggleVisibilityIntent();
}

/// Cmd+Shift+L.
class ToggleLockIntent extends EditorIntent {
  const ToggleLockIntent();
}

/// Esc.
class SelectParentIntent extends EditorIntent {
  const SelectParentIntent();
}

/// Enter.
class SelectChildrenIntent extends EditorIntent {
  const SelectChildrenIntent();
}

/// Tab / Shift-Tab.
class SelectSiblingIntent extends EditorIntent {
  const SelectSiblingIntent({this.backwards = false});

  final bool backwards;
}

/// What an intent does in a given state.
sealed class EditorAction {
  const EditorAction();
}

class RunCommand extends EditorAction {
  const RunCommand(this.command);

  final EditCommand command;
}

class UndoAction extends EditorAction {
  const UndoAction();
}

class RedoAction extends EditorAction {
  const RedoAction();
}

class ApplySelection extends EditorAction {
  const ApplySelection(this.selection);

  final SelectionState selection;
}

/// The shell opens the rename field for [nodeId].
class BeginRename extends EditorAction {
  const BeginRename(this.nodeId);

  final String nodeId;
}

/// The intent does nothing here (e.g. delete with nothing selected).
class NoAction extends EditorAction {
  const NoAction();
}

/// The shortcut map. [apple]: Cmd on macOS, Ctrl elsewhere (where redo
/// also answers to Ctrl+Y).
///
/// Select none is Cmd+Shift+A (Illustrator's "Deselect"; Figma has no
/// default binding). Nudge by 10 is Shift+arrow.
Map<ShortcutActivator, EditorIntent> editorShortcuts({required bool apple}) {
  SingleActivator cmd(
    LogicalKeyboardKey key, {
    bool shift = false,
    bool alt = false,
  }) => SingleActivator(
    key,
    meta: apple,
    control: !apple,
    shift: shift,
    alt: alt,
  );

  return {
    cmd(LogicalKeyboardKey.keyZ): const UndoIntent(),
    cmd(LogicalKeyboardKey.keyZ, shift: true): const RedoIntent(),
    if (!apple)
      const SingleActivator(LogicalKeyboardKey.keyY, control: true):
          const RedoIntent(),
    const SingleActivator(LogicalKeyboardKey.delete):
        const DeleteSelectionIntent(),
    const SingleActivator(LogicalKeyboardKey.backspace):
        const DeleteSelectionIntent(),
    cmd(LogicalKeyboardKey.keyD): const DuplicateSelectionIntent(),
    cmd(LogicalKeyboardKey.keyG): const GroupSelectionIntent(),
    cmd(LogicalKeyboardKey.keyG, alt: true): const FrameSelectionIntent(),
    cmd(LogicalKeyboardKey.keyG, shift: true): const UngroupSelectionIntent(),
    const SingleActivator(LogicalKeyboardKey.keyA, shift: true):
        const AddAutoLayoutIntent(),
    const SingleActivator(LogicalKeyboardKey.arrowLeft): const NudgeIntent(
      -1,
      0,
    ),
    const SingleActivator(LogicalKeyboardKey.arrowRight): const NudgeIntent(
      1,
      0,
    ),
    const SingleActivator(LogicalKeyboardKey.arrowUp): const NudgeIntent(0, -1),
    const SingleActivator(LogicalKeyboardKey.arrowDown): const NudgeIntent(
      0,
      1,
    ),
    const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
        const NudgeIntent(-10, 0),
    const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
        const NudgeIntent(10, 0),
    const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
        const NudgeIntent(0, -10),
    const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
        const NudgeIntent(0, 10),
    cmd(LogicalKeyboardKey.keyA): const SelectAllIntent(),
    cmd(LogicalKeyboardKey.keyA, shift: true): const SelectNoneIntent(),
    cmd(LogicalKeyboardKey.keyR): const RenameSelectionIntent(),
    cmd(LogicalKeyboardKey.keyH, shift: true): const ToggleVisibilityIntent(),
    cmd(LogicalKeyboardKey.keyL, shift: true): const ToggleLockIntent(),
    const SingleActivator(LogicalKeyboardKey.escape):
        const SelectParentIntent(),
    const SingleActivator(LogicalKeyboardKey.enter):
        const SelectChildrenIntent(),
    const SingleActivator(LogicalKeyboardKey.tab): const SelectSiblingIntent(),
    const SingleActivator(LogicalKeyboardKey.tab, shift: true):
        const SelectSiblingIntent(backwards: true),
  };
}

/// What [intent] does in [state]. [tree] is the active scene's
/// [SelectionTree] (needed by the selection intents; without it they do
/// nothing).
EditorAction actionForIntent(
  EditorIntent intent,
  EditorState state, {
  SelectionTree? tree,
}) {
  final sel = state.selection.toList();
  final current = SelectionState(
    selection: state.selection,
    context: state.selectionContext,
    textEditId: state.textEditId,
  );
  EditorAction run(EditCommand c) =>
      sel.isEmpty ? const NoAction() : RunCommand(c);
  EditorAction select(SelectionState Function(SelectionTree t) rule) =>
      tree == null ? const NoAction() : ApplySelection(rule(tree));
  final index = ir.DocumentIndex.of(state.document);
  bool baseFlag(bool Function(ir.NodeCommon c) f) => sel.any((id) {
    final n = index.node(id);
    return n != null && f(n.common);
  });
  return switch (intent) {
    UndoIntent() => const UndoAction(),
    RedoIntent() => const RedoAction(),
    DeleteSelectionIntent() => run(DeleteNodes(sel)),
    DuplicateSelectionIntent() => run(DuplicateNodes(sel)),
    GroupSelectionIntent() => run(WrapInFrame(sel, group: true)),
    FrameSelectionIntent() => run(WrapInFrame(sel)),
    UngroupSelectionIntent() => run(UnwrapFrame(sel)),
    AddAutoLayoutIntent() => run(AddAutoLayout(sel)),
    NudgeIntent(:final dx, :final dy) => run(NudgeNodes(sel, dx, dy)),
    SelectAllIntent() => select((t) => selectAll(t, current)),
    SelectNoneIntent() => ApplySelection(selectNone(current)),
    RenameSelectionIntent() =>
      sel.length == 1 ? BeginRename(sel.single) : const NoAction(),
    // Figma: hide when any selected layer is visible, else show.
    ToggleVisibilityIntent() => run(
      SetVisible(sel, !baseFlag((c) => c.visible)),
    ),
    // Lock when any selected layer is unlocked, else unlock.
    ToggleLockIntent() => run(SetLocked(sel, baseFlag((c) => !c.locked))),
    SelectParentIntent() => select((t) => selectParent(t, current)),
    SelectChildrenIntent() => select((t) => selectChildren(t, current)),
    SelectSiblingIntent(:final backwards) => select(
      (t) => selectSibling(t, current, backwards: backwards),
    ),
  };
}
