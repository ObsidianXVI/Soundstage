import 'dart:typed_data';

import 'records.dart';

/// The storage engine under the story repository: three object stores
/// (`stories`, `revisions`, `assets`) with single-purpose operations.
///
/// Each method is one atomic transaction. [IndexedDbStoryDatabase] is the
/// browser implementation; [MemoryStoryDatabase] backs the VM tests and the
/// fallback when IndexedDB is unavailable.
abstract interface class StoryDatabase {
  Future<List<StoryRecord>> listStories();
  Future<StoryRecord?> getStory(String id);

  /// Inserts or replaces the metadata row. Moving [StoryRecord.headRevision]
  /// is a `putStory`.
  Future<void> putStory(StoryRecord record);

  /// Deletes the story row and all of its revisions in one transaction.
  Future<void> deleteStory(String id);

  Future<List<ProjectRecord>> listProjects();
  Future<ProjectRecord?> getProject(String id);
  Future<void> putProject(ProjectRecord record);
  Future<void> deleteProject(String id);

  Future<void> putRevision(RevisionRecord record);
  Future<RevisionRecord?> getRevision(String storyId, int rev);

  /// The revisions of [storyId], ascending by `rev`, without their documents.
  Future<List<RevisionInfo>> listRevisions(String storyId);
  Future<void> deleteRevisions(String storyId, Iterable<int> revs);

  Future<void> putAsset(AssetRecord record);
  Future<AssetRecord?> getAsset(String id);
  Future<List<AssetMeta>> listAssets();
  Future<void> deleteAssets(Iterable<String> ids);

  /// Browser usage and quota, or null where unknown.
  Future<StorageEstimate?> estimate();

  void close();
}

/// A [StoryDatabase] in memory. Throws [StorageFullException] when a write
/// would exceed [quotaBytes].
class MemoryStoryDatabase implements StoryDatabase {
  MemoryStoryDatabase({this.quotaBytes});

  /// A byte budget for revisions and assets together; null = unlimited.
  int? quotaBytes;

  final Map<String, StoryRecord> _stories = {};
  final Map<String, ProjectRecord> _projects = {};
  final Map<String, Map<int, RevisionRecord>> _revisions = {};
  final Map<String, AssetRecord> _assets = {};

  int get usedBytes {
    var n = 0;
    for (final r in _revisions.values) {
      for (final v in r.values) {
        n += v.size;
      }
    }
    for (final a in _assets.values) {
      n += a.bytes.length;
    }
    return n;
  }

  void _checkQuota(int adding) {
    final q = quotaBytes;
    if (q != null && usedBytes + adding > q) throw const StorageFullException();
  }

  @override
  Future<List<StoryRecord>> listStories() async => _stories.values.toList();

  @override
  Future<StoryRecord?> getStory(String id) async => _stories[id];

  @override
  Future<void> putStory(StoryRecord record) async =>
      _stories[record.id] = record;

  @override
  Future<void> deleteStory(String id) async {
    _stories.remove(id);
    _revisions.remove(id);
  }

  @override
  Future<List<ProjectRecord>> listProjects() async => _projects.values.toList();

  @override
  Future<ProjectRecord?> getProject(String id) async => _projects[id];

  @override
  Future<void> putProject(ProjectRecord record) async =>
      _projects[record.id] = record;

  @override
  Future<void> deleteProject(String id) async => _projects.remove(id);

  @override
  Future<void> putRevision(RevisionRecord record) async {
    _checkQuota(record.size);
    (_revisions[record.storyId] ??= {})[record.rev] = record;
  }

  @override
  Future<RevisionRecord?> getRevision(String storyId, int rev) async =>
      _revisions[storyId]?[rev];

  @override
  Future<List<RevisionInfo>> listRevisions(String storyId) async {
    final revs = _revisions[storyId]?.values.toList() ?? const [];
    return [
      for (final r in revs)
        RevisionInfo(rev: r.rev, savedAt: r.savedAt, size: r.size),
    ]..sort((a, b) => a.rev.compareTo(b.rev));
  }

  @override
  Future<void> deleteRevisions(String storyId, Iterable<int> revs) async {
    final m = _revisions[storyId];
    if (m == null) return;
    for (final r in revs) {
      m.remove(r);
    }
  }

  @override
  Future<void> putAsset(AssetRecord record) async {
    _checkQuota(record.bytes.length);
    _assets[record.meta.id] = record;
  }

  @override
  Future<AssetRecord?> getAsset(String id) async => _assets[id];

  @override
  Future<List<AssetMeta>> listAssets() async => [
    for (final a in _assets.values) a.meta,
  ];

  @override
  Future<void> deleteAssets(Iterable<String> ids) async {
    for (final id in ids) {
      _assets.remove(id);
    }
  }

  @override
  Future<StorageEstimate?> estimate() async =>
      StorageEstimate(usage: usedBytes, quota: quotaBytes);

  @override
  void close() {}

  /// Test hook: replaces the stored JSON of a revision (to corrupt it).
  void corruptRevision(String storyId, int rev, String json) {
    final old = _revisions[storyId]![rev]!;
    _revisions[storyId]![rev] = RevisionRecord(
      storyId: storyId,
      rev: rev,
      savedAt: old.savedAt,
      json: json,
    );
  }

  /// Test hook: the raw bytes of an asset, for round-trip checks.
  Uint8List? assetBytes(String id) => _assets[id]?.bytes;
}
