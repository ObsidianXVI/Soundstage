import 'package:flutter/widgets.dart';

/// Whether [node] is the focus node of a text input (an `EditableText`).
bool isTextInputFocus(FocusNode? node) {
  final ctx = node?.context;
  // A node whose widget just unmounted (a closing popover's field) is
  // briefly still primary: not a text input any more.
  if (ctx == null || !ctx.mounted) return false;
  return ctx.widget is EditableText ||
      ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Moves focus off [node] to its nearest focusable ancestor (not the scope),
/// so key events still bubble through the same `Shortcuts` as before. Falls
/// back to a plain `unfocus` when there is none.
///
/// Used when a field commits or cancels, and when the canvas takes a pointer
/// down, so editor shortcuts (Cmd+C/V and so on) work again, Figma-style.
void releaseFocusToAncestor(FocusNode node) {
  for (final a in node.ancestors) {
    if (a is FocusScopeNode) break;
    if (a.canRequestFocus && !a.skipTraversal) {
      a.requestFocus();
      return;
    }
  }
  node.unfocus();
}
