@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

void main() {
  test('https-scheme assets load over the network; errors throw', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      if (r.uri.path == '/a.bin') {
        r.response.add([1, 2, 3]);
      } else {
        r.response.statusCode = 404;
      }
      r.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final resolver = StageAssetResolver();
    expect(await resolver.load('$base/a.bin'), [1, 2, 3]);
    await expectLater(resolver.load('$base/missing'), throwsStateError);
    await expectLater(resolver.load('ftp://x/y'), throwsUnsupportedError);
    await server.close(force: true);
  });
}
