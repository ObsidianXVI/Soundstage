import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

Future<Uint8List> fetchBytes(String url) async {
  final response = await web.window.fetch(url.toJS).toDart;
  if (!response.ok) {
    throw StateError('GET $url: HTTP ${response.status}');
  }
  final buffer = await response.arrayBuffer().toDart;
  return buffer.toDart.asUint8List();
}
