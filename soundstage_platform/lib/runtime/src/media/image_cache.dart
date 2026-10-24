import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import '../paint/stage_color.dart';
import 'asset_resolver.dart';

/// First wait before a failed image is requested again; it doubles with
/// each further failure, up to [kImageRetryMax].
const Duration kImageRetryBase = Duration(seconds: 2);

/// Longest wait between attempts at an image that keeps failing.
const Duration kImageRetryMax = Duration(minutes: 5);

/// A size-bounded LRU of decoded images (architecture §17.1).
///
/// Paint code asks for an image synchronously with [obtain]. A miss starts
/// the load once and returns null; the caller paints a placeholder and is
/// called back when the image lands. Decoded images are charged at
/// `width × height × 4` bytes. When the total exceeds [maxBytes], the least
/// recently used images are evicted and disposed. Eviction only happens
/// when a load completes, never during paint, and pictures that already drew
/// an image keep their own reference to it.
///
/// **Failures (negative cache).** A load that fails is reported once
/// ([FlutterError.reportError]) and remembered apart from the LRU, so
/// neither eviction nor [release] forgets it. Until its retry time,
/// [obtain] returns null without loading again; after it, the next
/// [obtain] tries once more, silently, and each further failure doubles the
/// wait ([kImageRetryBase] … [kImageRetryMax]). A different `version`
/// (the asset record changed, e.g. a re-upload) forgets the failure and
/// loads at once. A success forgets it too.
///
/// **Versions.** A non-null `version` is stored with the entry; [obtain]
/// with a different one drops just that entry and decodes again. The cache
/// is meant to outlive environment rebuilds (one per editor or player), so
/// adding an asset leaves every other decode alone.
class StageImageCache {
  StageImageCache({this.maxBytes = 128 << 20, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// The decoded-bytes budget.
  final int maxBytes;

  final DateTime Function() _now;

  final LinkedHashMap<String, _Entry> _entries = LinkedHashMap();
  final Map<String, _Failure> _failures = {};
  int _bytes = 0;

  /// Bytes currently held by decoded images.
  int get currentBytes => _bytes;

  /// Number of entries (loaded or loading).
  int get length => _entries.length;

  /// Whether [key] is decoded and cached.
  bool containsImage(String key) => _entries[key]?.image != null;

  /// Whether the last load of [key] failed (and no newer version replaced
  /// it).
  bool hasFailed(String key) => _failures.containsKey(key);

  /// When [key] may be loaded again after a failure, or null.
  DateTime? retryAt(String key) => _failures[key]?.retryAt;

  /// The decoded image for [key], or null while it loads (or if it failed).
  /// A miss calls [load] once; [onReady] runs when the image is available.
  /// [version] identifies what [key] stands for (see the class docs).
  ui.Image? obtain(
    String key,
    Future<ui.Image> Function() load, {
    VoidCallback? onReady,
    Object? version,
  }) {
    var hit = _entries.remove(key);
    if (hit != null && version != null && hit.version != version) {
      // What [key] stands for changed (a replaced file keeps its URI):
      // forget the old decode, keep the other entries.
      if (hit.image != null) {
        _bytes -= hit.bytes;
        hit.image!.dispose();
      }
      hit = null;
    }
    if (hit != null) {
      _entries[key] = hit; // most recently used
      if (hit.image == null && onReady != null) hit.listeners.add(onReady);
      return hit.image;
    }
    final failure = _failures[key];
    if (failure != null) {
      if (failure.version != version) {
        _failures.remove(key); // the asset changed: try it fresh
      } else if (_now().isBefore(failure.retryAt)) {
        return null;
      }
    }
    final entry = _Entry()..version = version;
    if (onReady != null) entry.listeners.add(onReady);
    _entries[key] = entry;
    load().then(
      (image) {
        if (!identical(_entries[key], entry)) {
          image.dispose(); // cleared while loading
          return;
        }
        _failures.remove(key);
        entry.image = image;
        entry.bytes = image.width * image.height * 4;
        _bytes += entry.bytes;
        _evict(keep: key);
        final listeners = List.of(entry.listeners);
        entry.listeners.clear();
        for (final l in listeners) {
          l();
        }
      },
      onError: (Object error, StackTrace stack) {
        if (!identical(_entries[key], entry)) return; // cleared while loading
        _entries.remove(key);
        entry.listeners.clear();
        final previous = _failures[key];
        final attempts = (previous?.attempts ?? 0) + 1;
        var wait = kImageRetryBase * (1 << (attempts - 1).clamp(0, 20));
        if (wait > kImageRetryMax) wait = kImageRetryMax;
        _failures[key] = _Failure(
          version: version,
          attempts: attempts,
          retryAt: _now().add(wait),
        );
        if (previous != null) return; // reported once per failing key
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'soundstage media',
            context: ErrorDescription('while loading image "$key"'),
          ),
        );
      },
    );
    return null;
  }

