// The browser's drag-and-drop of files from the desktop, behind a
// conditional import so the VM tests compile.
export 'file_drop_stub.dart' if (dart.library.js_interop) 'file_drop_web.dart';
