import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Publishes a debug value as `window[name]` (`?stats=1` measurements read
/// the story's scroll offset this way).
void publishDebugValue(String name, double value) {
  globalContext.setProperty(name.toJS, value.toJS);
}
