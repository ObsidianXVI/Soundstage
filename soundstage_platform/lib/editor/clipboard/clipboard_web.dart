import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'system_clipboard.dart' show ClipboardDenied;

/// An image on the system clipboard.
typedef ClipboardImage = ({Uint8List bytes, String mime});

/// Reads an image from the system clipboard through the async Clipboard
/// API (`navigator.clipboard.read()`), feature-detected: null where the
/// browser lacks it or the clipboard holds no image. Throws
/// [ClipboardDenied] when the browser refuses the read (no permission, or
/// not in a user gesture).
Future<ClipboardImage?> readClipboardImage() async {
  final clipboard = web.window.navigator.clipboard;
  if (!(clipboard as JSObject).hasProperty('read'.toJS).toDart) return null;
  try {
    final items = (await clipboard.read().toDart).toDart;
    for (final item in items) {
      for (final type in item.types.toDart) {
        final mime = type.toDart;
        if (!mime.startsWith('image/')) continue;
        final blob = await item.getType(mime).toDart;
        final buffer = await blob.arrayBuffer().toDart;
        return (bytes: buffer.toDart.asUint8List(), mime: mime);
      }
    }
    return null;
  } on Object {
    throw const ClipboardDenied();
  }
}
