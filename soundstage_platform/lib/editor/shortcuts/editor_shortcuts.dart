import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/editor/core/shortcuts.dart';

import 'shortcut_map.dart';

/// Installs the editor's one shortcut table ([kEditorShortcuts]) above
/// [child], with its `Actions`:
///
/// - every document and selection intent (`EditorIntent`) goes to
///   [onEditorIntent], normally `EditorController.perform`, so
///   `actionForIntent` stays the single source of commands;
/// - UI intents (tools, zoom, panels, preview, help) are bound by the
///   caller in [actions].
///
/// Every action stands down while a text field has focus if its key has no
/// Cmd/Ctrl (so typing `v`, `?` or Backspace into a field never triggers a
/// tool, the help overlay or a delete).
class EditorShortcuts extends StatelessWidget {
  const EditorShortcuts({
    required this.child,
    this.onEditorIntent,
    this.actions = const {},
    this.mac,
    super.key,
  });

  final Widget child;

  /// Receives the table's `EditorIntent`s; null leaves them unbound.
  final void Function(EditorIntent intent)? onEditorIntent;

  /// Actions for the UI intents, by intent type.
  final Map<Type, Action<Intent>> actions;

  /// Forces the Cmd-vs-Ctrl choice (tests); defaults to the platform.
  final bool? mac;

  @override
  Widget build(BuildContext context) {
    final forward = onEditorIntent;
    return Shortcuts(
      shortcuts: buildShortcutMap(mac: mac),
      child: Actions(
        actions: <Type, Action<Intent>>{
          if (forward != null)
            for (final type in editorIntentTypes)
              type: EditorShortcutAction<EditorIntent>(forward),
          ...actions,
        },
        child: child,
      ),
    );
  }
}

/// An action for an intent of the shortcut table that stands down while a
/// text field has focus, if the intent fires from a key without Cmd/Ctrl.
class EditorShortcutAction<T extends Intent> extends Action<T> {
  EditorShortcutAction(this._invoke);

  final void Function(T intent) _invoke;

  @override
  bool isEnabled(T intent) =>
      !(intentIsTextSensitive(intent) && primaryFocusIsTextInput());

  @override
  Object? invoke(T intent) {
    _invoke(intent);
    return null;
  }
}
