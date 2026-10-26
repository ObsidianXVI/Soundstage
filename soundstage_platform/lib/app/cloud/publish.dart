import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:soundstage_platform/editor/clipboard/content_hash.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../persistence/local_asset_store.dart' show extensionForMime;
import '../persistence/story_package.dart' show AssetBytesSource;
import 'chunks.dart';

/// The published pointer of a slug (Firestore `published/{slug}`, m4.md
/// T4.2): who owns it, which story, which frozen version and where its
/// document is.
class PublishedRecord {
  const PublishedRecord({
    required this.ownerId,
    required this.storyId,
    required this.version,
    required this.path,
    this.title = '',
    this.description = '',
    this.image = '',
    this.manifest = '',
  });

  factory PublishedRecord.fromMap(Map<String, Object?> m) => PublishedRecord(
    ownerId: m['ownerId']! as String,
    storyId: m['storyId']! as String,
    version: (m['version']! as num).toInt(),
    path: m['path']! as String,
    title: (m['title'] as String?) ?? '',
    description: (m['description'] as String?) ?? '',
    image: (m['image'] as String?) ?? '',
    manifest: (m['manifest'] as String?) ?? '',
  );

  final String ownerId;
  final String storyId;
  final int version;

  /// The document's Storage path (`published/<uid>/<slug>/v<n>.stage.json`).
  final String path;
  final String title;
  final String description;

  /// The public URL of the link-preview image (the first scene's poster),
  /// or empty.
  final String image;

  /// The Storage path of the chunked manifest
  /// (`published/<uid>/<slug>/v<n>.manifest.json`), or empty for versions
  /// published before chunking (T4.4).
  final String manifest;

  Map<String, Object?> toMap() => {
    'ownerId': ownerId,
    'storyId': storyId,
    'version': version,
    'path': path,
    'title': title,
    'description': description,
    'image': image,
    'manifest': manifest,
  };
}

/// What publishing needs from the backend (Firebase in the app, a fake in
/// tests). Paths are Storage object paths; see `infra/firebase/*.rules`.
abstract interface class CloudBackend {
  /// The signed-in author, or null.
  String? get uid;

  Future<bool> exists(String path);

  Future<void> upload(String path, Uint8List bytes, String mime);

  /// A URL anyone can GET [path] at (published files are public-read).
  String publicUrl(String path);

  Future<PublishedRecord?> published(String slug);

  Future<void> setPublished(String slug, PublishedRecord record);

  /// The author's story metadata (`stories/{storyId}`).
  Future<void> setStoryMeta(String storyId, Map<String, Object?> data);

  /// The slug story [storyId] was last published at, or null.
  Future<String?> publishedSlugOf(String storyId);
}

