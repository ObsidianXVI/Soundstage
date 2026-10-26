import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// An HTTP request with a JSON body; returns the status and body text.
Future<(int, String)> sendJson(
  String method,
  String url, {
  Map<String, String> headers = const {},
  String? body,
}) async {
  final h = web.Headers();
  headers.forEach((k, v) => h.set(k, v));
  if (body != null) h.set('content-type', 'application/json');
  final res = await web.window
      .fetch(
        url.toJS,
        web.RequestInit(method: method, headers: h, body: body?.toJS),
      )
      .toDart;
  final text = (await res.text().toDart).toDart;
  return (res.status, text);
}

/// [svg] drawn into a [width] × [height] PNG by the browser.
Future<Uint8List> rasterizeSvg(String svg, int width, int height) async {
  final blob = web.Blob(
    [svg.toJS].toJS,
    web.BlobPropertyBag(type: 'image/svg+xml'),
  );
  final url = web.URL.createObjectURL(blob);
  try {
    final img = web.HTMLImageElement()
      ..width = width
      ..height = height
      ..src = url;
    await img.decode().toDart;
    final canvas = web.HTMLCanvasElement()
      ..width = width
      ..height = height;
    final ctx = canvas.getContext('2d')! as web.CanvasRenderingContext2D;
    ctx.drawImage(img, 0, 0, width, height);
    final done = Completer<web.Blob?>();
    canvas.toBlob(
      ((web.Blob? b) => done.complete(b)).toJS,
      'image/png',
    );
    final png = await done.future;
    if (png == null) throw StateError('The illustration could not be drawn.');
    final buffer = await png.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } finally {
    web.URL.revokeObjectURL(url);
  }
}

/// A per-browser setting (null when storage is blocked).
String? readSetting(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } on Object {
    return null;
  }
}

void writeSetting(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } on Object {
    // private window or blocked storage: the defaults apply next time
  }
}
