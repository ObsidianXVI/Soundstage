import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

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
  },
}) async {
  final report = IngestReport();
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
      report.assets.add(await service.add(f.bytes, mime, name: f.name));
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

/// The asset kind of a MIME type, or null when the editor does not handle it.
ir.AssetKind? mediaKindForMime(String mime) {
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
      _ => null,
    };
