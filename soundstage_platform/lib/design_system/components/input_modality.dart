import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Whether the last input was the keyboard (focus rings and focus tooltips
/// show) or a pointer (they don't), like the browser's `:focus-visible`.
abstract final class SsInputModality {
  /// True after a key press, false after a pointer press.
  static final ValueNotifier<bool> keyboard = ValueNotifier<bool>(true);

  static bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent) keyboard.value = true;
    return false;
  }

  static void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) keyboard.value = false;
  }

  static Object? _router;

  /// Starts listening for input. Safe to call repeatedly; it registers again
  /// only if the underlying router or keyboard object was replaced (as
  /// between widget tests).
  static void ensureInstalled() {
    final router = GestureBinding.instance.pointerRouter;
    if (!identical(router, _router)) {
      _router = router;
      router.addGlobalRoute(_onPointer);
    }
    HardwareKeyboard.instance
      ..removeHandler(_onKey)
      ..addHandler(_onKey);
  }
}
