import 'dart:typed_data';

import 'package:soundstage_platform/editor/audio/waveform_peaks.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart' show LocalAssetLoader;

import 'platform.dart' as platform;
import 'records.dart';
import 'story_database.dart';

/// Decodes a file for its intrinsic size, duration and dominant colour.
abstract interface class AssetAnalyzer {
  Future<AssetAnalysis> analyze(Uint8List bytes, String mime);
}

/// Decodes in the browser (`createImageBitmap`, a canvas downsample,
/// media-element metadata).
class BrowserAssetAnalyzer implements AssetAnalyzer {
  const BrowserAssetAnalyzer();

  @override
  Future<AssetAnalysis> analyze(Uint8List bytes, String mime) =>
      platform.analyzeInBrowser(bytes, mime);
}

/// Decodes audio into waveform peaks (null when it cannot).
typedef PeaksDecoder = Future<WaveformPeaks?> Function(Uint8List bytes);

/// Creates and revokes browser object URLs.
abstract interface class ObjectUrlFactory {
  String create(Uint8List bytes, String mime);
  void revoke(String url);
}

class BrowserObjectUrls implements ObjectUrlFactory {
  const BrowserObjectUrls();

  @override
  String create(Uint8List bytes, String mime) =>
      platform.createObjectUrl(bytes, mime);

  @override
  void revoke(String url) => platform.revokeObjectUrl(url);
}

/// The asset kind of a MIME type, or null when the editor does not handle it.
ir.AssetKind? assetKindForMime(String mime) {
  final m = mime.toLowerCase();
  if (m.startsWith('image/')) return ir.AssetKind.image;
  if (m.startsWith('video/')) return ir.AssetKind.video;
  if (m.startsWith('audio/')) return ir.AssetKind.audio;
  if (m.startsWith('font/') ||
      m == 'application/font-woff' ||
      m == 'application/x-font-ttf' ||
      m == 'application/vnd.ms-fontobject') {
    return ir.AssetKind.font;
  }
  return null;
}

/// A file extension for [mime] (zip entry names).
String extensionForMime(String mime) => switch (mime.toLowerCase()) {
  'image/png' => 'png',
  'image/jpeg' => 'jpg',
  'image/webp' => 'webp',
  'image/gif' => 'gif',
  'image/avif' => 'avif',
  'image/svg+xml' => 'svg',
  'audio/mpeg' => 'mp3',
  'audio/mp4' => 'm4a',
  'audio/ogg' => 'ogg',
  'audio/wav' || 'audio/x-wav' => 'wav',
  'audio/webm' => 'weba',
  'audio/flac' => 'flac',
  'video/mp4' => 'mp4',
  'video/webm' => 'webm',
  'font/ttf' => 'ttf',
  'font/otf' => 'otf',
  'font/woff' => 'woff',
  'font/woff2' => 'woff2',
  _ => 'bin',
};

/// The MIME type for a file [extension] (without the dot), or null.
String? mimeForExtension(String extension) => switch (extension.toLowerCase()) {
  'png' => 'image/png',
  'jpg' || 'jpeg' => 'image/jpeg',
  'webp' => 'image/webp',
  'gif' => 'image/gif',
  'avif' => 'image/avif',
  'svg' => 'image/svg+xml',
  'mp3' => 'audio/mpeg',
  'm4a' => 'audio/mp4',
  'ogg' => 'audio/ogg',
  'wav' => 'audio/wav',
  'weba' => 'audio/webm',
  'flac' => 'audio/flac',
  'mp4' => 'video/mp4',
  'webm' => 'video/webm',
  'ttf' => 'font/ttf',
  'otf' => 'font/otf',
  'woff' => 'font/woff',
  'woff2' => 'font/woff2',
  _ => null,
};

/// The asset library in browser storage: the files behind `local://<id>`
/// URIs (architecture §12).
///
/// Implements the runtime's [LocalAssetLoader], so the player and editor
/// read these through `StageAssetResolver`.
class LocalAssetStore implements LocalAssetLoader {
  LocalAssetStore(
    this._db, {
    AssetAnalyzer? analyzer,
    ObjectUrlFactory? urls,
    PeaksDecoder? peaksDecoder,
    DateTime Function()? now,
    ir.IdGenerator? ids,
  }) : _analyzer = analyzer ?? const BrowserAssetAnalyzer(),
       _decodePeaks = peaksDecoder ?? platform.decodePeaksInBrowser,
       _urls = urls ?? const BrowserObjectUrls(),
       _now = now ?? DateTime.now,
       _ids = ids ?? ir.IdGenerator();