class PublishException implements Exception {
  const PublishException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PublishResult {
  const PublishResult({
    required this.slug,
    required this.version,
    this.warnings = const [],
  });

  final String slug;
  final int version;
  final List<String> warnings;

  /// The player route, relative to the site (`/s/<slug>`).
  String get path => '/s/$slug';
}

final RegExp _slugPattern = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$');

/// Whether [slug] is a valid published link (lowercase letters, digits and
/// inner dashes; matches the Firestore rules).
bool isValidSlug(String slug) => _slugPattern.hasMatch(slug);

/// A slug suggested by [title] (`My first story!` → `my-first-story`).
String slugFor(String title) {
  final s = title
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = s.length > 64
      ? s.substring(0, 64).replaceAll(RegExp(r'-+$'), '')
      : s;
  return cut.isEmpty ? 'story' : cut;
}

/// Publishes [doc] (story [storyId]) at [slug] as the next frozen version
/// (architecture §16, m4.md T4.2):
///
/// 1. every asset is uploaded once under
///    `published/<uid>/<slug>/assets/<id>-<hash>.<ext>` (content-named, so
///    unchanged files are not re-sent and older versions keep their bytes;
///    image sequences as numbered frames);
/// 2. the document, its URIs rewritten to public URLs, goes to
///    `published/<uid>/<slug>/v<n>.stage.json`;
/// 3. the same document in chunks (architecture §17.3): a content-named
///    library chunk and scene chunks (unchanged scenes are not re-sent),
///    and `v<n>.manifest.json` pointing at them;
/// 4. `published/<slug>` points at both, and the story's metadata records
///    the link.
///
/// [cover] renders the link-preview image (PNG); it is uploaded
/// content-named next to the versions. A failed render publishes without
/// one.
///
/// Throws [PublishException] when signed out, the slug is invalid or
/// belongs to someone else. Assets whose bytes are unavailable keep their
/// URI and are listed in `warnings`.
Future<PublishResult> publishStory(
  ir.StageDocument doc, {
  required String storyId,
  required String slug,
  required CloudBackend backend,
  required AssetBytesSource bytesOf,
  Future<Uint8List?> Function()? cover,
}) async {
  final uid = backend.uid;
  if (uid == null) throw const PublishException('Sign in to publish.');
  if (!isValidSlug(slug)) {
    throw const PublishException(
      'Use lowercase letters, digits and dashes for the link.',
    );
  }
  final existing = await backend.published(slug);
  if (existing != null && existing.ownerId != uid) {
    throw PublishException('The link "$slug" is taken. Choose another.');
  }
  final version = (existing?.version ?? 0) + 1;
  final base = 'published/$uid/$slug';
  final warnings = <String>[];

  Future<String> put(String path, Uint8List bytes, String mime) async {
    if (!await backend.exists(path)) await backend.upload(path, bytes, mime);
    return path;
  }

  final assets = <String, ir.Asset>{};
  for (final MapEntry(:key, value: a) in doc.assets.entries) {
    final label = a.name.isEmpty ? a.id : a.name;
    final ext = extensionForMime(a.mime);
    if (a.kind == ir.AssetKind.imageSequence) {
      final count = a.frameCount ?? 0;
      final frames = <Uint8List>[];
      for (var i = 0; i < count; i++) {
        final bytes = await bytesOf(
          a.copyWith(kind: ir.AssetKind.image, uri: ir.sequenceFrameUri(a, i)),
        );
        if (bytes == null) break;
        frames.add(bytes);
      }
      if (count == 0 || frames.length != count) {
        warnings.add('$label: frames are missing, so it was not published.');
        assets[key] = a;
        continue;
      }
      final hash = _short(
        contentHash(
          Uint8List.fromList(utf8.encode(frames.map(contentHash).join())),
        ),
      );
      final pad = count.toString().length.clamp(4, 9);
      final stem = '$base/assets/${a.id}-$hash';
      for (final (i, f) in frames.indexed) {
        await put(
          '${stem}_${(i + 1).toString().padLeft(pad, '0')}.$ext',
          f,
          a.mime,
        );
      }
      // The braces must survive URL encoding: the runtime fills them in.
      const token = 'FRAMENUMBER';
      final pattern = backend
          .publicUrl('${stem}_$token.$ext')
          .replaceFirst(token, '{${'1'.padLeft(pad, '0')}}');
      assets[key] = a.copyWith(uri: pattern);
      continue;
    }
    final bytes = await bytesOf(a);
    if (bytes == null) {
      warnings.add('$label: the file is unavailable, so it was not published.');
      assets[key] = a;
      continue;
    }
    final path = await put(
      '$base/assets/${a.id}-${_short(contentHash(bytes))}.$ext',
      bytes,
      a.mime,
    );
    assets[key] = a.copyWith(uri: backend.publicUrl(path));
  }

  // The author's meta-notes and inspiration board are private.
  final frozen = doc.copyWith(
    assets: assets,
    meta: doc.meta.copyWith(slug: slug),
    notes: const {},
    board: const ir.InspirationBoard(),
  );
  var image = '';
  try {
    final png = await cover?.call();
    if (png != null) {
      image = backend.publicUrl(
        await put(
          '$base/cover-${_short(contentHash(png))}.png',
          png,
          'image/png',
        ),
      );
    }
  } on Object {
    image = ''; // the preview image is optional
  }

  final docPath = '$base/v$version.stage.json';
  await backend.upload(
    docPath,
    Uint8List.fromList(utf8.encode(jsonEncode(frozen.toJson()))),
    'application/json',
  );

  final chunks = splitDocument(frozen);
  Future<String> putJson(String stem, Object? json) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    final path = await put(
      '$stem-${_short(contentHash(bytes))}.json',
      bytes,
      'application/json',
    );
    return backend.publicUrl(path);
  }

