import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:soundstage_platform/editor/clipboard/content_hash.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../persistence/local_asset_store.dart' show extensionForMime;
import '../persistence/story_package.dart' show AssetBytesSource;
import 'chunks.dart';
import 'targets.dart';

export 'targets.dart';

/// One frozen version of a published story (m7.md T7.3).
class PublishedVersion {
  const PublishedVersion({
    required this.version,
    required this.path,
    this.manifest = '',
    this.title = '',
    this.description = '',
    this.image = '',
    this.publishedAt = 0,
  });

  factory PublishedVersion.fromMap(Map<String, Object?> m) => PublishedVersion(
    version: (m['version']! as num).toInt(),
    path: m['path']! as String,
    manifest: (m['manifest'] as String?) ?? '',
    title: (m['title'] as String?) ?? '',
    description: (m['description'] as String?) ?? '',
    image: (m['image'] as String?) ?? '',
    publishedAt: (m['publishedAt'] as num?)?.toInt() ?? 0,
  );

  final int version;

  /// The document's Storage path (`…/v<n>.stage.json`).
  final String path;

  /// The Storage path of the chunked manifest (`…/v<n>.manifest.json`).
  final String manifest;
  final String title;
  final String description;

  /// The public URL of the link-preview image (the first scene's poster),
  /// or empty.
  final String image;

  /// Milliseconds since the epoch (UTC).
  final int publishedAt;

  Map<String, Object?> toMap() => {
    'version': version,
    'path': path,
    'manifest': manifest,
    'title': title,
    'description': description,
    'image': image,
    'publishedAt': publishedAt,
  };
}

/// The most versions a record lists (older files stay in Storage).
const int kMaxListedVersions = 100;

/// The public record of a published story (Firestore at
/// [PublishTarget.docPath]): who owns it, which story, the live version
/// (its fields copied to the top level for readers and link previews) and
/// the version history (DECISIONS 26/10/26 "Releases").
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
    this.latest = 0,
    this.versions = const [],
  });

  factory PublishedRecord.fromMap(Map<String, Object?> m) {
    final version = (m['version']! as num).toInt();
    return PublishedRecord(
      ownerId: m['ownerId']! as String,
      storyId: m['storyId']! as String,
      version: version,
      path: m['path']! as String,
      title: (m['title'] as String?) ?? '',
      description: (m['description'] as String?) ?? '',
      image: (m['image'] as String?) ?? '',
      manifest: (m['manifest'] as String?) ?? '',
      latest: (m['latest'] as num?)?.toInt() ?? version,
      versions: [
        for (final v in (m['versions'] as List?) ?? const [])
          if (v is Map) PublishedVersion.fromMap(v.cast<String, Object?>()),
      ],
    );
  }

  final String ownerId;
  final String storyId;

  /// The live version.
  final int version;

  /// The live document's Storage path.
  final String path;
  final String title;
  final String description;
  final String image;

  /// The live manifest's Storage path, or empty for an unchunked version.
  final String manifest;

  /// The newest version published (the next is `latest + 1`).
  final int latest;

  /// Every listed version, oldest first.
  final List<PublishedVersion> versions;

  /// This record with [v] live.
  PublishedRecord withLive(PublishedVersion v) => PublishedRecord(
    ownerId: ownerId,
    storyId: storyId,
    version: v.version,
    path: v.path,
    title: v.title,
    description: v.description,
    image: v.image,
    manifest: v.manifest,
    latest: latest,
    versions: versions,
  );

  Map<String, Object?> toMap() => {
    'ownerId': ownerId,
    'storyId': storyId,
    'version': version,
    'path': path,
    'title': title,
    'description': description,
    'image': image,
    'manifest': manifest,
    'latest': latest,
    'versions': [for (final v in versions) v.toMap()],
  };
}

/// A published story or publication in a handle's listing.
class SiteEntry {
  const SiteEntry({
    required this.route,
    required this.title,
    this.description = '',
    this.image = '',
    this.issueCount = 0,
  });

  final String route;
  final String title;
  final String description;
  final String image;

  /// For a publication: how many issues it lists.
  final int issueCount;
}

/// What a handle has published (`/@<handle>`).
class SiteListing {
  const SiteListing({
    required this.handle,
    this.name = '',
    this.publications = const [],
    this.drafts = const [],
  });

  final String handle;
  final String name;
  final List<SiteEntry> publications;
  final List<SiteEntry> drafts;
}

/// What publishing needs from the backend (Firebase in the app, a fake in
/// tests). Paths are Storage object paths; see `infra/firebase/*.rules`.
abstract interface class CloudBackend {
  /// The signed-in author, or null.
  String? get uid;

  /// The signed-in author's handle, or null when none is chosen yet.
  Future<String?> handle();

