import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// A story as listed on the home page.
class StorySummary {
  const StorySummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.sceneCount,
    this.bundled = false,
  });

  final String id;
  final String title;
  final DateTime updatedAt;

  /// Null when the document has not been loaded yet.
  final int? sceneCount;

  /// A bundled demo story (listed alongside the author's own).
  final bool bundled;
}

/// Where stories live. T1.1 ships the in-memory implementation; T1.11
/// replaces it with IndexedDB persistence behind this same interface.
///
/// Implementations never throw from [load] for a missing story (they return
/// null).
abstract interface class StoryRepository {
  /// All stories, most recently updated first.
  Future<List<StorySummary>> list();

  /// The document for [id], or null if there is none.
  Future<ir.StageDocument?> load(String id);

  /// Creates a blank story and returns its summary.
  Future<StorySummary> create({String title = 'Untitled story'});

  /// Stores [document] as the new content of [id].
  Future<void> save(String id, ir.StageDocument document);

  Future<void> rename(String id, String title);

  Future<void> delete(String id);
}

/// A bundled demo story: route id, title and asset path.
class BundledStory {
  const BundledStory(this.name, this.title, this.asset);

  final String name;
  final String title;
  final String asset;

  /// The story id used in `/edit/:id` and `/play/:id`.
  String get id => 'demo-$name';
}

/// The bundled demos (`/demo/:name`), also listed as stories.
const List<BundledStory> kBundledStories = <BundledStory>[
  BundledStory('static', 'Static layout demo', 'assets/demo/static.stage.json'),
  BundledStory(
    'gallery',
    'Paint gallery',
    'assets/demo/paint_gallery.stage.json',
  ),
  BundledStory('motion', 'Motion demo', 'assets/demo/motion.stage.json'),
  BundledStory(
    'sound',
    'Lights Go Low (sound)',
    'assets/demo/sound.stage.json',
  ),
  BundledStory(
    'spike',
    'The Hour Between (spike)',
    'assets/demo/spike.stage.json',
  ),
];

/// Reads a bundled asset as text.
typedef AssetTextLoader = Future<String> Function(String path);

/// Keeps stories in memory for the session; bundled demos load from assets
/// on first use. Nothing survives a reload (T1.11).
class InMemoryStoryRepository implements StoryRepository {
  InMemoryStoryRepository({
    AssetTextLoader? loadAsset,
    DateTime Function()? now,
  }) : _loadAsset = loadAsset ?? rootBundle.loadString,
       _now = now ?? DateTime.now;

  final AssetTextLoader _loadAsset;
  final DateTime Function() _now;
  final Map<String, ir.StageDocument> _docs = <String, ir.StageDocument>{};
  final Map<String, StorySummary> _own = <String, StorySummary>{};
  final Map<String, String> _renamed = <String, String>{};
  final Set<String> _deletedBundled = <String>{};

  BundledStory? _bundled(String id) {
    for (final b in kBundledStories) {
      if (b.id == id) return b;
    }
    return null;
  }

  @override
  Future<List<StorySummary>> list() async {
    final own = _own.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return <StorySummary>[
      for (final s in own) s,
      for (final b in kBundledStories)
        if (!_deletedBundled.contains(b.id))
          StorySummary(
            id: b.id,
            title: _renamed[b.id] ?? b.title,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
            sceneCount: _docs[b.id]?.scenes.length,
            bundled: true,
          ),
    ];
  }

  @override
  Future<ir.StageDocument?> load(String id) async {
    final cached = _docs[id];
    if (cached != null) return cached;
    final b = _bundled(id);
    if (b == null || _deletedBundled.contains(id)) return null;
    final json = jsonDecode(await _loadAsset(b.asset)) as Map<String, Object?>;
    return _docs[id] = ir.StageDocument.fromJsonMigrating(json);
  }

  @override
  Future<StorySummary> create({String title = 'Untitled story'}) async {
    final doc = ir.StageDocument.empty(
      ids: ir.IdGenerator(),
      meta: ir.StageMeta(title: title),
    );
    final summary = StorySummary(
      id: doc.id,
      title: title,
      updatedAt: _now(),
      sceneCount: 0,
    );
    _docs[doc.id] = doc;
    _own[doc.id] = summary;
    return summary;
  }

  @override
  Future<void> save(String id, ir.StageDocument document) async {
    _docs[id] = document;
    final own = _own[id];
    if (own != null) {
      _own[id] = StorySummary(
        id: id,
        title: document.meta.title.isEmpty ? own.title : document.meta.title,
        updatedAt: _now(),
        sceneCount: document.scenes.length,
      );
    }
  }

  @override
  Future<void> rename(String id, String title) async {
    final own = _own[id];
    if (own != null) {
      _own[id] = StorySummary(
        id: id,
        title: title,
        updatedAt: _now(),
        sceneCount: own.sceneCount,
      );
    } else if (_bundled(id) != null) {
      _renamed[id] = title;
    }
  }

  @override
  Future<void> delete(String id) async {
    _own.remove(id);
    _docs.remove(id);
    if (_bundled(id) != null) _deletedBundled.add(id);
  }
}

/// The repository for the session. T1.11 swaps the implementation here.
final storyRepositoryProvider = Provider<StoryRepository>(
  (ref) => InMemoryStoryRepository(),
);

/// Bumped after every create / rename / delete so the list refreshes.
class StoryListRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

final storyListRevisionProvider = NotifierProvider<StoryListRevision, int>(
  StoryListRevision.new,
);

/// The story list.
final storyListProvider = FutureProvider<List<StorySummary>>((ref) {
  ref.watch(storyListRevisionProvider);
  return ref.watch(storyRepositoryProvider).list();
});

/// The story with the given id (the "current story" of a route), or null if
/// there is none.
final storyDocumentProvider = FutureProvider.family<ir.StageDocument?, String>((
  ref,
  id,
) {
  return ref.watch(storyRepositoryProvider).load(id);
});
