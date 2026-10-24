import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/editor/core/editor_state.dart';

/// The editor's UI-only intents: tools, zoom, panels, preview, save and the
/// help overlay. The shell binds them with `Actions`.
///
/// Document and selection intents (undo, delete, group, nudge, select
/// parent, …) are `EditorIntent`s in `lib/editor/core/shortcuts.dart`;
/// `actionForIntent` turns them into commands. The keys for both live in
/// one table, [kEditorShortcuts](shortcut_map.dart).
sealed class ShellIntent extends Intent {
  const ShellIntent();
}

// -- Edit ------------------------------------------------------------------

/// Writes pending changes now (autosave flush).
class SaveIntent extends ShellIntent {
  const SaveIntent();
}

/// Cmd+C / Cmd+X / Cmd+V / Shift+Cmd+V: the clipboard (T1.9). These stand
/// down while a text field has focus, so the field copies and pastes its
/// own text.
class CopyIntent extends ShellIntent {
  const CopyIntent();
}

class CutIntent extends ShellIntent {
  const CutIntent();
}

class PasteIntent extends ShellIntent {
  const PasteIntent();
}

/// Paste over the selection ("paste to replace").
class PasteReplaceIntent extends ShellIntent {
  const PasteReplaceIntent();
}

// -- Tools -----------------------------------------------------------------
class SelectToolIntent extends ShellIntent {
  const SelectToolIntent(this.tool);
  final EditorTool tool;
}

// -- View ------------------------------------------------------------------
class ZoomInIntent extends ShellIntent {
  const ZoomInIntent();
}

class ZoomOutIntent extends ShellIntent {
  const ZoomOutIntent();
}

class ZoomTo100Intent extends ShellIntent {
  const ZoomTo100Intent();
}

class ZoomToFitIntent extends ShellIntent {
  const ZoomToFitIntent();
}

class ZoomToSelectionIntent extends ShellIntent {
  const ZoomToSelectionIntent();
}

class ToggleLeftPanelIntent extends ShellIntent {
  const ToggleLeftPanelIntent();
}

class ToggleRightPanelIntent extends ShellIntent {
  const ToggleRightPanelIntent();
}

class ToggleTimelineIntent extends ShellIntent {
  const ToggleTimelineIntent();
}

class PreviewIntent extends ShellIntent {
  const PreviewIntent();
}

class ShowShortcutHelpIntent extends ShellIntent {
  const ShowShortcutHelpIntent();
}
