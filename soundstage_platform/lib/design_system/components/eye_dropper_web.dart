import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui';

import 'color_math.dart';

@JS('EyeDropper')
extension type _EyeDropper._(JSObject _) implements JSObject {
  external _EyeDropper();
  external JSPromise<_EyeDropperResult> open();
}

extension type _EyeDropperResult._(JSObject _) implements JSObject {
  external String get sRGBHex;
}

/// Whether the browser's EyeDropper API exists (Chromium; not Firefox or
/// Safari). Feature-detected, never assumed.
bool get eyeDropperSupported => globalContext.has('EyeDropper');

/// Opens the screen eyedropper; null when unsupported or cancelled.
Future<Color?> pickScreenColor() async {
  if (!eyeDropperSupported) return null;
  try {
    final result = await _EyeDropper().open().toDart;
    return parseHexColor(result.sRGBHex);
  } on Object {
    return null; // The user pressed Escape.
  }
}
