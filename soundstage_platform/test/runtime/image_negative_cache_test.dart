import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// A bundle without any file: every load fails.
class _EmptyBundle extends CachingAssetBundle {
  int loads = 0;

  @override
  Future<ByteData> load(String key) async {
    loads++;
    throw FlutterError('No asset "$key"');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<FlutterErrorDetails> reports;
  late FlutterExceptionHandler? previous;
  setUp(() {
    reports = [];
    previous = FlutterError.onError;
    FlutterError.onError = reports.add;
  });
  tearDown(() => FlutterError.onError = previous);

  group('StageImageCache failures (negative cache)', () {
    test('a failed load is reported once and not requested again '
        'before its retry time', () async {
      var now = DateTime(2026);
      final cache = StageImageCache(now: () => now);
      var loads = 0;
      Future<ui.Image> load() async {
        loads++;
        throw StateError('missing');
      }

      expect(cache.obtain('k', load), isNull);
      await pumpEventQueue();
      expect(loads, 1);
      expect(reports, hasLength(1));
      expect(cache.hasFailed('k'), isTrue);
      expect(cache.retryAt('k'), now.add(kImageRetryBase));

      // Every frame asks again: nothing is loaded, nothing reported.
      for (var i = 0; i < 60; i++) {
        expect(cache.obtain('k', load), isNull);
      }
      await pumpEventQueue();
      expect(loads, 1);
      expect(reports, hasLength(1));

      // Released (a scene left the window): the failure is remembered.
      cache.release('k');
      expect(cache.obtain('k', load), isNull);
      await pumpEventQueue();
      expect(loads, 1);
    });

    test('retries back off exponentially up to the cap, silently', () async {
      var now = DateTime(2026);
      final cache = StageImageCache(now: () => now);
      var loads = 0;
      Future<ui.Image> load() async {
        loads++;
        throw StateError('missing');
      }

      cache.obtain('k', load);
      await pumpEventQueue();
      final waits = <Duration>[];
      for (var i = 0; i < 12; i++) {
        final at = cache.retryAt('k')!;
        waits.add(at.difference(now));
        now = at;
        cache.obtain('k', load);
        await pumpEventQueue();
      }
      expect(loads, 13);
      expect(reports, hasLength(1));
      expect(waits.take(4), [
        kImageRetryBase,
        kImageRetryBase * 2,
        kImageRetryBase * 4,
        kImageRetryBase * 8,
      ]);
      expect(waits.last, kImageRetryMax);
    });

    test('a new version (asset changed) retries at once; success forgets '
        'the failure', () async {
      final now = DateTime(2026);
      final cache = StageImageCache(now: () => now);
      final image = await createTestImage(width: 2, height: 2);
      var fail = true;
      var loads = 0;
      Future<ui.Image> load() async {
        loads++;
        if (fail) throw StateError('missing');
        return image;
      }

      cache.obtain('k', load, version: 'v1');
      await pumpEventQueue();
      cache.obtain('k', load, version: 'v1');
      await pumpEventQueue();
      expect(loads, 1);

      fail = false;
      var ready = 0;
      expect(
        cache.obtain('k', load, version: 'v2', onReady: () => ready++),
        isNull,
      );
      await pumpEventQueue();
      expect(loads, 2);
      expect(ready, 1);
      expect(cache.hasFailed('k'), isFalse);
      expect(cache.obtain('k', load, version: 'v2'), isNotNull);
      cache.clear();
    });
  });

  group('StageMedia', () {
    test('a failing asset is loaded once while painting repeatedly, and '
        'again when its record changes', () async {
      final bundle = _EmptyBundle();
      const asset = ir.Asset(
        id: 'img',
        kind: ir.AssetKind.image,
        uri: 'asset://nope.png',
      );
      var media = StageMedia(
        resolver: StageAssetResolver(
          assets: const {'img': asset},
          customBundle: bundle,
        ),
      );
      final cache = media.cache;
      for (var i = 0; i < 30; i++) {
        expect(media.image('img'), isNull);
        await pumpEventQueue();
      }
      expect(bundle.loads, 1);
      expect(reports, hasLength(1));

      // The asset is replaced (e.g. re-uploaded with new metadata).
      media = StageMedia(
        resolver: StageAssetResolver(
          assets: {'img': asset.copyWith(width: 10, height: 10)},
          customBundle: bundle,
        ),
        cache: cache,
      );
      expect(media.image('img'), isNull);
      await pumpEventQueue();
      expect(bundle.loads, 2);
      // A new failure of a changed asset is a new report.
      expect(reports, hasLength(2));
    });

    test('a missing asset requests nothing', () {
      final media = StageMedia(resolver: StageAssetResolver());
      expect(media.image('none'), isNull);
      expect(media.cache.length, 0);
      expect(reports, isEmpty);
    });
  });
}
