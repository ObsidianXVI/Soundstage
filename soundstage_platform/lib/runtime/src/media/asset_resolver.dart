import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// Resolves document assets to bytes (architecture §12).
///
/// Supported URI schemes:
/// - `asset://<path>` — a file bundled with the app (demo content), loaded
///   from [bundle] at `<path>`.
/// - `local://<id>` — a file in the editor's browser storage (IndexedDB),
///   loaded through [local]. The app installs the loader once at start-up
///   ([defaultLocal]); a missing file throws [StateError].
///
/// `https://` (published stories, M4) is not wired yet; loading it throws
/// [UnsupportedError], which the image cache reports once and then paints
/// the asset's placeholder.
class StageAssetResolver {
  StageAssetResolver({this.assets = const {}, this.customBundle, this._local});

  /// The loader for `local://` URIs of every resolver that is not given its
  /// own. Set by the app when browser storage opens.
  static LocalAssetLoader? defaultLocal;

  final LocalAssetLoader? _local;

  /// The loader used for `local://` URIs, if any.
  LocalAssetLoader? get local => _local ?? defaultLocal;

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
    final localId = localAssetId(uri);
    if (localId != null) {
      final loader = local;
      if (loader == null) {
        throw UnsupportedError('No local asset storage for "$uri".');
      }
      final bytes = await loader.loadBytes(localId);
      if (bytes == null) throw StateError('Local asset "$localId" is missing.');
      return bytes;
    }
    throw UnsupportedError(
      'Cannot load "$uri" yet: only asset:// and local:// are wired.',
    );
  }
}

/// The bundle path of an `asset://<path>` URI, or null for other schemes.
String? bundledAssetPath(String uri) {
  const scheme = 'asset://';
  if (!uri.startsWith(scheme)) return null;
  return uri.substring(scheme.length);
}

/// The id in a `local://<id>` URI, or null for other schemes.
String? localAssetId(String uri) {
  const scheme = 'local://';
  if (!uri.startsWith(scheme)) return null;
  return uri.substring(scheme.length);
}

/// Where `local://` assets live (the editor's IndexedDB store).
abstract interface class LocalAssetLoader {
  /// The file's bytes, or null if there is no such asset.
  Future<Uint8List?> loadBytes(String assetId);

  /// A browser object URL for the file (for media elements that cannot take
  /// bytes), or null if there is no such asset. Each call must be paired
  /// with [releaseObjectUrl]; the URL is revoked when the last holder
  /// releases it.
  Future<String?> acquireObjectUrl(String assetId);

  void releaseObjectUrl(String assetId);
}
