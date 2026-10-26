import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'local_asset_store.dart';
import 'records.dart';
import 'story_database.dart';

/// How many of the newest revisions are always kept.
const int kKeepRevisions = 50;

/// The revisions to delete under the retention policy: keep the head, the
/// newest [keepLast], and (within [hourlyWindow] of [now]) the newest
/// revision of each clock hour. Pure, so it is tested directly.
Set<int> revisionsToDelete(
  List<RevisionInfo> revisions, {
  required int head,
  required DateTime now,
  int keepLast = kKeepRevisions,
  Duration hourlyWindow = const Duration(days: 1),
}) {
  final sorted = [...revisions]..sort((a, b) => b.rev.compareTo(a.rev));
  final keep = <int>{head};
  for (final r in sorted.take(keepLast)) {
    keep.add(r.rev);
  }
  final windowStart = now.subtract(hourlyWindow).millisecondsSinceEpoch;
  final seenHours = <int>{};
  for (final r in sorted) {
    if (r.savedAt < windowStart) continue;
    final hour = r.savedAt ~/ Duration.millisecondsPerHour;
    if (seenHours.add(hour)) keep.add(r.rev); // newest first = newest per hour
  }
  return {
    for (final r in revisions)
      if (!keep.contains(r.rev)) r.rev,
  };
}

/// Reads a bundled asset file.
typedef BundledBytesLoader = Future<Uint8List> Function(String path);

/// A [StoryRepository] over a [StoryDatabase] (architecture §16, §17.2).
///
/// - **Crash-safe save.** A save writes the new revision in one transaction
///   and then moves the story's `headRevision` in a second, so a failure
///   between the two (or a full disk on the first) leaves the previous head
///   intact. Orphan revisions from a crash are harmless: the next save
///   numbers past them.
/// - **Retention.** The newest [maxRevisions] plus one per hour for the past
///   day ([revisionsToDelete]).
/// - **Loads never throw.** [open] runs `loadDocument` (migrate, parse,
///   validate). When the head cannot be read it falls back to the newest
///   older revision that can, and says so in [StoryLoad.recoveredFromRevision].
/// - **Demos are read-only.** They are listed and open, but saving throws
///   [ReadOnlyStoryException]; [duplicate] copies one (document and assets)
///   into storage.
class DbStoryRepository implements StoryRepository {
  DbStoryRepository(
    this.db, {
    LocalAssetStore? assets,
    AssetTextLoader? loadText,
    BundledBytesLoader? loadBytes,
    DateTime Function()? now,
    this.maxRevisions = kKeepRevisions,
  }) : assets = assets ?? LocalAssetStore(db),
       _loadText = loadText ?? rootBundle.loadString,
       _loadBytes = loadBytes ?? _rootBundleBytes,
       _now = now ?? DateTime.now;

  final StoryDatabase db;
  final LocalAssetStore assets;
  final int maxRevisions;
  final AssetTextLoader _loadText;
  final BundledBytesLoader _loadBytes;
  final DateTime Function() _now;

  /// The JSON last written per story: an identical save is skipped.
  final Map<String, String> _lastSaved = {};
  final Map<String, Future<void>> _chains = {};

  static Future<Uint8List> _rootBundleBytes(String path) async {
    final d = await rootBundle.load(path);
    return d.buffer.asUint8List(d.offsetInBytes, d.lengthInBytes);
  }

  BundledStory? _bundled(String id) {
    for (final b in kBundledStories) {
      if (b.id == id) return b;
    }
    return null;
  }

  int get _nowMs => _now().millisecondsSinceEpoch;

  @override
  bool isReadOnly(String id) => _bundled(id) != null;

  // ---- list / open --------------------------------------------------------

  @override
  Future<List<StorySummary>> list() async {
    final own = await db.listStories()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [
      for (final s in own)
        StorySummary(
          id: s.id,
          title: s.title,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(s.updatedAt),
          sceneCount: s.sceneCount,
        ),
      for (final b in kBundledStories)
        StorySummary(
          id: b.id,
          title: b.title,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          bundled: true,
        ),
    ];
  }

  @override
  Future<ir.StageDocument?> load(String id) async => (await open(id))?.document;

