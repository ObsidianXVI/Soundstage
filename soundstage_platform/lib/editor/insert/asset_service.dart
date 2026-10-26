import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../audio/waveform_peaks.dart';
import '../clipboard/content_hash.dart';
import '../core/editor_controller.dart';

/// A file the author gave the editor: from the picker, a drop or the
/// clipboard.
typedef EditorFile = ({String name, Uint8List bytes, String mime});

/// The editor's door to the asset store (`local://<id>`, architecture §12).
///
/// Panels, the insert tools and the clipboard talk to this. The editor never
/// imports the app: the app implements it (over its IndexedDB store) and
/// supplies it with `EditorShell(assetService:)`; tests supply a fake. Every method throws
/// [AssetServiceException] with a message fit for a toast.
abstract interface class EditorAssetService {
  /// Whether files can be stored (false when browser storage is blocked).
  bool get available;

  /// Stores [bytes] as a new asset and returns its table entry.
  Future<ir.Asset> add(Uint8List bytes, String mime, {String name = ''});

  /// Replaces the file of [assetId]; the id stays.
  Future<ir.Asset> replace(
    String assetId,
    Uint8List bytes,
    String mime, {
    String? name,
  });

  /// The stored bytes of [assetId], or null.
  Future<Uint8List?> bytes(String assetId);

  /// The table entry for an asset that is in the store but may not be in
  /// the document (a clipboard reference within the same browser profile),
  /// or null.
  Future<ir.Asset?> stored(String assetId);

  /// The waveform peaks of audio asset [assetId] (10 ms buckets,
  /// m2.md "Audio lane"), or null when it is not audio, not stored, or the
  /// browser cannot decode it. They are computed once when the file is
  /// uploaded and stored in the asset record; an asset that lacks them gets
  /// them computed on this first request.
  ///
  /// [uri] is the asset's URI in the document: assets that are not in the
  /// store (bundled `asset://` demo audio) are decoded from it.
  Future<WaveformPeaks?> peaks(String assetId, {String? uri});
}

/// A storage or format problem, worded for the author.
class AssetServiceException implements Exception {
  const AssetServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The asset service of the open editor. Unset by default: `EditorShell`
/// overrides it, and reading it without an override throws.
final editorAssetServiceProvider = Provider<EditorAssetService>(
  (ref) => throw StateError(
    'editorAssetServiceProvider is not set: pass assetService to EditorShell '
    'or override the provider.',
  ),
  dependencies: const [],
);

/// The waveform peaks of an audio asset, by asset id (null while none are
/// available). The audio lane reads this; call `ref.invalidate` with the
/// asset id after replacing the file of an asset.
final audioPeaksProvider = FutureProvider.family<WaveformPeaks?, String>(
  (ref, assetId) => ref
      .watch(editorAssetServiceProvider)
      .peaks(
        assetId,
        uri: ref.read(editorControllerProvider).document.assets[assetId]?.uri,
      ),
  dependencies: [editorAssetServiceProvider, editorControllerProvider],
);

/// Files that were not stored, with why (for one toast).
class IngestReport {
  IngestReport();

  final List<ir.Asset> assets = [];
  final List<String> problems = [];

  bool get ok => problems.isEmpty;

  /// "a.png: …; b.gif: …".
  String get summary => problems.join('\n');
}

/// The MIME type to store [f] under: its own when it is a known media
/// type, else by file extension.
String? mimeOfFile(EditorFile f) {
  if (mediaKindForMime(f.mime) != null) return f.mime;
  final dot = f.name.lastIndexOf('.');
  return dot < 0 ? null : mimeForFileExtension(f.name.substring(dot + 1));
}

/// Stores each of [files] that is an image, audio or video file and
/// returns the new assets in order; the rest (fonts go through the Fonts
/// panel) and the failures are listed in `problems`.
Future<IngestReport> ingestMedia(
  EditorAssetService service,
  Iterable<EditorFile> files, {
  Set<ir.AssetKind> kinds = const {
    ir.AssetKind.image,
    ir.AssetKind.audio,
    ir.AssetKind.video,
    ir.AssetKind.lottie,
    ir.AssetKind.rive,
  },
  Iterable<ir.Asset> existing = const [],
}) async {
  final report = IngestReport();
  // Same bytes, same asset (as an import does): a file already in the
  // document, or given twice, reuses that asset instead of a second copy.
  // Candidates are matched on byte size first, so only same-size stored
  // files are read and hashed.
  final known = [...existing];
  final hashes = <String, String>{};
  Future<ir.Asset?> sameAs(EditorFile f, ir.AssetKind kind) async {
    final h = contentHash(f.bytes);
    for (final a in known) {
      if (a.kind != kind) continue;
      if (a.byteSize > 0 && a.byteSize != f.bytes.length) continue;
      final ah = hashes[a.id] ??= await () async {
        final b = await service.bytes(a.id);
        return b == null ? '' : contentHash(b);
      }();
      if (ah == h) return a;
    }
    return null;
  }

  for (final f in files) {
    final mime = mimeOfFile(f);
    final kind = mime == null ? null : mediaKindForMime(mime);
    if (kind == ir.AssetKind.font) {
      report.problems.add('${f.name}: fonts are added in Assets → Fonts.');
      continue;
    }
    if (mime == null || kind == null || !kinds.contains(kind)) {
      report.problems.add(
        '${f.name}: not an image, audio or video file the editor can use.',
      );
      continue;
    }
    try {
      final same = await sameAs(f, kind);
      if (same != null) {
        if (!report.assets.contains(same)) report.assets.add(same);
        continue;
      }
      final added = await service.add(f.bytes, mime, name: f.name);
      hashes[added.id] = contentHash(f.bytes);
      known.add(added);
      report.assets.add(added);
    } on AssetServiceException catch (e) {
      report.problems.add('${f.name}: ${e.message}');
    }
  }
  return report;
}

/// Opens the file picker; an empty list means cancelled.
typedef EditorFilePicker =
    Future<List<EditorFile>> Function({String accept, bool multiple});

/// The browser's file picker, supplied by the app (and by tests). Reading it
/// without an override throws. Must be called from a user gesture.
final editorFilePickerProvider = Provider<EditorFilePicker>(
  (ref) => throw StateError(
    'editorFilePickerProvider is not set: pass filePicker to EditorShell '
    'or override the provider.',
  ),
  dependencies: const [],
);

/// MIME types of the embed files (browsers give no type for them).
const String kRiveMime = 'application/x-rive';
const String kDotLottieMime = 'application/zip+dotlottie';

/// The asset kind of a MIME type, or null when the editor does not handle it.
/// A JSON file is a Lottie animation (the only JSON media).
ir.AssetKind? mediaKindForMime(String mime) {
  final m = mime.toLowerCase();
  if (m == kRiveMime) return ir.AssetKind.rive;
  if (m == kDotLottieMime || m == 'application/json') {
    return ir.AssetKind.lottie;
  }
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

/// The MIME type for a file [extension] (without the dot), or null.
String? mimeForFileExtension(String extension) =>
    switch (extension.toLowerCase()) {
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
      'riv' => kRiveMime,
      'lottie' => kDotLottieMime,
      'json' => 'application/json',
      _ => null,
    };
