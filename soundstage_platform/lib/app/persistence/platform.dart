// Browser-only services behind a conditional import, so everything above
// this file also compiles and tests on the VM.
export 'platform_stub.dart' if (dart.library.js_interop) 'platform_web.dart';
