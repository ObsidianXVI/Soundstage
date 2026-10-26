import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Rich text to put on the clipboard.
typedef RichClip = ({String html, String plain});

/// Writes [content] to the clipboard as `text/html` and `text/plain`.
///
/// Call it straight from the click: the clipboard item is created at once
/// with promises of the two parts, so the browser keeps the user gesture
/// while [content] is still being built (Safari needs this).
Future<void> copyRichText(Future<RichClip> content) async {
  JSPromise<web.Blob> part(String Function(RichClip) pick, String type) =>
      content
          .then(
            (c) =>
                web.Blob([pick(c).toJS].toJS, web.BlobPropertyBag(type: type)),
          )
          .toJS;
  final items = JSObject()
    ..setProperty('text/html'.toJS, part((c) => c.html, 'text/html'))
    ..setProperty('text/plain'.toJS, part((c) => c.plain, 'text/plain'));
  await web.window.navigator.clipboard
      .write([web.ClipboardItem(items)].toJS)
      .toDart;
}
