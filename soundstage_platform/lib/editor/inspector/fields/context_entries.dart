import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

// Nested context menus in the inspector. A right-click reaches every
// Listener under the pointer, innermost first: a field offers its entries
// ("Bind to variable…") for that pointer, and an enclosing control with a
// menu of its own (a paint row, a field's value-source menu) takes them
// into its menu. Entries nobody took open as a menu of their own once the
// event has been dispatched.

final Map<int, List<SsMenuEntry>> _offered = {};

/// Offers [entries] for the right-click [event] (see above).
void offerContextEntries(
  BuildContext context,
  PointerDownEvent event,
  List<SsMenuEntry> entries,
) {
  _offered[event.pointer] = entries;
  scheduleMicrotask(() {
    final left = _offered.remove(event.pointer);
    if (left != null && context.mounted) {
      showSsContextMenu(context, position: event.position, entries: left);
    }
  });
}

/// The entries offered for [event] by a control inside the caller, after a
/// divider; empty when there are none.
List<SsMenuEntry> takeContextEntries(PointerDownEvent event) {
  final e = _offered.remove(event.pointer);
  return e == null ? const [] : [const SsMenuDivider(), ...e];
}
