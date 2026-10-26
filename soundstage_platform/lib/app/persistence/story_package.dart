import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart' show localAssetId;

import 'local_asset_store.dart';
import 'records.dart';

/// The `.stage.zip` layout:
///
/// ```
/// manifest.json         { format, version, schemaVersion, title, exportedAt, assets: [...] }
/// story.stage.json      the document, every asset uri rewritten to local://<id>
/// assets/<id>.<ext>     one file per asset
/// ```
const String kPackageFormat = 'soundstage-story';
const int kPackageVersion = 1;
const String kManifestName = 'manifest.json';
const String kStoryName = 'story.stage.json';

/// Hard limits on what an import will unpack (a zip can lie about sizes).
const int kMaxImportBytes = 1 << 30; // 1 GiB uncompressed in total
const int kMaxImportEntries = 5000;

/// A file name for [title] (`My story` becomes `My-story`).
String exportFileBase(String title) {
  final cleaned = title
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9._ -]+'), '')
      .replaceAll(RegExp(r'\s+'), '-');
  return cleaned.isEmpty ? 'story' : cleaned;
}

/// `.stage.json` text for [document].
String exportStageJson(ir.StageDocument document) =>
    const JsonEncoder.withIndent('  ').convert(document.toJson());

/// Gives the bytes of [asset] for export, or null if unavailable.
typedef AssetBytesSource = Future<Uint8List?> Function(ir.Asset asset);

