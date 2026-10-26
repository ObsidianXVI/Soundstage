import 'dart:typed_data';

/// An HTTP request with a JSON body; returns the status and body text.
Future<(int, String)> sendJson(
  String method,
  String url, {
  Map<String, String> headers = const {},
  String? body,
}) async => throw UnsupportedError('The agent needs a browser.');

/// [svg] drawn into a [width] × [height] PNG.
Future<Uint8List> rasterizeSvg(String svg, int width, int height) async =>
    throw UnsupportedError('The agent needs a browser.');

/// A per-browser setting (null when unavailable).
String? readSetting(String key) => null;

void writeSetting(String key, String value) {}
