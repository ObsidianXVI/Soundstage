// The browser's async Clipboard API for images, behind a conditional import
// so the VM tests compile.
export 'clipboard_stub.dart' if (dart.library.js_interop) 'clipboard_web.dart';
