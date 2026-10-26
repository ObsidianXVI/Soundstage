import 'dart:convert';

import 'package:soundstage_platform/ir/ir.dart' as ir;

// Chunked published documents (architecture §17.3, m4.md T4.4): a small
// manifest, a library chunk (tokens, components, fonts, the asset table)
// and one chunk per scene. The player fetches scene chunks as the reader
// approaches them; the manifest carries a stub of every scene (its root
// frame without children or tracks) so scroll lengths and backgrounds are
// right before a scene arrives.

/// The keys of a document that go to the library chunk.
const List<String> _libraryKeys = [
  'tokens',
  'assets',
  'fonts',
  'components',
  'variantSets',
];

/// The manifest format tag.
const String kChunkedFormat = 'soundstage.chunked/1';

/// A document split into chunks (JSON maps, ready to encode).
class DocumentChunks {
  const DocumentChunks({
    required this.manifest,
    required this.library,
    required this.scenes,
  });

  /// The document without its library and with stub scenes. The
  /// publisher adds `library` (the library chunk's URL) and `chunks`
  /// (scene id → chunk URL).
  final Map<String, Object?> manifest;
  final Map<String, Object?> library;

  /// Scene id → the scene's full JSON, in reading order.
  final Map<String, Map<String, Object?>> scenes;
}

/// Splits [doc] into chunks.
DocumentChunks splitDocument(ir.StageDocument doc) {
  final json = _plain(doc.toJson());
  final library = {
    for (final k in _libraryKeys)
      if (json.containsKey(k)) k: json.remove(k),
  };
  final scenes = <String, Map<String, Object?>>{};
  final stubs = <Map<String, Object?>>[];
  for (final s in (json.remove('scenes') as List?) ?? const []) {
    final scene = Map<String, Object?>.from(s as Map);
    scenes[scene['id']! as String] = scene;
    stubs.add(_stub(scene));
  }
  return DocumentChunks(
    manifest: {...json, 'format': kChunkedFormat, 'stubs': stubs},
    library: library,
    scenes: scenes,
  );
}

/// A scene's stand-in until its chunk arrives: same id, kind, length,
/// clocks, background and root frame, without children or tracks.
Map<String, Object?> _stub(Map<String, Object?> scene) {
  final root = Map<String, Object?>.from(scene['root']! as Map)
    ..['children'] = const <Object?>[];
  return {...scene, 'root': root, 'tracks': const <Object?>[]};
}

/// A published chunked story being loaded: the document so far (stub
/// scenes until their chunks arrive) and which scenes are complete.
class ChunkedDocument {
  ChunkedDocument._(this._base, this.document);

  /// Assembles the document from a [manifest] and its [library] chunk,
  /// every scene a stub.
  factory ChunkedDocument.open(
    Map<String, Object?> manifest,
    Map<String, Object?> library,
  ) {
    if (manifest['format'] != kChunkedFormat) {
      throw const FormatException('Not a chunked Soundstage document.');
    }
    final base = Map<String, Object?>.from(manifest)
      ..remove('format')
      ..remove('library');
    final stubs = (base.remove('stubs') as List?) ?? const [];
    final chunkPaths = (base.remove('chunks') as Map?) ?? const {};
    final doc = _parse({...base, ...library, 'scenes': stubs});
    return ChunkedDocument._(base, doc)
      .._paths.addAll(chunkPaths.cast<String, String>());
  }

  final Map<String, Object?> _base;
  final Map<String, String> _paths = {};
  final Set<String> _loaded = {};

  /// The document with every chunk received so far.
  ir.StageDocument document;

  /// Where scene [sceneId]'s chunk is (as the manifest gives it).
  String? chunkPath(String sceneId) => _paths[sceneId];

  bool isLoaded(String sceneId) => _loaded.contains(sceneId);

  /// Whether every scene has its chunk.
  bool get complete => document.scenes.every((s) => _loaded.contains(s.id));

  /// Puts scene chunk [json] in place of its stub. The other scenes keep
  /// their identity, so the player re-resolves only this one. Returns
  /// false when the chunk is not one of this document's scenes.
  bool addScene(Map<String, Object?> json) {
    final id = json['id'];
    final i = document.scenes.indexWhere((s) => s.id == id);
    if (i < 0) return false;
    // Migrate and parse it as a one-scene document of the same version
    // (without the library: parsing does not resolve references).
    final scene = _parse({
      ..._base,
      'scenes': [json],
    }).scenes.single;
    final scenes = [...document.scenes]..[i] = scene;
    document = document.copyWith(scenes: scenes);
    _loaded.add(scene.id);
    return true;
  }

  static ir.StageDocument _parse(Map<String, Object?> json) =>
      ir.StageDocument.fromJsonMigrating(json);
}

/// A deep copy of [json] as plain maps and lists (what `jsonDecode`
/// gives), so freezed objects inside `toJson` output become maps.
Map<String, Object?> _plain(Map<String, Object?> json) =>
    jsonDecode(jsonEncode(json)) as Map<String, Object?>;