/// Builds a `.stage.zip`: the document, its assets and a manifest.
///
/// Assets whose bytes are unavailable (a dangling reference, a remote URL)
/// are left out and listed under `missing` in the manifest; the document
/// keeps their original URI.
Future<Uint8List> exportStageZip(
  ir.StageDocument document,
  AssetBytesSource bytesOf, {
  DateTime? exportedAt,
}) async {
  final archive = Archive();
  final entries = <Map<String, Object?>>[];
  final missing = <String>[];
  final rewritten = <String, ir.Asset>{};
  for (final MapEntry(:key, value: asset) in document.assets.entries) {
    if (asset.kind == ir.AssetKind.imageSequence) {
      final packed = await _exportSequence(asset, bytesOf, archive, entries);
      if (packed == null) missing.add(asset.id);
      rewritten[key] = packed ?? asset;
      continue;
    }
    final bytes = await bytesOf(asset);
    if (bytes == null) {
      missing.add(asset.id);
      rewritten[key] = asset;
      continue;
    }
    final ext = extensionForMime(asset.mime);
    final path = 'assets/${asset.id}.$ext';
    final compress =
        asset.kind == ir.AssetKind.font ||
        asset.mime == 'image/svg+xml' ||
        asset.mime.contains('wav');
    archive.add(
      compress
          ? ArchiveFile.bytes(path, bytes)
          : ArchiveFile.noCompress(path, bytes.length, bytes),
    );
    entries.add({
      'id': asset.id,
      'path': path,
      'mime': asset.mime,
      'byteSize': bytes.length,
    });
    rewritten[key] = asset.copyWith(uri: 'local://${asset.id}');
  }
  final packaged = document.copyWith(assets: rewritten);
  archive.addFile(ArchiveFile.string(kStoryName, exportStageJson(packaged)));
  archive.addFile(
    ArchiveFile.string(
      kManifestName,
      const JsonEncoder.withIndent('  ').convert({
        'format': kPackageFormat,
        'version': kPackageVersion,
        'schemaVersion': document.schemaVersion,
        'title': document.meta.title,
        'exportedAt': (exportedAt ?? DateTime.now()).toUtc().toIso8601String(),
        'assets': entries,
        if (missing.isNotEmpty) 'missing': missing,
      }),
    ),
  );
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Writes the frames of image sequence [asset] as
/// `assets/<id>_0001.<ext>`, … and returns the entry pointing at them
/// (`local://<id>_{0001}`), or null when any frame is unavailable.
Future<ir.Asset?> _exportSequence(
  ir.Asset asset,
  AssetBytesSource bytesOf,
  Archive archive,
  List<Map<String, Object?>> entries,
) async {
  final count = asset.frameCount ?? 0;
  if (count < 1 || !ir.isFramePattern(asset.uri)) return null;
  final pad = count.toString().length.clamp(4, 9);
  final ext = extensionForMime(asset.mime);
  final files = <ArchiveFile>[];
  var total = 0;
  for (var i = 0; i < count; i++) {
    final bytes = await bytesOf(
      asset.copyWith(
        kind: ir.AssetKind.image,
        uri: ir.sequenceFrameUri(asset, i),
      ),
    );
    if (bytes == null) return null;
    total += bytes.length;
    final id = '${asset.id}_${(i + 1).toString().padLeft(pad, '0')}';
    files.add(ArchiveFile.noCompress('assets/$id.$ext', bytes.length, bytes));
  }
  files.forEach(archive.add);
  entries.add({
    'id': asset.id,
    'path': 'assets/${asset.id}_{${'1'.padLeft(pad, '0')}}.$ext',
    'mime': asset.mime,
    'byteSize': total,
    'frameCount': count,
  });
  return asset.copyWith(uri: 'local://${asset.id}_{${'1'.padLeft(pad, '0')}}');
}

/// What an import produced.
class ImportedStory {
  const ImportedStory({
    required this.document,
    this.diagnostics = const [],
    this.warnings = const [],
    this.assetCount = 0,
  });

  /// The parsed document, still carrying the id it was exported with; the
  /// repository assigns a fresh story id (`createFrom`).
  final ir.StageDocument? document;
  final List<ir.IrDiagnostic> diagnostics;
  final List<String> warnings;
  final int assetCount;
}

/// The import could not even be started (not JSON, not a story zip).
class ImportException implements Exception {
  const ImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool looksLikeZip(Uint8List bytes) =>
    bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4B;

final RegExp _assetEntry = RegExp(
  r'^assets/([A-Za-z0-9_\-]+)\.([A-Za-z0-9]+)$',
);

/// Parses a `.stage.json` (text) or `.stage.zip` ([bytes] starting `PK`).
///
/// Zip assets are written through [store]. An asset id that already exists
/// in the store with different content gets a fresh id, and every reference
/// in the document is rewritten; an id whose content is identical is reused.
/// Nothing is written to the story list: the caller passes the result to
/// `StoryRepository.createFrom`.
Future<ImportedStory> importStoryFile(
  Uint8List bytes,
  LocalAssetStore store,
) async {
  if (!looksLikeZip(bytes)) {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      throw const ImportException('This file is not a Soundstage story.');
    }
    final result = ir.loadDocument(text);
    if (!result.loaded) {
      throw ImportException(
        result.diagnostics.isEmpty
            ? 'This file is not a Soundstage story.'
            : result.diagnostics.first.message,
      );
    }
    return ImportedStory(
      document: result.document,
      diagnostics: result.diagnostics,
    );
  }

  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object {
    throw const ImportException('This zip file could not be read.');
  }
  if (archive.length > kMaxImportEntries) {
    throw const ImportException('This zip has too many files.');
  }
  var total = 0;
  for (final f in archive) {
    total += f.size;
    if (total > kMaxImportBytes) {
      throw const ImportException('This zip is too large to import.');
    }
  }
  ArchiveFile? storyFile;
  ArchiveFile? manifestFile;
  final assetFiles = <String, ArchiveFile>{}; // id -> file
  final assetExt = <String, String>{};
  for (final f in archive) {
    if (!f.isFile) continue;
    if (f.name == kStoryName) {
      storyFile = f;
    } else if (f.name == kManifestName) {
      manifestFile = f;
    } else {
      final m = _assetEntry.firstMatch(f.name);
      if (m != null) {
        assetFiles[m.group(1)!] = f;
        assetExt[m.group(1)!] = m.group(2)!;
      }
    }
  }
  if (storyFile == null) {
    throw const ImportException('This zip has no story.stage.json.');
  }
  final Object? raw;
  try {
    raw = jsonDecode(utf8.decode(storyFile.readBytes() ?? Uint8List(0)));
  } on Object {
    throw const ImportException('story.stage.json could not be read.');
  }
  if (raw is! Map) {
    throw const ImportException('story.stage.json is not a story document.');
  }

  final manifestMime = <String, String>{};
  if (manifestFile != null) {
    try {
      final m = jsonDecode(
        utf8.decode(manifestFile.readBytes() ?? Uint8List(0)),
      );
      if (m is Map && m['assets'] is List) {
        for (final a
            in (m['assets'] as List).whereType<Map<String, Object?>>()) {
          final id = a['id'];
          final mime = a['mime'];
          if (id is String && mime is String) manifestMime[id] = mime;
        }
      }
    } on Object {
      // The manifest is a convenience; extensions give the types too.
    }
  }

  // Parse the document first (to learn each asset's metadata), then store
  // the files, remapping ids on collision.
  var json = <String, Object?>{
    for (final e in raw.entries) e.key.toString(): e.value,
  };
  final warnings = <String>[];
  final remap = <String, String>{};
  final probe = ir.loadDocument(json);
  final assetMeta = probe.document?.assets ?? const <String, ir.Asset>{};
  final taken = <String>{for (final m in await store.list()) m.id};
  final ids = ir.IdGenerator()
    ..reserve(taken)
    ..reserve(assetFiles.keys);
  var stored = 0;
  // Image sequences first: their frames move together, so a collision on
  // any frame gives the whole sequence a fresh id.
  for (final seq in assetMeta.values) {
    if (seq.kind != ir.AssetKind.imageSequence) continue;
    final count = seq.frameCount ?? 0;
    final frames = <(String, Uint8List)>[];
    for (var i = 0; i < count; i++) {
      final key = localAssetId(ir.sequenceFrameUri(seq, i));
      final data = key == null ? null : assetFiles.remove(key)?.readBytes();
      if (key != null && data != null) frames.add((key, data));
    }
    if (frames.length != count || count == 0) {
      if (count > 0) {
        warnings.add('Image sequence "${seq.name}" is missing frames.');
      }
      continue;
    }
    var conflict = false;
    for (final (key, data) in frames) {
      final existing = await store.record(key);
      if (existing != null && !_sameBytes(existing.bytes, data)) {
        conflict = true;
        break;
      }
    }
    final id = conflict ? ids.next() : seq.id;
    if (conflict) remap[seq.id] = id;
    for (final (key, data) in frames) {
      final frameId = '$id${key.substring(seq.id.length)}';
      await store.putExisting(
        ir.Asset(
          id: frameId,
          kind: ir.AssetKind.image,
          uri: 'local://$frameId',
          name: seq.name,
          mime: seq.mime,
          width: seq.width,
          height: seq.height,
        ),
        data,
      );
    }
    stored++;
  }
  for (final MapEntry(:key, value: file) in assetFiles.entries) {
    final data = file.readBytes();
    if (data == null) continue;
    final ext = assetExt[key]!;
    final mime =
        manifestMime[key] ?? mimeForExtension(ext) ?? assetMeta[key]?.mime;
    if (mime == null || assetKindForMime(mime) == null) {
      warnings.add('Skipped "${file.name}": unsupported file type.');
      continue;
    }
    var id = key;
    final existing = await store.record(key);
    if (existing != null) {
      if (_sameBytes(existing.bytes, data)) {
        stored++;
        continue; // identical content: reuse the id
      }
      id = ids.next();
      remap[key] = id;
    }
    final base =
        assetMeta[key] ??
        ir.Asset(id: key, kind: assetKindForMime(mime)!, uri: 'local://$key');
    await store.putExisting(
      base.copyWith(id: id, mime: mime, uri: 'local://$id'),
      data,
    );
    stored++;
  }
  if (remap.isNotEmpty) {
    json = Map<String, Object?>.from(_remapIds(json, remap)! as Map);
  }
  final result = ir.loadDocument(json);
  if (!result.loaded) {
    throw ImportException(
      result.diagnostics.isEmpty
          ? 'story.stage.json is not a story document.'
          : result.diagnostics.first.message,
    );
  }
  return ImportedStory(
    document: result.document,
    diagnostics: result.diagnostics,
    warnings: warnings,
    assetCount: stored,
  );
}

final RegExp _sequencePattern = RegExp(r'^(.+?)(_\{\d+\})$');

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Replaces asset ids in a decoded document: map keys and string values
/// equal to an old id (or `local://<old>`). Asset ids are random and
/// distinctive, so an exact-match rewrite does not touch anything else.
Object? _remapIds(Object? node, Map<String, String> remap) {
  switch (node) {
    case final String s:
      if (remap.containsKey(s)) return remap[s];
      if (s.startsWith('local://')) {
        final id = s.substring('local://'.length);
        if (remap.containsKey(id)) return 'local://${remap[id]}';
        // An image sequence pattern: `local://<id>_{0001}`.
        final m = _sequencePattern.firstMatch(id);
        if (m != null && remap.containsKey(m.group(1))) {
          return 'local://${remap[m.group(1)]}${m.group(2)}';
        }
      }
      return s;
    case final Map<Object?, Object?> m:
      return <String, Object?>{
        for (final e in m.entries)
          if (e.key is String)
            (remap[e.key] ?? e.key! as String): _remapIds(e.value, remap),
      };
    case final List<Object?> l:
      return [for (final v in l) _remapIds(v, remap)];
    default:
      return node;
  }
}

/// Exposes the remapper for tests.
Object? remapAssetIdsForTest(Object? json, Map<String, String> remap) =>
    _remapIds(json, remap);

/// The storage-full failure surfaced while importing assets is rethrown as is
/// ([StorageFullException]); this keeps the import atomic from the author's
/// point of view only for the document (assets already stored are garbage
/// until [LocalAssetStore.collectGarbage]).
typedef ImportStorageFull = StorageFullException;