  /// Claims [handle] for the signed-in author (once). Throws
  /// [PublishException] when it is taken.
  Future<void> claimHandle(String handle, {String name = ''});

  Future<bool> exists(String path);

  Future<void> upload(String path, Uint8List bytes, String mime);

  /// A URL anyone can GET [path] at (published files are public-read).
  String publicUrl(String path);

  Future<PublishedRecord?> published(PublishTarget target);

  Future<void> setPublished(PublishTarget target, PublishedRecord record);

  /// The author's story metadata (`stories/{storyId}`), merged.
  Future<void> setStoryMeta(String storyId, Map<String, Object?> data);

  /// Where story [storyId] was last published, or null.
  Future<PublishTarget?> publishedTargetOf(String storyId);

  /// The publication at [ref], or null.
  Future<SeriesRecord?> series(PublicationRef ref);

  Future<void> setSeries(PublicationRef ref, SeriesRecord record);

  /// The signed-in author's publication of project [projectId], or null.
  Future<PublicationRef?> publicationOf(String projectId);

  /// What [handle] has published, or null for an unknown handle.
  Future<SiteListing?> site(String handle);
}

/// One published issue in a publication.
class SeriesIssue {
  const SeriesIssue({
    required this.slug,
    required this.title,
    this.description = '',
    this.image = '',
  });

  factory SeriesIssue.fromMap(Map<String, Object?> m) => SeriesIssue(
    slug: m['slug']! as String,
    title: (m['title'] as String?) ?? '',
    description: (m['description'] as String?) ?? '',
    image: (m['image'] as String?) ?? '',
  );

  /// The issue's slug within its publication.
  final String slug;
  final String title;
  final String description;
  final String image;

  Map<String, Object?> toMap() => {
    'slug': slug,
    'title': title,
    'description': description,
    'image': image,
  };
}

/// A project's publication (Firestore [PublicationRef.docPath],
/// `/@<handle>/<pub>`): its published issues, newest first (DECISIONS
/// 26/10/26 #11: a series or newsletter routine).
class SeriesRecord {
  const SeriesRecord({
    required this.ownerId,
    required this.projectId,
    required this.title,
    this.issues = const [],
  });

  factory SeriesRecord.fromMap(Map<String, Object?> m) => SeriesRecord(
    ownerId: m['ownerId']! as String,
    projectId: m['projectId']! as String,
    title: (m['title'] as String?) ?? '',
    issues: [
      for (final i in (m['issues'] as List?) ?? const [])
        if (i is Map) SeriesIssue.fromMap(i.cast<String, Object?>()),
    ],
  );

  final String ownerId;
  final String projectId;
  final String title;
  final List<SeriesIssue> issues;

  Map<String, Object?> toMap() => {
    'ownerId': ownerId,
    'projectId': projectId,
    'title': title,
    'issues': [for (final i in issues) i.toMap()],
  };
}

/// Throws [PublishException] unless the signed-in author owns [handle].
/// Returns the author's uid.
Future<String> _requireHandle(CloudBackend backend, String handle) async {
  final uid = backend.uid;
  if (uid == null) throw const PublishException('Sign in to publish.');
  final own = await backend.handle();
  if (own == null) throw const PublishException('Choose a handle first.');
  if (own != handle) {
    throw PublishException('@$handle is not your handle.');
  }
  return uid;
}

/// Publishes (or refreshes) project [projectId]'s publication at [ref]:
/// the issues among [issueIds] that are published in it, in the given
/// order (newest first). Throws [PublishException] when signed out, the
/// slug is invalid or the publication belongs to another project.
Future<SeriesRecord> publishSeries({
  required String projectId,
  required String title,
  required PublicationRef ref,
  required List<String> issueIds,
  required CloudBackend backend,
}) async {
  final uid = await _requireHandle(backend, ref.handle);
  if (!isValidPublication(ref.slug)) {
    throw const PublishException(
      'Use lowercase letters, digits and dashes for the link.',
    );
  }
  final existing = await backend.series(ref);
  if (existing != null &&
      (existing.ownerId != uid || existing.projectId != projectId)) {
    throw PublishException(
      'You already use "${ref.slug}" for another project. Choose another.',
    );
  }
  final issues = <SeriesIssue>[];
  for (final id in issueIds) {
    final target = await backend.publishedTargetOf(id);
    if (target is! IssueTarget || target.publication != ref) continue;
    final r = await backend.published(target);
    if (r == null || r.ownerId != uid) continue;
    issues.add(
      SeriesIssue(
        slug: target.slug,
        title: r.title,
        description: r.description,
        image: r.image,
      ),
    );
  }
  final record = SeriesRecord(
    ownerId: uid,
    projectId: projectId,
    title: title,
    issues: issues,
  );
  await backend.setSeries(ref, record);
  return record;
}

class PublishException implements Exception {
  const PublishException(this.message);

  final String message;

  @override
  String toString() => message;
}

