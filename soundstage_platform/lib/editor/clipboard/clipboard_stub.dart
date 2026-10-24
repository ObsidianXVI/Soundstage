import 'dart:typed_data';

/// An image on the system clipboard.
typedef ClipboardImage = ({Uint8List bytes, String mime});

/// Reads an image from the system clipboard; null when there is none or
/// the browser cannot (no browser here).
Future<ClipboardImage?> readClipboardImage() async => null;
