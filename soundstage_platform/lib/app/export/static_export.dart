import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:soundstage_platform/export/export.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../persistence/local_asset_store.dart' show extensionForMime;
import '../persistence/story_package.dart' show AssetBytesSource;

/// Renders a poster frame: scene [sceneId] at [clock] (null: its poster
/// clock), cropped to [nodeId] when given. PNG bytes, or null.
typedef PosterSource =
    Future<Uint8List?> Function({
      required String sceneId,
      double? clock,
      String? nodeId,
    });

/// A file an export bundles.
class ExportFile {
  const ExportFile(this.path, this.bytes, this.mime);

  /// Relative to the export root (`assets/…`).
  final String path;
  final Uint8List bytes;
  final String mime;
}

/// The files [story]'s blocks need (architecture §16.1), by
/// [fileKeyOf] key: image and audio assets as stored, posters rendered
/// through [poster]. Keys whose file is unavailable are left out (the block
/// then exports as text only).
Future<Map<String, ExportFile>> collectExportFiles(
  LinearStory story,
  ir.StageDocument doc, {
  required AssetBytesSource bytesOf,
  required PosterSource poster,
}) async {
  final out = <String, ExportFile>{};
  final used = <String>{};
  String pathFor(String stem, String ext) {
    final safe = stem.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-');
    var p = 'assets/$safe.$ext';
    for (var n = 2; used.contains(p); n++) {
      p = 'assets/$safe-$n.$ext';
    }
    used.add(p);
    return p;
  }

  for (final b in story.blocks) {
    final key = fileKeyOf(b);
    if (key == null || out.containsKey(key)) continue;
    Uint8List? bytes;
    var mime = 'image/png';
    var stem = key;
    switch (b) {
      case FigureBlock(:final assetId?) || AudioBlock(:final assetId):
        final asset = doc.assets[assetId];
        if (asset == null) break;
        if (asset.kind == ir.AssetKind.imageSequence) {
          // A sequence as a still: its first frame.
          bytes = await bytesOf(
            asset.copyWith(
              kind: ir.AssetKind.image,
              uri: ir.sequenceFrameUri(asset, 0),
            ),
          );
        } else {
          bytes = await bytesOf(asset);
        }
        mime = asset.mime.isEmpty ? mime : asset.mime;
        final name = asset.name.trim();
        final dot = name.lastIndexOf('.');
        stem = name.isEmpty
            ? assetId
            : (dot > 0 ? name.substring(0, dot) : name);
      case FigureBlock(:final nodeId, :final sceneId):
        bytes = await poster(sceneId: sceneId, nodeId: nodeId);
        stem = 'figure-$nodeId';
      case PosterBlock(:final sceneId, :final clock):
        bytes = await poster(sceneId: sceneId, clock: clock);
        stem = 'scene-$sceneId';
      default:
        break;
    }
    if (bytes == null) continue;
    out[key] = ExportFile(pathFor(stem, extensionForMime(mime)), bytes, mime);
  }
  return out;
}

enum StaticExportFormat { markdown, html }

/// A `.zip` with `story.md` (or `index.html`) and its `assets/` folder.
Future<Uint8List> exportStaticZip(
  ir.StageDocument doc,
  StaticExportFormat format, {
  required AssetBytesSource bytesOf,
  required PosterSource poster,
  Backlink? backlink,
}) async {
  final story = linearize(doc);
  final files = await collectExportFiles(
    story,
    doc,
    bytesOf: bytesOf,
    poster: poster,
  );
  String? pathOf(String key) => files[key]?.path;
  final archive = Archive();
  final (name, text) = switch (format) {
    StaticExportFormat.markdown => (
      'story.md',
      toMarkdown(story, pathOf: pathOf, backlink: backlink),
    ),
    StaticExportFormat.html => (
      'index.html',
      toHtml(story, pathOf: pathOf, backlink: backlink),
    ),
  };
  archive.addFile(ArchiveFile.bytes(name, utf8.encode(text)));
  for (final f in files.values) {
    archive.add(ArchiveFile.noCompress(f.path, f.bytes.length, f.bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