  final StoryDatabase _db;
  final AssetAnalyzer _analyzer;
  final ObjectUrlFactory _urls;
  final PeaksDecoder _decodePeaks;
  final DateTime Function() _now;
  final ir.IdGenerator _ids;

  /// Stores [bytes] as a new asset and returns its document entry
  /// (`local://<id>`), with the intrinsic size, duration and a
  /// dominant-colour placeholder where the file has them.
  ///
  /// Throws [UnsupportedAssetException] for a MIME type the editor does not
  /// handle or an image that cannot be decoded, and [StorageFullException]
  /// when the browser is out of space (nothing is stored then).
  Future<ir.Asset> put(Uint8List bytes, String mime, {String name = ''}) async {
    final kind = assetKindForMime(mime);
    if (kind == null) {
      throw UnsupportedAssetException('"$mime" is not a supported media type.');
    }
    final analysis = await _analyzer.analyze(bytes, mime);
    final peaks = kind == ir.AssetKind.audio ? await _peaksOf(bytes) : null;
    final id = await _freshId();
    final meta = AssetMeta(
      id: id,
      mime: mime,
      byteSize: bytes.length,
      createdAt: _now().millisecondsSinceEpoch,
      name: name,
      width: analysis.width,
      height: analysis.height,
      duration: analysis.duration ?? peaks?.duration,
      dominantColor: analysis.dominantColor,
      peaks: peaks?.data,
    );
    await _db.putAsset(AssetRecord(meta, bytes));
    return toAsset(meta);
  }

  /// Replaces the file of asset [assetId] with [bytes] (re-analysed), keeping
  /// its id, creation time and, unless [name] is given, its name: every use
  /// in a document follows. Throws like [put]; nothing changes on failure.
  Future<ir.Asset> replace(
    String assetId,
    Uint8List bytes,
    String mime, {
    String? name,
  }) async {
    final old = await _db.getAsset(assetId);
    if (old == null) {
      throw UnsupportedAssetException('There is no stored asset "$assetId".');
    }
    if (assetKindForMime(mime) == null) {
      throw UnsupportedAssetException('"$mime" is not a supported media type.');
    }
    final analysis = await _analyzer.analyze(bytes, mime);
    final peaks = assetKindForMime(mime) == ir.AssetKind.audio
        ? await _peaksOf(bytes)
        : null;
    final meta = AssetMeta(
      id: assetId,
      mime: mime,
      byteSize: bytes.length,
      createdAt: old.meta.createdAt,
      name: name ?? old.meta.name,
      width: analysis.width,
      height: analysis.height,
      duration: analysis.duration ?? peaks?.duration,
      dominantColor: analysis.dominantColor,
      peaks: peaks?.data,
    );
    _peaksCache.remove(assetId)?.ignore();
    await _db.putAsset(AssetRecord(meta, bytes));
    return toAsset(meta);
  }

  /// Stores [bytes] under the id and metadata of [asset] (importing or
  /// duplicating a document: nothing is decoded again). Returns the entry
  /// with its `local://` URI.
  Future<ir.Asset> putExisting(ir.Asset asset, Uint8List bytes) async {
    final c = asset.placeholder?.dominantColor;
    final meta = AssetMeta(
      id: asset.id,
      mime: asset.mime,
      byteSize: bytes.length,
      createdAt: _now().millisecondsSinceEpoch,
      name: asset.name,
      width: asset.width,
      height: asset.height,
      duration: asset.duration,
      dominantColor: c == null ? null : _argb(c),
    );
    await _db.putAsset(AssetRecord(meta, bytes));
    return asset.copyWith(uri: 'local://${asset.id}', byteSize: bytes.length);
  }

  /// Decoding failures (an undecodable file, too little memory) mean "no
  /// peaks yet", never a failed upload: the file still plays.
  Future<WaveformPeaks?> _peaksOf(Uint8List bytes) async {
    try {
      return await _decodePeaks(bytes);
    } on Object {
      return null;
    }
  }

  final Map<String, Future<WaveformPeaks?>> _peaksCache = {};

  /// The waveform peaks of audio asset [assetId]: read from its record, or
  /// computed now and stored when it has none (an asset uploaded before
  /// peaks existed, imported, or whose decode failed). Null for a missing
  /// or non-audio asset and for audio that cannot be decoded. Concurrent
  /// callers share one decode.
  Future<WaveformPeaks?> peaks(String assetId) => _peaksCache.putIfAbsent(
    assetId,
    () => _loadPeaks(assetId).then((p) {
      if (p == null) _peaksCache.remove(assetId);
      return p;
    }),
  );

