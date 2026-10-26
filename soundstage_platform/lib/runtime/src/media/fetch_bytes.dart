import 'dart:typed_data';

import 'fetch_bytes_stub.dart'
    if (dart.library.js_interop) 'fetch_bytes_web.dart'
    as platform;

/// The bytes at an `http(s)` [url] (published assets, M4). Throws on a
/// network error or a non-2xx status.
Future<Uint8List> fetchBytes(String url) => platform.fetchBytes(url);
