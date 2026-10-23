import 'package:flutter/widgets.dart';

/// The editor's command intents. T1.1 defines them and the keys that fire
/// them; T1.2 binds the ones that act on the document with `Actions`.
///
/// Only [ShowShortcutHelpIntent], the panel toggles and [PreviewIntent] are
/// handled by the shell today.
sealed class EditorIntent extends Intent {
  const EditorIntent();
}

// -- Edit ------------------------------------------------------------------
class UndoIntent extends EditorIntent {
  const UndoIntent();
}

class RedoIntent extends EditorIntent {
  const RedoIntent();
}

class CopyNodesIntent extends EditorIntent {
  const CopyNodesIntent();
}

class CutNodesIntent extends EditorIntent {
  const CutNodesIntent();
}

class PasteNodesIntent extends EditorIntent {
  const PasteNodesIntent();
}

class DuplicateIntent extends EditorIntent {
  const DuplicateIntent();
}

class DeleteNodesIntent extends EditorIntent {
  const DeleteNodesIntent();
}

class SelectAllIntent extends EditorIntent {
  const SelectAllIntent();
}

class SelectParentIntent extends EditorIntent {
  const SelectParentIntent();
}

class SelectChildrenIntent extends EditorIntent {
  const SelectChildrenIntent();
}

class RenameIntent extends EditorIntent {
  const RenameIntent();
}

class SaveIntent extends EditorIntent {
  const SaveIntent();
}

/// Arrow-key nudge of the selection by [dx]/[dy] design pixels (10 with
/// Shift).
class NudgeIntent extends EditorIntent {
  const NudgeIntent(this.dx, this.dy, {this.large = false});

  final int dx;
  final int dy;
  final bool large;
}

// -- Structure -------------------------------------------------------------
class GroupIntent extends EditorIntent {
  const GroupIntent();
}

class UngroupIntent extends EditorIntent {
  const UngroupIntent();
}

class FrameSelectionIntent extends EditorIntent {
  const FrameSelectionIntent();
}

class BringForwardIntent extends EditorIntent {
  const BringForwardIntent({this.toFront = false});
  final bool toFront;
}

class SendBackwardIntent extends EditorIntent {
  const SendBackwardIntent({this.toBack = false});
  final bool toBack;
}

class ToggleVisibilityIntent extends EditorIntent {
  const ToggleVisibilityIntent();
}

class ToggleLockIntent extends EditorIntent {
  const ToggleLockIntent();
}

// -- Tools -----------------------------------------------------------------
enum EditorTool { move, frame, text, rectangle, ellipse, line, hand }

class SelectToolIntent extends EditorIntent {
  const SelectToolIntent(this.tool);
  final EditorTool tool;
}

// -- View ------------------------------------------------------------------
class ZoomInIntent extends EditorIntent {
  const ZoomInIntent();
}

class ZoomOutIntent extends EditorIntent {
  const ZoomOutIntent();
}

class ZoomTo100Intent extends EditorIntent {
  const ZoomTo100Intent();
}

class ZoomToFitIntent extends EditorIntent {
  const ZoomToFitIntent();
}

class ZoomToSelectionIntent extends EditorIntent {
  const ZoomToSelectionIntent();
}

class ToggleLeftPanelIntent extends EditorIntent {
  const ToggleLeftPanelIntent();
}

class ToggleRightPanelIntent extends EditorIntent {
  const ToggleRightPanelIntent();
}

class ToggleTimelineIntent extends EditorIntent {
  const ToggleTimelineIntent();
}

class PreviewIntent extends EditorIntent {
  const PreviewIntent();
}

class ShowShortcutHelpIntent extends EditorIntent {
  const ShowShortcutHelpIntent();
}