  @override
  Future<StoryLoad?> open(String id) async {
    try {
      final b = _bundled(id);
      if (b != null) {
        final result = ir.loadDocument(await _loadText(b.asset));
        return StoryLoad(
          document: result.document,
          diagnostics: result.diagnostics,
          readOnly: true,
        );
      }
      final story = await db.getStory(id);
      if (story == null) return null;
      final head = await _tryLoad(id, story.headRevision);
      if (head != null) {
        return StoryLoad(
          document: head.document,
          diagnostics: head.diagnostics,
          headRevision: story.headRevision,
        );
      }
      // The head is missing or unreadable: newest older revision that loads.
      final revs = await db.listRevisions(id)
        ..sort((a, b) => b.rev.compareTo(a.rev));
      for (final info in revs) {
        if (info.rev == story.headRevision) continue;
        final r = await _tryLoad(id, info.rev);
        if (r != null) {
          return StoryLoad(
            document: r.document,
            diagnostics: r.diagnostics,
            headRevision: story.headRevision,
            recoveredFromRevision: info.rev,
          );
        }
      }
      return StoryLoad(
        headRevision: story.headRevision,
        diagnostics: const [
          ir.IrDiagnostic(
            ir.IrDiagnosticKind.invalidDocument,
            'No stored revision of this story could be read.',
            location: '',
          ),
        ],
      );
    } on Object catch (e) {
      return StoryLoad(
        diagnostics: [
          ir.IrDiagnostic(
            ir.IrDiagnosticKind.invalidDocument,
            'The story could not be opened: $e',
            location: '',
          ),
        ],
      );
    }
  }

  Future<ir.LoadResult?> _tryLoad(String id, int rev) async {
    final r = await db.getRevision(id, rev);
    if (r == null) return null;
    final result = ir.loadDocument(r.json);
    return result.loaded ? result : null;
  }

  // ---- write --------------------------------------------------------------