  /// Forgets that [key] failed, so the next [obtain] loads it at once.
  void forgetFailure(String key) => _failures.remove(key);

  /// Inserts an already decoded [image] (tests, prefetch).
  void put(String key, ui.Image image) {
    final old = _entries.remove(key);
    if (old?.image != null) {
      _bytes -= old!.bytes;
      old.image!.dispose();
    }
    final entry = _Entry()
      ..image = image
      ..bytes = image.width * image.height * 4;
    _entries[key] = entry;
    _bytes += entry.bytes;
    _evict(keep: key);
  }

  void _evict({required String keep}) {
    while (_bytes > maxBytes) {
      String? victim;
      for (final MapEntry(:key, :value) in _entries.entries) {
        if (key != keep && value.image != null) {
          victim = key;
          break;
        }
      }
      if (victim == null) return;
      final e = _entries.remove(victim)!;
      _bytes -= e.bytes;
      e.image!.dispose();
    }
  }

  /// Drops [key] (decoded or loading) and disposes its image (T0.6: the
  /// player releases images of scenes that leave the lazy window). Returns
  /// whether there was an entry.
  bool release(String key) {
    final e = _entries.remove(key);
    if (e == null) return false;
    if (e.image != null) {
      _bytes -= e.bytes;
      e.image!.dispose();
    }
    return true;
  }

  /// Disposes every cached image and forgets every failure.
  void clear() {
    for (final e in _entries.values) {
      e.image?.dispose();
    }
    _entries.clear();
    _failures.clear();
    _bytes = 0;
  }
}

class _Entry {
  Object? version;
  ui.Image? image;
  int bytes = 0;
  final List<VoidCallback> listeners = [];
}

class _Failure {
  const _Failure({
    required this.version,
    required this.attempts,
    required this.retryAt,
  });

  final Object? version;
  final int attempts;
  final DateTime retryAt;
}

/// Media access for render objects: document assets through a
/// [StageAssetResolver] and decoded images through a [StageImageCache].
class StageMedia {
  StageMedia({required this.resolver, StageImageCache? cache})
    : cache = cache ?? StageImageCache();

  final StageAssetResolver resolver;
  final StageImageCache cache;

  /// The decoded image for [assetId], picking the variant for [targetWidth]
  /// physical pixels. Null while loading, or when the asset is missing or
  /// fails to load; [onReady] runs when it becomes available.
  ///
  /// A missing asset (no record) requests nothing; document validation
  /// reports it. A failing load is reported once and retried with backoff,
  /// or at once when the asset's record changes (see [StageImageCache]).
  ui.Image? image(
    String assetId, {
    double? targetWidth,
    VoidCallback? onReady,
  }) {
    final asset = resolver.asset(assetId);
    if (asset == null) return null;
    final uri = resolver.uriFor(asset, targetWidth: targetWidth);
    return cache.obtain(
      uri,
      () => _decode(uri),
      onReady: onReady,
      version: (
        asset.id,
        uri,
        asset.mime,
        asset.byteSize,
        asset.width,
        asset.height,
      ),
    );
  }

  /// The original size of [assetId] in pixels, when the asset declares it.
  /// Used to place images and to pick variants before anything is decoded.
  ui.Size? intrinsicSize(String assetId) {
    final a = resolver.asset(assetId);
    final w = a?.width, h = a?.height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return ui.Size(w.toDouble(), h.toDouble());
  }

  /// Starts decoding [assetId] ahead of need (T0.6: scenes entering the
  /// lazy window).
  void prefetch(String assetId, {double? targetWidth}) {
    image(assetId, targetWidth: targetWidth);
  }

  /// Completes when [assetId] is decoded (now or later), or after [timeout]
  /// when it is missing, fails or is slow (the enter gate never blocks on
  /// a broken image).
  Future<void> ready(
    String assetId, {
    double? targetWidth,
    Duration timeout = const Duration(seconds: 8),
  }) {
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    if (image(assetId, targetWidth: targetWidth, onReady: finish) != null ||
        resolver.asset(assetId) == null) {
      finish();
    }
    return done.future.timeout(timeout, onTimeout: () {});
  }

  /// Releases every decoded rendition (original and variants) of [assetId]
  /// (T0.6: scenes leaving the lazy window).
  void releaseAsset(String assetId) {
    final asset = resolver.asset(assetId);
    if (asset == null) return;
    cache.release(asset.uri);
    for (final v in asset.variants) {
      cache.release(v.uri);
    }
  }

  /// The colour to paint while [assetId] loads, if the asset declares one.
  Color? placeholderColor(String assetId) {
    final c = resolver.asset(assetId)?.placeholder?.dominantColor;
    return c == null ? null : stageColor(c);
  }

  Future<ui.Image> _decode(String uri) async {
    final bytes = await resolver.load(uri);
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }
}