class PublishResult {
  const PublishResult({
    required this.target,
    required this.version,
    this.warnings = const [],
  });

  final PublishTarget target;
  final int version;
  final List<String> warnings;

  /// The reader's route, relative to the site.
  String get path => target.route;
}

/// Publishes [doc] (story [storyId]) at [target] as the next frozen
/// version and makes it live (architecture §16, m4.md T4.2, m7.md T7.3):
///
/// 1. every asset is uploaded once under `<prefix>/assets/<id>-<hash>.<ext>`
///    (content-named, so unchanged files are not re-sent and older versions
///    keep their bytes; image sequences as numbered frames), where
///    `<prefix>` is [PublishTarget.storagePrefix];
/// 2. the document, its URIs rewritten to public URLs, goes to
///    `<prefix>/v<n>.stage.json`;
/// 3. the same document in chunks (architecture §17.3): a content-named
///    library chunk and scene chunks (unchanged scenes are not re-sent),
///    and `v<n>.manifest.json` pointing at them;
/// 4. the record at [PublishTarget.docPath] adds the version and points at
///    it, and the story's metadata records the target.
///
/// [cover] renders the link-preview image (PNG); it is uploaded
/// content-named next to the versions. A failed render publishes without
/// one.
///
/// Throws [PublishException] when signed out, the handle is not the
/// author's, the slug is invalid or another story is published there.
/// Assets whose bytes are unavailable keep their URI and are listed in
/// `warnings`.
Future<PublishResult> publishStory(
  ir.StageDocument doc, {
  required String storyId,
  required PublishTarget target,
  required CloudBackend backend,
  required AssetBytesSource bytesOf,
  Future<Uint8List?> Function()? cover,
  DateTime? now,
}) async {
  final uid = await _requireHandle(backend, target.handle);
  final slug = target.slug;
  if (!isValidSlug(slug) ||
      (target is IssueTarget && !isValidPublication(target.publication.slug))) {
    throw const PublishException(
      'Use lowercase letters, digits and dashes for the link.',
    );
  }
  final existing = await backend.published(target);
  if (existing != null &&
      (existing.ownerId != uid || existing.storyId != storyId)) {
    throw PublishException(
      'Another story is published at "$slug". Choose another link.',
    );
  }
  final version = (existing?.latest ?? 0) + 1;
  final base = target.storagePrefix(uid);
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
    annotations: const [],
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
  final published = PublishedVersion(
    version: version,
    path: docPath,
    manifest: manifestPath,
    title: doc.meta.title,
    description: doc.meta.description,
    image: image,
    publishedAt: (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
  );
  final versions = [...?existing?.versions, published];
  await backend.setPublished(
    target,
    PublishedRecord(
      ownerId: uid,
      storyId: storyId,
      version: version,
      path: docPath,
      latest: version,
      versions: versions.length > kMaxListedVersions
          ? versions.sublist(versions.length - kMaxListedVersions)
          : versions,
    ).withLive(published),
  );
  await backend.setStoryMeta(storyId, {
    'ownerId': uid,
    'title': doc.meta.title,
    'published': target.toMap(),
    'publishedVersion': version,
  });
  return PublishResult(target: target, version: version, warnings: warnings);
}

/// Makes [version] of the story at [target] live (DECISIONS 26/10/26
/// "Releases"): the record points at it; nothing is rebuilt. Throws
/// [PublishException] when it is not the author's or the version is not
/// listed.
Future<PublishedRecord> makeLive(
  PublishTarget target,
  int version, {
  required CloudBackend backend,
}) async {
  final uid = await _requireHandle(backend, target.handle);
  final record = await backend.published(target);
  if (record == null || record.ownerId != uid) {
    throw const PublishException('This story is not published.');
  }
  final v = record.versions.where((v) => v.version == version).firstOrNull;
  if (v == null) {
    throw PublishException('Version $version is no longer listed.');
  }
  final live = record.withLive(v);
  await backend.setPublished(target, live);
  return live;
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

/// Opens the live version at [target] (null when nothing is published
/// there): its manifest and library chunk when the version is chunked,
/// else its whole document. [fetch] gets bytes from a URL.
Future<PublishedStory?> openPublished(
  PublishTarget target, {
  required CloudBackend backend,
  required Future<Uint8List> Function(String url) fetch,
}) async {
  final record = await backend.published(target);
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

/// Loads the whole live document at [target], or null when nothing is
/// published there. [fetch] gets bytes from a URL.
Future<ir.LoadResult?> loadPublished(
  PublishTarget target, {
  required CloudBackend backend,
  required Future<Uint8List> Function(String url) fetch,
}) async {
  final record = await backend.published(target);
  if (record == null) return null;
  final bytes = await fetch(backend.publicUrl(record.path));
  return ir.loadDocument(utf8.decode(bytes));
}
