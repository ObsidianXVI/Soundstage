import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../insert/asset_service.dart';
import 'clipboard_platform.dart' as platform;

/// The browser refused to read the clipboard (permission denied, or the
/// read was not in response to a user gesture).
class ClipboardDenied implements Exception {
  const ClipboardDenied();

  @override
  String toString() => 'Clipboard access was denied.';
}

/// The system clipboard as the editor uses it: text (carrying the
/// Soundstage envelope or plain text) and images. Swappable for tests.
abstract interface class SystemClipboard {
  Future<void> writeText(String text);

  /// The text on the clipboard, or null. Throws [ClipboardDenied].
  Future<String?> readText();

  /// An image on the clipboard, or null (none, or the browser cannot read
  /// images: feature-detected). Throws [ClipboardDenied].
  Future<EditorFile?> readImage();
}

/// The browser's clipboard: Flutter's text clipboard plus the async
/// Clipboard API for images.
class BrowserClipboard implements SystemClipboard {
  const BrowserClipboard();

  @override
  Future<void> writeText(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on Object {
      throw const ClipboardDenied();
    }
  }

  @override
  Future<String?> readText() async {
    try {
      return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } on Object {
      throw const ClipboardDenied();
    }
  }

  @override
  Future<EditorFile?> readImage() async {
    final img = await platform.readClipboardImage();
    return img == null
        ? null
        : (name: 'Pasted image', bytes: img.bytes, mime: img.mime);
  }
}

final systemClipboardProvider = Provider<SystemClipboard>(
  (ref) => const BrowserClipboard(),
);
