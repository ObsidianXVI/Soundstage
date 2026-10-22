import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// Resolves document assets to bytes (architecture §12).
///
/// Supported URI schemes:
/// - `asset://<path>` — a file bundled with the app (demo content), loaded
///   from [bundle] at `<path>`.
///
/// `local://` (IndexedDB, M1) and `https://` (published stories, M4) are
/// not wired yet; loading them throws [UnsupportedError], which the image
/// cache reports once and then paints the asset's placeholder.
class StageAssetResolver {
  StageAssetResolver({this.assets = const {}, this.customBundle});

  /// The document's asset table.
  final Map<String, ir.Asset> assets;

  /// The bundle for `asset://` URIs; null = the app's `rootBundle`.
  final AssetBundle? customBundle;

  AssetBundle get bundle => customBundle ?? rootBundle;

  /// The asset with [id], or null if the document has none.
  ir.Asset? asset(String id) => assets[id];

  /// The URI to load for [asset] when it renders [targetWidth] physical
  /// pixels wide: the smallest variant at least that wide, else the
  /// original (§6, §17.1). Without a target, the original.
  String uriFor(ir.Asset asset, {double? targetWidth}) {
    if (targetWidth == null || asset.variants.isEmpty) return asset.uri;
    ir.AssetVariant? best;
    for (final v in asset.variants) {
      if (v.width < targetWidth) continue;
      if (best == null || v.width < best.width) best = v;
    }
    if (best == null) return asset.uri;
    // The original is the largest rendition when its width is known.
    final w = asset.width;
    if (w != null && w >= targetWidth && w <= best.width) return asset.uri;
    return best.uri;
  }

  /// Loads the bytes at [uri].
  Future<Uint8List> load(String uri) async {
    final path = bundledAssetPath(uri);
    if (path != null) {
      final data = await bundle.load(path);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    throw UnsupportedError('Cannot load "$uri" yet: only asset:// is wired.');
  }
}

/// The bundle path of an `asset://<path>` URI, or null for other schemes.
String? bundledAssetPath(String uri) {
  const scheme = 'asset://';
  if (!uri.startsWith(scheme)) return null;
  return uri.substring(scheme.length);
}
