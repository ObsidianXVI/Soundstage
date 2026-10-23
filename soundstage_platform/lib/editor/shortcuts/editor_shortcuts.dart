import 'package:flutter/widgets.dart';

import 'shortcut_map.dart';

/// Installs the editor's shortcut table above [child]. Bind intents with
/// `Actions` below it (the shell binds the panel toggles, preview and the
/// help overlay; T1.2 binds the document commands).
class EditorShortcuts extends StatelessWidget {
  const EditorShortcuts({required this.child, this.mac, super.key});

  final Widget child;

  /// Forces the Cmd-vs-Ctrl choice (tests); defaults to the platform.
  final bool? mac;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: buildShortcutMap(mac: mac),
      child: child,
    );
  }
}

/// An action for an [EditorIntent](intents.dart) that stands down while a
/// text field has focus, if the intent fires from a bare key (so typing `v`
/// or `?` into a field never triggers a tool or the help overlay).
class EditorAction<T extends Intent> extends Action<T> {
  EditorAction(this._invoke);

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
