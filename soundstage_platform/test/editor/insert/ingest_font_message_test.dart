import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';

import 'fakes.dart';

void main() {
  test('B10: a dropped font says where fonts go and is not stored', () async {
    final service = FakeAssetService();
    final report = await ingestMedia(service, [
      (name: 'Inter.ttf', bytes: Uint8List(4), mime: 'font/ttf'),
      (name: 'x.woff', bytes: Uint8List(4), mime: ''),
    ]);
    expect(service.addCount, 0);
    expect(report.problems, hasLength(2));
    for (final p in report.problems) {
      expect(p, contains('Assets → Fonts'));
    }
  });
}
