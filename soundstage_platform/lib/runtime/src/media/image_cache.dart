import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import '../paint/stage_color.dart';
import 'asset_resolver.dart';

/// A size-bounded LRU of decoded images (architecture §17.1).
///
/// Paint code asks for an image synchronously with [obtain]. A miss starts
/// the load once and returns null; the caller paints a placeholder and is
/// called back when the image lands. Decoded images are charged at
/// `width × height × 4` bytes. When the total exceeds [maxBytes], the least
/// recently used images are evicted and disposed. Eviction only happens
/// when a load completes, never during paint, and pictures that already drew
/// an image keep their own reference to it.
class StageImageCache {
  StageImageCache({this.maxBytes = 128 << 20});

  /// The decoded-bytes budget.
  final int maxBytes;

  final LinkedHashMap<String, _Entry> _entries = LinkedHashMap();
  int _bytes = 0;

  /// Bytes currently held by decoded images.
  int get currentBytes => _bytes;

  /// Number of entries (loaded, loading or failed).
  int get length => _entries.length;

  /// Whether [key] is decoded and cached.
  bool containsImage(String key) => _entries[key]?.image != null;

  /// The decoded image for [key], or null while it loads (or if it failed).
  /// A miss calls [load] once; [onReady] runs when the image is available.
  ui.Image? obtain(
    String key,
    Future<ui.Image> Function() load, {
    VoidCallback? onReady,
  }) {
    final hit = _entries.remove(key);
    if (hit != null) {
      _entries[key] = hit; // most recently used
      if (hit.image == null && !hit.failed && onReady != null) {
        hit.listeners.add(onReady);
      }
      return hit.image;
    }
    final entry = _Entry();
    if (onReady != null) entry.listeners.add(onReady);
    _entries[key] = entry;
    load().then(
      (image) {
        if (!identical(_entries[key], entry)) {
          image.dispose(); // cleared while loading
          return;
        }
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
        entry.failed = true;
        entry.listeners.clear();
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

  /// Disposes every cached image.
  void clear() {
    for (final e in _entries.values) {
      e.image?.dispose();
    }
    _entries.clear();
    _bytes = 0;
  }
}

class _Entry {
  ui.Image? image;
  int bytes = 0;
  bool failed = false;
  final List<VoidCallback> listeners = [];
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
  ui.Image? image(
    String assetId, {
    double? targetWidth,
    VoidCallback? onReady,
  }) {
    final asset = resolver.asset(assetId);
    if (asset == null) return null;
    final uri = resolver.uriFor(asset, targetWidth: targetWidth);
    return cache.obtain(uri, () => _decode(uri), onReady: onReady);
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