  final manifestPath = '$base/v$version.manifest.json';
  final manifest = {
    ...chunks.manifest,
    'library': await putJson('$base/library', chunks.library),
    'chunks': {
      for (final MapEntry(:key, :value) in chunks.scenes.entries)
        key: await putJson('$base/scenes/$key', value),
    },
  };
  await backend.upload(
    manifestPath,
    Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
    'application/json',
  );
  await backend.setPublished(
    slug,
    PublishedRecord(
      ownerId: uid,
      storyId: storyId,
      version: version,
      path: docPath,
      title: doc.meta.title,
      description: doc.meta.description,
      image: image,
      manifest: manifestPath,
    ),
  );
  await backend.setStoryMeta(storyId, {
    'ownerId': uid,
    'title': doc.meta.title,
    'publishedSlug': slug,
    'publishedVersion': version,
  });
  return PublishResult(slug: slug, version: version, warnings: warnings);
}

String _short(String hash) => hash.substring(0, 12);

/// A published story as the player opens it: the whole document, or a
/// chunked one that fills in scene by scene.
sealed class PublishedStory {
  const PublishedStory();
}

class WholePublishedStory extends PublishedStory {
  const WholePublishedStory(this.document);

  final ir.StageDocument document;
}

class ChunkedPublishedStory extends PublishedStory {
  ChunkedPublishedStory(this.chunked, this._fetch);

  final ChunkedDocument chunked;
  final Future<Uint8List> Function(String url) _fetch;
  final Map<String, Future<bool>> _pending = {};

  /// Fetches scene [sceneId]'s chunk once (concurrent calls share it).
  /// Completes with whether the document changed.
  Future<bool> loadScene(String sceneId) {
    if (chunked.isLoaded(sceneId)) return Future.value(false);
    return _pending[sceneId] ??= () async {
      final url = chunked.chunkPath(sceneId);
      if (url == null) return false;
      try {
        final json = jsonDecode(utf8.decode(await _fetch(url)));
        return chunked.addScene((json as Map).cast<String, Object?>());
      } finally {
        unawaited(_pending.remove(sceneId));
      }
    }();
  }
}

/// Opens the published story at [slug] (null when nothing is published
/// there): its manifest and library chunk when the version is chunked,
/// else its whole document. [fetch] gets bytes from a URL.
Future<PublishedStory?> openPublished(
  String slug, {
  required CloudBackend backend,
  required Future<Uint8List> Function(String url) fetch,
}) async {
  final record = await backend.published(slug);
  if (record == null) return null;
  Future<Map<String, Object?>> json(String url) async =>
      (jsonDecode(utf8.decode(await fetch(url))) as Map)
          .cast<String, Object?>();
  if (record.manifest.isNotEmpty) {
    final manifest = await json(backend.publicUrl(record.manifest));
    final library = await json(manifest['library']! as String);
    return ChunkedPublishedStory(
      ChunkedDocument.open(manifest, library),
      fetch,
    );
  }
  final loaded = ir.loadDocument(
    utf8.decode(await fetch(backend.publicUrl(record.path))),
  );
  final doc = loaded.document;
  return doc == null ? null : WholePublishedStory(doc);
}

/// Loads the whole published document at [slug], or null when nothing is
/// published there. [fetch] gets bytes from a URL.
Future<ir.LoadResult?> loadPublished(
  String slug, {
  required CloudBackend backend,
  required Future<Uint8List> Function(String url) fetch,
}) async {
  final record = await backend.published(slug);
  if (record == null) return null;
  final bytes = await fetch(backend.publicUrl(record.path));
  return ir.loadDocument(utf8.decode(bytes));
}
