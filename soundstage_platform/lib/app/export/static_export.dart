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

/// A `.zip` laid out like the Letterpress repository (m4.md T4.5d): unzip
/// it at the repo root. It holds the Markdown source
/// (`lib/letterpress-engine/store/md_sources/<name>.md`), the generated
/// module (`lib/letterpress-engine/store/modules/soundstage/<name>.dart`),
/// the images (`assets/images/soundstage/<name>/`) and
/// `LETTERPRESS_IMPORT.md` with the lines to add to `lp_store.dart` and
/// `pubspec.yaml`.
Future<Uint8List> exportLetterpressZip(
  ir.StageDocument doc, {
  required AssetBytesSource bytesOf,
  required PosterSource poster,
  required String name,
  required DateTime date,
  Backlink? backlink,
}) async {
  final story = linearize(doc);
  final files = await collectExportFiles(
    story,
    doc,
    bytesOf: bytesOf,
    poster: poster,
  );
  final assetDir = 'assets/images/soundstage/$name';
  String? assetPathOf(String key) {
    final f = files[key];
    return f == null ? null : '$assetDir/${f.path.split('/').last}';
  }

  final className = letterpressClassName(story.title);
  final module = toLetterpressModule(
    story,
    className: className,
    projectName: 'soundstage',
    date: date,
    assetPathOf: assetPathOf,
    sizeOf: (key) {
      final f = files[key];
      return f == null ? null : imageSizeOf(f.bytes);
    },
    backlink: backlink,
  );
  final field = '${className[0].toLowerCase()}${className.substring(1)}';
  final readme =
      '''
# Importing "${story.title}" into Letterpress

Unzip this archive at the root of the Letterpress repository, then:

1. In `lib/letterpress-engine/store/lp_store.dart`, add the part:

       part './modules/soundstage/$name.dart';

   and the registry entry inside `LPStore`:

       static final LPModule $field = $className(renderWithPost: false);

2. In `pubspec.yaml`, under `flutter: assets:`, add:

       - $assetDir/

3. To publish it, list `LPStore.$field` in `ContentConfig`.
''';
  const store = 'lib/letterpress-engine/store';
  final archive = Archive()
    ..addFile(
      ArchiveFile.bytes(
        '$store/md_sources/$name.md',
        utf8.encode(toMarkdown(story, pathOf: assetPathOf, backlink: backlink)),
      ),
    )
    ..addFile(
      ArchiveFile.bytes(
        '$store/modules/soundstage/$name.dart',
        utf8.encode(module),
      ),
    )
    ..addFile(ArchiveFile.bytes('LETTERPRESS_IMPORT.md', utf8.encode(readme)));
  for (final f in files.values) {
    if (!f.mime.startsWith('image/')) continue; // Letterpress has no audio
    final path = '$assetDir/${f.path.split('/').last}';
    archive.add(ArchiveFile.noCompress(path, f.bytes.length, f.bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// A Letterpress file name for [title] (`My story` → `my_story`).
String letterpressFileName(String title) {
  final s = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return s.isEmpty ? 'soundstage_story' : s;
}
