import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../persistence/records.dart' show RevisionInfo, StoryNotFoundException;

export '../persistence/records.dart'
    show
        ReadOnlyStoryException,
        RevisionInfo,
        StorageFullException,
        StoryNotFoundException;

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

/// The outcome of opening a story: the document plus what the load found
/// (architecture §17.2: documents never fail to open).
class StoryLoad {
  const StoryLoad({
    this.document,
    this.diagnostics = const [],
    this.headRevision,
    this.recoveredFromRevision,
    this.readOnly = false,
  });

  /// Null only when neither the head nor any older revision could be read.
  final ir.StageDocument? document;

  /// Findings of `loadDocument` for the revision that was opened.
  final List<ir.IrDiagnostic> diagnostics;

  /// The revision that was opened (null for bundled demos).
  final int? headRevision;

  /// Set when the stored head could not be read and this older revision was
  /// opened instead. The caller should tell the author.
  final int? recoveredFromRevision;

  /// Bundled demos open read-only.
  final bool readOnly;

  bool get recovered => recoveredFromRevision != null;
}

/// Where stories live: [InMemoryStoryRepository] for tests and as the
/// fallback when browser storage is unavailable, `IndexedDbStoryRepository`
/// (T1.11) in the app.
///
/// Implementations never throw from [load] or [open] for a missing or
/// corrupt story (they return null or a [StoryLoad] without a document).
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

  /// Opens [id] with diagnostics and recovery information, or null if there
  /// is no such story. Never throws.
  Future<StoryLoad?> open(String id);

  /// Whether [id] cannot be saved to (bundled demos).
  bool isReadOnly(String id);

  /// The stored revisions of [id], newest first. Empty where the repository
  /// keeps no history.
  Future<List<RevisionInfo>> revisions(String id);

  /// Makes revision [rev] the current one by saving its content as a new
  /// revision (history is never rewritten).
  Future<void> restore(String id, int rev);

  /// Copies [id] (a demo or one of the author's stories) into a new story
  /// with its own id, including its assets.
  Future<StorySummary> duplicate(String id);

  /// Stores [document] as a new story with a fresh id and returns it.
  Future<StorySummary> createFrom(ir.StageDocument document);
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

  @override
  Future<StoryLoad?> open(String id) async {
    final doc = await load(id);
    if (doc == null) return null;
    return StoryLoad(document: doc, diagnostics: ir.validateDocument(doc));
  }

  @override
  bool isReadOnly(String id) => false;

  @override
  Future<List<RevisionInfo>> revisions(String id) async => const [];

  @override
  Future<void> restore(String id, int rev) async {}

  @override
  Future<StorySummary> duplicate(String id) async {
    final doc = await load(id);
    if (doc == null) throw StoryNotFoundException(id);
    final title = _own[id]?.title ?? _renamed[id] ?? doc.meta.title;
    return createFrom(doc.copyWith(meta: doc.meta.copyWith(title: title)));
  }

  @override
  Future<StorySummary> createFrom(ir.StageDocument document) async {
    final id = ir.IdGenerator().next();
    final doc = document.copyWith(id: id);
    final summary = StorySummary(
      id: id,
      title: doc.meta.title.isEmpty ? 'Untitled story' : doc.meta.title,
      updatedAt: _now(),
      sceneCount: doc.scenes.length,
    );
    _docs[id] = doc;
    _own[id] = summary;
    return summary;
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

/// Writes still in flight per story (the editor's final autosave flush when
/// it closes). Story loads wait for them, so reopening a story right after
/// leaving the editor reads what was saved.
class StoryWriteBarrier {
  final Map<String, Future<void>> _pending = {};

  /// Registers [write] for story [id] until it completes.
  void track(String id, Future<void> write) {
    final prev = _pending[id];
    final all = prev == null ? write : Future.wait([prev, write]).then((_) {});
    final guarded = all.catchError((Object _) {});
    _pending[id] = guarded;
    guarded.whenComplete(() {
      if (identical(_pending[id], guarded)) _pending.remove(id);
    });
  }

  /// Completes when no write of [id] is in flight.
  Future<void> wait(String id) => _pending[id] ?? Future<void>.value();
}

final storyWriteBarrierProvider = Provider<StoryWriteBarrier>(
  (ref) => StoryWriteBarrier(),
);

/// The story with the given id (the "current story" of a route), or null if
/// there is none.
final storyDocumentProvider = FutureProvider.family<ir.StageDocument?, String>((
  ref,
  id,
) async {
  await ref.read(storyWriteBarrierProvider).wait(id);
  return ref.watch(storyRepositoryProvider).load(id);
});

/// The story with load details (diagnostics, recovery from an older
/// revision), or null if there is none.
final storyLoadProvider = FutureProvider.family<StoryLoad?, String>((
  ref,
  id,
) async {
  await ref.read(storyWriteBarrierProvider).wait(id);
  return ref.watch(storyRepositoryProvider).open(id);
});
