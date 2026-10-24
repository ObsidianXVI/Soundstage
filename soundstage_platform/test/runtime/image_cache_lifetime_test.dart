import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _CountingBundle extends CachingAssetBundle {
  final Map<String, int> loads = {};

  @override
  Future<ByteData> load(String key) async {
    loads[key] = (loads[key] ?? 0) + 1;
    return ByteData.sublistView(_png);
  }
}

ir.Asset _asset(String id, {int byteSize = 1}) => ir.Asset(
  id: id,
  kind: ir.AssetKind.image,
  uri: 'asset://$id.png',
  byteSize: byteSize,
);

Future<void> _settle(WidgetTester t) =>
    t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  StageMedia mediaOf(
    _CountingBundle bundle,
    StageImageCache cache,
    Map<String, ir.Asset> assets,
  ) => StageMedia(
    resolver: StageAssetResolver(assets: assets, customBundle: bundle),
    cache: cache,
  );

  testWidgets('adding an asset does not decode the others again', (t) async {
    final bundle = _CountingBundle();
    final cache = StageImageCache();

    var m = mediaOf(bundle, cache, {'a': _asset('a')});
    m.image('a');
    await _settle(t);
    expect(m.image('a'), isNotNull);
    expect(bundle.loads, {'a.png': 1});

    // The environment is rebuilt with one more asset.
    m = mediaOf(bundle, cache, {'a': _asset('a'), 'b': _asset('b')});
    expect(m.image('a'), isNotNull, reason: 'still decoded, no flash');
    m.image('b');
    await _settle(t);
    expect(bundle.loads, {'a.png': 1, 'b.png': 1});
  });

  testWidgets('a replaced asset invalidates only its own entry', (t) async {
    final bundle = _CountingBundle();
    final cache = StageImageCache();

    var m = mediaOf(bundle, cache, {'a': _asset('a'), 'b': _asset('b')});
    m
      ..image('a')
      ..image('b');
    await _settle(t);
    expect(bundle.loads, {'a.png': 1, 'b.png': 1});

    m = mediaOf(bundle, cache, {
      'a': _asset('a', byteSize: 99),
      'b': _asset('b'),
    });
    expect(m.image('b'), isNotNull);
    expect(m.image('a'), isNull, reason: 'old decode dropped');
    await _settle(t);
    expect(m.image('a'), isNotNull);
    expect(bundle.loads, {'a.png': 2, 'b.png': 1});
  });
}
