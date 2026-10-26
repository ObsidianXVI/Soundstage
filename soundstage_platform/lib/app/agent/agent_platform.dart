// Browser pieces of the agent client: JSON over fetch, and SVG → PNG
// through the browser's own SVG renderer (the runtime has no vector image
// support yet, m6.md T6.5).
export 'agent_platform_stub.dart'
    if (dart.library.js_interop) 'agent_platform_web.dart';
