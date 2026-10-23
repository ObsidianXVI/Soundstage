import 'package:flutter/widgets.dart' show Intent;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'command.dart';
import 'commands/node_commands.dart';
import 'commands/property_commands.dart';
import 'editor_state.dart';
import 'selection.dart';

// The document and selection intents of the editor and what they do
// ([actionForIntent], the single source of commands for keyboard input).
// The keys that fire them are in the one shortcut table,
// `lib/editor/shortcuts/shortcut_map.dart`; `EditorShortcuts` hosts the
// `Shortcuts`/`Actions` widgets and forwards these intents to
// `EditorController.perform`. UI-only intents (tools, zoom, panels, help)
// are in `lib/editor/shortcuts/intents.dart`.

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

/// Cmd+] / Cmd+[ (forward / backward), with Alt: to front / back.
class ReorderSelectionIntent extends EditorIntent {
  const ReorderSelectionIntent(this.direction);

  final ReorderDirection direction;
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
    ReorderSelectionIntent(:final direction) => run(
      ReorderNodes(sel, direction),
    ),
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