  Future<T> _serial<T>(String id, Future<T> Function() body) {
    final prev = _chains[id] ?? Future<void>.value();
    final next = prev.then((_) => body());
    _chains[id] = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  @override
  Future<StorySummary> create({String title = 'Untitled story'}) =>
      _insert(newStoryDocument(title: title));

  @override
  Future<StorySummary> createFrom(ir.StageDocument document) {
    final ids = ir.IdGenerator.forDocument(document);
    return _insert(document.copyWith(id: ids.next()));
  }

  Future<StorySummary> _insert(ir.StageDocument doc) async {
    final json = jsonEncode(doc.toJson());
    final now = _nowMs;
    final title = doc.meta.title.isEmpty ? 'Untitled story' : doc.meta.title;
    // Step 1: the revision. Step 2: the story row that points at it.
    await db.putRevision(
      RevisionRecord(storyId: doc.id, rev: 1, savedAt: now, json: json),
    );
    final record = StoryRecord(
      id: doc.id,
      title: title,
      createdAt: now,
      updatedAt: now,
      headRevision: 1,
      coverAssetId: doc.meta.coverAssetId,
      sceneCount: doc.scenes.length,
    );
    await db.putStory(record);
    _lastSaved[doc.id] = json;
    return StorySummary(
      id: doc.id,
      title: title,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(now),
      sceneCount: doc.scenes.length,
    );
  }

  @override
  Future<void> save(String id, ir.StageDocument document) {
    if (isReadOnly(id)) throw ReadOnlyStoryException(id);
    return _serial(
      id,
      () => _write(id, jsonEncode(document.toJson()), document),
    );
  }

  Future<void> _write(String id, String json, ir.StageDocument document) async {
    final story = await db.getStory(id);
    if (story == null) throw StoryNotFoundException(id);
    if (_lastSaved[id] == json) return;
    final revs = await db.listRevisions(id);
    var top = story.headRevision;
    for (final r in revs) {
      if (r.rev > top) top = r.rev;
    }
    final rev = top + 1;
    final now = _nowMs;
    // Step 1: write the new revision. If this fails (quota, crash) the
    // head still points at the previous revision.
    await db.putRevision(
      RevisionRecord(storyId: id, rev: rev, savedAt: now, json: json),
    );
    // Step 2: move the head pointer.
    await db.putStory(
      story.copyWith(
        title: document.meta.title.isEmpty ? null : document.meta.title,
        updatedAt: now,
        headRevision: rev,
        coverAssetId: document.meta.coverAssetId,
        sceneCount: document.scenes.length,
      ),
    );
    _lastSaved[id] = json;
    // Pruning is housekeeping: a failure must not fail the save.
    try {
      final doomed = revisionsToDelete(
        [...revs, RevisionInfo(rev: rev, savedAt: now, size: json.length)],
        head: rev,
        now: _now(),
        keepLast: maxRevisions,
      );
      if (doomed.isNotEmpty) await db.deleteRevisions(id, doomed);
    } on Object {
      // Retried by the next save.
    }
  }

  @override
  Future<void> rename(String id, String title) async {
    if (isReadOnly(id)) throw ReadOnlyStoryException(id);
    final story = await db.getStory(id);
    if (story == null) throw StoryNotFoundException(id);
    final loaded = await open(id);
    final doc = loaded?.document;
    if (doc != null && !loaded!.recovered) {
      await save(id, doc.copyWith(meta: doc.meta.copyWith(title: title)));
    } else {
      await db.putStory(story.copyWith(title: title, updatedAt: _nowMs));
    }
  }

  @override
  Future<void> delete(String id) async {
    if (isReadOnly(id)) return;
    await _serial(id, () async {
      await db.deleteStory(id);
      _lastSaved.remove(id);
    });
  }

  // ---- revisions ----------------------------------------------------------

  @override
  Future<List<RevisionInfo>> revisions(String id) async {
    if (isReadOnly(id)) return const [];
    return (await db.listRevisions(id))..sort((a, b) => b.rev.compareTo(a.rev));
  }

  @override
  Future<void> restore(String id, int rev) async {
    if (isReadOnly(id)) throw ReadOnlyStoryException(id);
    final r = await db.getRevision(id, rev);
    if (r == null) throw StoryNotFoundException('$id@$rev');
    final result = ir.loadDocument(r.json);
    final doc = result.document;
    if (doc == null) {
      throw StateError(
        'Revision $rev cannot be read, so it cannot be restored.',
      );
    }
    _lastSaved.remove(id); // restoring the head's twin must still write
    await save(id, doc);
  }

  // ---- duplicate ----------------------------------------------------------

  @override
  Future<StorySummary> duplicate(String id) async {
    final loaded = await open(id);
    final doc = loaded?.document;
    if (doc == null) throw StoryNotFoundException(id);
    final bundled = _bundled(id);
    final assetsOut = <String, ir.Asset>{};
    for (final entry in doc.assets.entries) {
      final a = entry.value;
      final path = _assetPath(a.uri);
      if (path == null || a.kind == ir.AssetKind.imageSequence) {
        // Already local:// or remote; bundled sequences stay asset://.
        assetsOut[entry.key] = a;
        continue;
      }
      try {
        assetsOut[entry.key] = await assets.putExisting(
          a,
          await _loadBytes(path),
        );
      } on StorageFullException {
        rethrow;
      } on Object {
        assetsOut[entry.key] = a; // stays an asset:// reference
      }
    }
    final title = bundled != null ? doc.meta.title : '${doc.meta.title} copy';
    return createFrom(
      doc.copyWith(
        assets: assetsOut,
        meta: doc.meta.copyWith(
          title: title.trim().isEmpty ? 'Untitled story' : title,
        ),
      ),
    );
  }

  static String? _assetPath(String uri) =>
      uri.startsWith('asset://') ? uri.substring('asset://'.length) : null;

  /// Bytes of an asset for export: from storage, or from the app bundle.
  Future<Uint8List?> assetBytes(ir.Asset asset) async {
    final localId = asset.uri.startsWith('local://')
        ? asset.uri.substring('local://'.length)
        : null;
    if (localId != null) return assets.get(localId);
    final path = _assetPath(asset.uri);
    if (path != null) {
      try {
        return await _loadBytes(path);
      } on Object {
        return null;
      }
    }
    return null;
  }

  /// Browser storage usage and quota.
  Future<StorageEstimate?> storageEstimate() => db.estimate();
}
