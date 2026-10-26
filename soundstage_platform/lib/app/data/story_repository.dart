import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../persistence/records.dart' show RevisionInfo, StoryNotFoundException;
import 'project_library.dart';

export '../persistence/records.dart'
    show
        ReadOnlyStoryException,
        RevisionInfo,
        StorageFullException,
        StoryNotFoundException;

/// A story as listed on the home page.
/// The document of a new story: the default breakpoints and one blank
/// pinned scene (DECISIONS 25/10/26 T1.12-1: new stories do not start
/// empty).
ir.StageDocument newStoryDocument({String title = 'Untitled story'}) {
  final ids = ir.IdGenerator();
  final doc = ir.StageDocument.empty(
    ids: ids,
    meta: ir.StageMeta(title: title),
  );
  return doc.copyWith(
    scenes: [
      ir.Scene.blankPinned(
        ids: ids,
        breakpoint: doc.breakpoints.first,
        name: 'Scene 1',
      ),
    ],
  );
}

class StorySummary {
  const StorySummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.sceneCount,
    this.bundled = false,
    this.projectId,
  });

  final String id;
  final String title;
  final DateTime updatedAt;

  /// The project this draft is an issue of; null for a standalone draft.
  final String? projectId;

  /// Null when the document has not been loaded yet.
  final int? sceneCount;

  /// A bundled demo story (listed alongside the author's own).
  final bool bundled;
}

/// A project as listed (DECISIONS 26/10/26 #11): many drafts (issues)
/// sharing one library.
class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.issueCount = 0,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final int issueCount;
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

  // ---- Projects (DECISIONS 26/10/26 #11) ---------------------------------

  /// All projects, most recently updated first.
  Future<List<ProjectSummary>> projects();

  Future<ProjectSummary> createProject({String title = 'Untitled project'});

  Future<void> renameProject(String id, String title);

  /// Deletes the project and every issue in it.
  Future<void> deleteProject(String id);

  /// Adds an issue to project [projectId]: a copy of issue [fromStoryId]
  /// (the template: same scenes and design, new ids), or else a blank
  /// issue with the project's library.
  Future<StorySummary> createIssue(
    String projectId, {
    String? fromStoryId,
    String? title,
  });

  /// Moves a standalone draft into project [projectId] (its library becomes
  /// the project's when the project has none yet).
  Future<void> moveToProject(String storyId, String projectId);
}

/// The next issue's title in a project with [count] issues.
String issueTitle(int count) => 'Issue ${count + 1}';

/// [doc] as the start of a new issue: a new document id (node, scene and
/// asset ids are scoped to a document, so they stay), titled [title],
/// without the source's link or notes.
ir.StageDocument issueCopy(ir.StageDocument doc, {required String title}) {
  final ids = ir.IdGenerator();
  return doc.copyWith(
    id: ids.next(),
    meta: doc.meta.copyWith(title: title, slug: ''),
    notes: const {},
  );
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
  final Map<String, ProjectSummary> _projects = {};
  final Map<String, ProjectLibrary> _libraries = {};

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
    final doc = newStoryDocument(title: title);
    final summary = StorySummary(
      id: doc.id,
      title: title,
      updatedAt: _now(),
      sceneCount: doc.scenes.length,
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
        projectId: own.projectId,
      );
      if (own.projectId case final pid?) {
        _libraries[pid] = ProjectLibrary.of(document);
      }
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
        projectId: own.projectId,
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
    var doc = await load(id);
    if (doc == null) return null;
    final library = _libraries[_own[id]?.projectId];
    if (library != null) doc = library.applyTo(doc);
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
  Future<StorySummary> createFrom(ir.StageDocument document) => _add(document);

  Future<StorySummary> _add(
    ir.StageDocument document, {
    String? projectId,
  }) async {
    final id = ir.IdGenerator().next();
    final doc = document.copyWith(id: id);
    final summary = StorySummary(
      id: id,
      title: doc.meta.title.isEmpty ? 'Untitled story' : doc.meta.title,
      updatedAt: _now(),
      sceneCount: doc.scenes.length,
      projectId: projectId,
    );
    _docs[id] = doc;
    _own[id] = summary;
    return summary;
  }

  @override
  Future<List<ProjectSummary>> projects() async => [
    for (final p in _projects.values)
      ProjectSummary(
        id: p.id,
        title: p.title,
        updatedAt: p.updatedAt,
        issueCount: _own.values.where((s) => s.projectId == p.id).length,
      ),
  ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Future<ProjectSummary> createProject({
    String title = 'Untitled project',
  }) async {
    final p = ProjectSummary(
      id: ir.IdGenerator().next(),
      title: title,
      updatedAt: _now(),
    );
    _projects[p.id] = p;
    return p;
  }

  @override
  Future<void> renameProject(String id, String title) async {
    final p = _projects[id];
    if (p == null) throw StoryNotFoundException(id);
    _projects[id] = ProjectSummary(id: id, title: title, updatedAt: _now());
  }

  @override
  Future<void> deleteProject(String id) async {
    _projects.remove(id);
    _libraries.remove(id);
    for (final s in _own.values.where((s) => s.projectId == id).toList()) {
      await delete(s.id);
    }
  }

  @override
  Future<StorySummary> createIssue(
    String projectId, {
    String? fromStoryId,
    String? title,
  }) async {
    if (!_projects.containsKey(projectId)) {
      throw StoryNotFoundException(projectId);
    }
    final count = _own.values.where((s) => s.projectId == projectId).length;
    final name = title ?? issueTitle(count);
    final from = fromStoryId == null ? null : await load(fromStoryId);
    final library = _libraries[projectId] ?? const ProjectLibrary();
    final doc = from != null
        ? issueCopy(library.applyTo(from), title: name)
        : library.blankIssue(title: name);
    return _add(doc, projectId: projectId);
  }

  @override
  Future<void> moveToProject(String storyId, String projectId) async {
    final s = _own[storyId];
    if (s == null || !_projects.containsKey(projectId)) {
      throw StoryNotFoundException(storyId);
    }
    _own[storyId] = StorySummary(
      id: s.id,
      title: s.title,
      updatedAt: _now(),
      sceneCount: s.sceneCount,
      projectId: projectId,
    );
    final doc = _docs[storyId];
    if (doc != null) await save(storyId, doc);
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

/// The projects (DECISIONS 26/10/26 #11), refreshed with the story list.
final projectListProvider = FutureProvider<List<ProjectSummary>>((ref) {
  ref.watch(storyListRevisionProvider);
  return ref.watch(storyRepositoryProvider).projects();
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