  Future<WaveformPeaks?> _loadPeaks(String assetId) async {
    final rec = await _db.getAsset(assetId);
    if (rec == null || assetKindForMime(rec.meta.mime) != ir.AssetKind.audio) {
      return null;
    }
    final have = rec.meta.peaks;
    if (have != null) {
      return WaveformPeaks(
        have,
        rec.meta.duration ?? have.length * kPeakBucketSeconds,
      );
    }
    final computed = await _peaksOf(rec.bytes);
    if (computed == null) return null;
    await _db.putAsset(
      AssetRecord(
        rec.meta.withPeaks(computed.data, duration: computed.duration),
        rec.bytes,
      ),
    );
    return WaveformPeaks(computed.data, rec.meta.duration ?? computed.duration);
  }

  Future<String> _freshId() async {
    final existing = {for (final m in await _db.listAssets()) m.id};
    _ids.reserve(existing);
    return _ids.next();
  }

  /// The file's bytes, or null if there is no such asset.
  Future<Uint8List?> get(String assetId) async =>
      (await _db.getAsset(assetId))?.bytes;

  /// The stored file and its metadata, or null.
  Future<AssetRecord?> record(String assetId) => _db.getAsset(assetId);

  Future<List<AssetMeta>> list() => _db.listAssets();

  /// The document entry for [meta].
  ir.Asset toAsset(AssetMeta meta) {
    final c = meta.dominantColor;
    return ir.Asset(
      id: meta.id,
      kind: assetKindForMime(meta.mime) ?? ir.AssetKind.image,
      uri: 'local://${meta.id}',
      name: meta.name,
      mime: meta.mime,
      byteSize: meta.byteSize,
      width: meta.width,
      height: meta.height,
      duration: meta.duration,
      placeholder: c == null
          ? null
          : ir.AssetPlaceholder(
              dominantColor: ir.StageColor(
                r: ((c >> 16) & 0xFF) / 255,
                g: ((c >> 8) & 0xFF) / 255,
                b: (c & 0xFF) / 255,
              ),
            ),
    );
  }

  static int _argb(ir.StageColor c) {
    int ch(double v) => (v.clamp(0.0, 1.0) * 255).round();
    return 0xFF000000 | (ch(c.r) << 16) | (ch(c.g) << 8) | ch(c.b);
  }

  /// Deletes assets that no story references and returns how many.
  ///
  /// "Referenced" means the id appears as a `local://<id>` URI in any
  /// retained revision of any story, so restoring an old revision never
  /// finds a missing file. Assets younger than [minAge] are kept: they may
  /// be uploaded but not yet autosaved into a document.
  Future<int> collectGarbage({
    Duration minAge = const Duration(hours: 1),
    Set<String> alsoReferenced = const {},
  }) async {
    final referenced = <String>{...alsoReferenced};
    final pattern = RegExp(r'local://([A-Za-z0-9_\-]+)');
    for (final story in await _db.listStories()) {
      for (final info in await _db.listRevisions(story.id)) {
        final rev = await _db.getRevision(story.id, info.rev);
        if (rev == null) continue;
        for (final m in pattern.allMatches(rev.json)) {
          referenced.add(m.group(1)!);
        }
      }
    }
    final cutoff = _now().subtract(minAge).millisecondsSinceEpoch;
    final doomed = [
      for (final m in await _db.listAssets())
        if (!referenced.contains(m.id) && m.createdAt <= cutoff) m.id,
    ];
    if (doomed.isNotEmpty) await _db.deleteAssets(doomed);
    return doomed.length;
  }

  // ---- LocalAssetLoader ---------------------------------------------------

  final Map<String, _UrlHold> _urlHolds = {};

  @override
  Future<Uint8List?> loadBytes(String assetId) => get(assetId);

  @override
  Future<String?> acquireObjectUrl(String assetId) async {
    final held = _urlHolds[assetId];
    if (held != null) {
      held.count++;
      return held.url;
    }
    final rec = await _db.getAsset(assetId);
    if (rec == null) return null;
    // Another caller may have created it while we awaited.
    final again = _urlHolds[assetId];
    if (again != null) {
      again.count++;
      return again.url;
    }
    final hold = _UrlHold(_urls.create(rec.bytes, rec.meta.mime));
    _urlHolds[assetId] = hold;
    return hold.url;
  }

  @override
  void releaseObjectUrl(String assetId) {
    final hold = _urlHolds[assetId];
    if (hold == null) return;
    if (--hold.count <= 0) {
      _urls.revoke(hold.url);
      _urlHolds.remove(assetId);
    }
  }

  /// Object URLs currently alive (tests).
  int get liveObjectUrls => _urlHolds.length;
}

class _UrlHold {
  _UrlHold(this.url);

  final String url;
  int count = 1;
}
