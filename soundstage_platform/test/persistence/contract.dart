import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/app/persistence/db_story_repository.dart';
import 'package:soundstage_platform/app/persistence/local_asset_store.dart';
import 'package:soundstage_platform/app/persistence/records.dart';
import 'package:soundstage_platform/app/persistence/story_database.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

class FakeAnalyzer implements AssetAnalyzer {
  @override
  Future<AssetAnalysis> analyze(Uint8List bytes, String mime) async =>
      const AssetAnalysis(width: 4, height: 3, dominantColor: 0xFF336699);
}

class FakeUrls implements ObjectUrlFactory {
  final live = <String>{};
  var n = 0;
  @override
  String create(Uint8List bytes, String mime) {
    final u = 'blob:fake/${n++}';
    live.add(u);
    return u;
  }

  @override
  void revoke(String url) => live.remove(url);
}

String demoJson(String title) => jsonEncode(
  ir.StageDocument.empty(
    ids: ir.IdGenerator.seeded(5),
    meta: ir.StageMeta(title: title),
  ).toJson(),
);

class Harness {
  Harness(this.db, this.clock) {
    assets = LocalAssetStore(
      db,
      analyzer: FakeAnalyzer(),
      urls: urls,
      now: () => clock(),
    );
    repo = DbStoryRepository(
      db,
      assets: assets,
      loadText: (p) async => demoJson('Loaded $p'),
      loadBytes: (p) async => Uint8List.fromList([1, 2, 3]),
      now: () => clock(),
      maxRevisions: 5,
    );
  }
  final StoryDatabase db;
  final DateTime Function() clock;
  final urls = FakeUrls();
  late final LocalAssetStore assets;
  late final DbStoryRepository repo;
}

/// Tests every [StoryRepository] implementation must pass. [make] builds a
/// fresh one; [reopen] builds a second repository over the same storage.
void repositoryContract(
  String name,
  Future<Harness> Function(DateTime Function() clock) make,
) {
  group('StoryRepository contract: $name', () {
    var t = DateTime(2026, 10, 23, 9);
    DateTime clock() => t = t.add(const Duration(minutes: 1));
    late Harness h;
    setUp(() async {
      t = DateTime(2026, 10, 23, 9);
      h = await make(clock);
    });

    test('create, list, open', () async {
      final s = await h.repo.create(title: 'Mine');
      final list = await h.repo.list();
      expect(list.first.id, s.id);
      expect(list.first.title, 'Mine');
      expect(list.where((x) => x.bundled).length, kBundledStories.length);
      final open = await h.repo.open(s.id);
      expect(open!.document!.meta.title, 'Mine');
      // A new story starts with one blank pinned scene.
      expect(open.document!.scenes, hasLength(1));
      expect(list.first.sceneCount, 1);
      expect(open.recovered, isFalse);
      expect(await h.repo.open('nope'), isNull);
    });

    test('save moves the head and rename updates the title', () async {
      final s = await h.repo.create();
      final doc = (await h.repo.load(s.id))!;
      await h.repo.save(
        s.id,
        doc.copyWith(meta: doc.meta.copyWith(title: 'Saved')),
      );
      expect((await h.repo.list()).first.title, 'Saved');
      expect((await h.repo.open(s.id))!.headRevision, 2);
      await h.repo.rename(s.id, 'Final');
      expect((await h.repo.load(s.id))!.meta.title, 'Final');
      expect((await h.repo.list()).first.title, 'Final');
    });

    test('identical save writes no new revision', () async {
      final s = await h.repo.create();
      final doc = (await h.repo.load(s.id))!;
      await h.repo.save(s.id, doc);
      expect((await h.repo.revisions(s.id)).length, 1);
    });

    test('delete removes the story and its revisions', () async {
      final s = await h.repo.create();
      await h.repo.delete(s.id);
      expect(await h.repo.open(s.id), isNull);
      expect(await h.db.listRevisions(s.id), isEmpty);
    });

    test('demos are read-only; duplicate copies document and assets', () async {
      expect(h.repo.isReadOnly('demo-static'), isTrue);
      expect(
        () => h.repo.save(
          'demo-static',
          ir.StageDocument.empty(ids: ir.IdGenerator()),
        ),
        throwsA(isA<ReadOnlyStoryException>()),
      );
      final demo = (await h.repo.open('demo-static'))!;
      expect(demo.readOnly, isTrue);
      final withAsset = ir.StageDocument.fromJson({
        ...demo.document!.toJson(),
        'assets': {
          'a1': const ir.Asset(
            id: 'a1',
            kind: ir.AssetKind.image,
            uri: 'asset://assets/x.png',
            mime: 'image/png',
          ).toJson(),
        },
      });
      final copy = await h.repo.createFrom(withAsset);
      final dup = await h.repo.duplicate(copy.id);
      expect(dup.id, isNot(copy.id));
      final doc = (await h.repo.load(dup.id))!;
      expect(
        doc.assets['a1']!.uri,
        'asset://assets/x.png'.replaceFirst(
          'asset://assets/x.png',
          'local://a1',
        ),
      );
      expect(await h.assets.get('a1'), Uint8List.fromList([1, 2, 3]));
    });

    test(
      'revisions list newest first and restore appends a revision',
      () async {
        final s = await h.repo.create(title: 'v1');
        for (final title in ['v2', 'v3']) {
          final d = (await h.repo.load(s.id))!;
          await h.repo.save(
            s.id,
            d.copyWith(meta: d.meta.copyWith(title: title)),
          );
        }
        final revs = await h.repo.revisions(s.id);
        expect(revs.map((r) => r.rev), [3, 2, 1]);
        await h.repo.restore(s.id, 1);
        expect((await h.repo.load(s.id))!.meta.title, 'v1');
        expect((await h.repo.revisions(s.id)).first.rev, 4);
      },
    );

    test('revision pruning keeps the newest N and the head', () async {
      final s = await h.repo.create(title: 'p');
      for (var i = 0; i < 12; i++) {
        final d = (await h.repo.load(s.id))!;
        await h.repo.save(
          s.id,
          d.copyWith(meta: d.meta.copyWith(title: 't$i')),
        );
      }
      final revs = (await h.repo.revisions(s.id)).map((r) => r.rev).toList();
      expect(revs.first, 13);
      // newest 5 + one per clock hour inside the day (clock moves 1 min/op)
      expect(revs.length, lessThan(13));
      expect(revs, containsAll([13, 12, 11, 10, 9]));
      expect((await h.repo.open(s.id))!.document!.meta.title, 't11');
    });

    test('corrupt head falls back to the newest revision that loads', () async {
      final s = await h.repo.create(title: 'good');
      final d = (await h.repo.load(s.id))!;
      await h.repo.save(
        s.id,
        d.copyWith(meta: d.meta.copyWith(title: 'newer')),
      );
      await h.db.putRevision(
        RevisionRecord(storyId: s.id, rev: 2, savedAt: 1, json: '{not json'),
      );
      final open = (await h.repo.open(s.id))!;
      expect(open.recovered, isTrue);
      expect(open.recoveredFromRevision, 1);
      expect(open.document!.meta.title, 'good');
    });

    test(
      'crash between revision write and pointer move keeps the old head',
      () async {
        final s = await h.repo.create(title: 'safe');
        final d = (await h.repo.load(s.id))!;
        // Simulate a crash after step 1: a new revision exists, the pointer did not move.
        await h.db.putRevision(
          RevisionRecord(
            storyId: s.id,
            rev: 2,
            savedAt: 5,
            json: jsonEncode(
              d.copyWith(meta: d.meta.copyWith(title: 'half')).toJson(),
            ),
          ),
        );
        final open = (await h.repo.open(s.id))!;
        expect(open.document!.meta.title, 'safe');
        expect(open.recovered, isFalse);
        // The next save numbers past the orphan.
        await h.repo.save(
          s.id,
          d.copyWith(meta: d.meta.copyWith(title: 'next')),
        );
        expect((await h.repo.open(s.id))!.headRevision, 3);
      },
    );

    test('asset put/get, object urls and garbage collection', () async {
      final a = await h.assets.put(
        Uint8List.fromList([9, 9]),
        'image/png',
        name: 'p',
      );
      expect(a.uri, 'local://${a.id}');
      expect(a.width, 4);
      expect(a.placeholder!.dominantColor.toHex(), '#336699');
      expect(await h.assets.get(a.id), Uint8List.fromList([9, 9]));
      await expectLater(
        h.assets.put(Uint8List(1), 'text/plain'),
        throwsA(isA<UnsupportedAssetException>()),
      );

      final u1 = await h.assets.acquireObjectUrl(a.id);
      final u2 = await h.assets.acquireObjectUrl(a.id);
      expect(u1, u2);
      h.assets.releaseObjectUrl(a.id);
      expect(h.urls.live, hasLength(1));
      h.assets.releaseObjectUrl(a.id);
      expect(h.urls.live, isEmpty);

      final used = await h.assets.put(Uint8List.fromList([1]), 'image/png');
      final s = await h.repo.create();
      final d = (await h.repo.load(s.id))!;
      await h.repo.save(s.id, d.copyWith(assets: {used.id: used}));
      // Too young: kept.
      expect(await h.assets.collectGarbage(), 0);
      t = t.add(const Duration(hours: 3));
      expect(await h.assets.collectGarbage(), 1);
      expect(await h.assets.get(a.id), isNull);
      expect(await h.assets.get(used.id), isNotNull);
    });
    test(
      'image sequences store numbered frames and survive collection',
      () async {
        final seq = await h.assets.putSequence([
          for (var i = 0; i < 3; i++) (Uint8List.fromList([i]), 'image/webp'),
        ], name: 'walk');
        expect(seq.kind, ir.AssetKind.imageSequence);
        expect(seq.uri, 'local://${seq.id}_{0001}');
        expect(seq.frameCount, 3);
        expect(seq.byteSize, 3);
        expect(seq.duration, closeTo(3 / ir.kSequenceFrameRate, 1e-9));
        expect(seq.width, 4);
        expect(ir.sequenceFrameUri(seq, 2), 'local://${seq.id}_0003');
        expect(
          await h.assets.loadBytes('${seq.id}_0003'),
          Uint8List.fromList([2]),
        );
        await expectLater(
          h.assets.putSequence([(Uint8List(1), 'audio/wav')]),
          throwsA(isA<UnsupportedAssetException>()),
        );
        await expectLater(
          h.assets.putSequence(const []),
          throwsA(isA<UnsupportedAssetException>()),
        );

        final orphan = await h.assets.putSequence([
          (Uint8List.fromList([7]), 'image/png'),
        ]);
        final s = await h.repo.create();
        final d = (await h.repo.load(s.id))!;
        await h.repo.save(s.id, d.copyWith(assets: {seq.id: seq}));
        t = t.add(const Duration(hours: 3));
        expect(await h.assets.collectGarbage(), 1);
        expect(await h.assets.get('${seq.id}_0001'), isNotNull);
        expect(await h.assets.get('${seq.id}_0003'), isNotNull);
        expect(await h.assets.get('${orphan.id}_0001'), isNull);
      },
    );

    test('projects: issues share one library', () async {
      final p = await h.repo.createProject(title: 'Weekly');
      expect((await h.repo.projects()).single.title, 'Weekly');

      // Issue 1: blank; give it a token collection.
      final i1 = await h.repo.createIssue(p.id);
      expect(i1.title, 'Issue 1');
      expect(i1.projectId, p.id);
      final d1 = (await h.repo.load(i1.id))!;
      final tokens = d1.tokens.copyWith(
        collections: [
          const ir.VariableCollection(
            id: 'c',
            name: 'Brand',
            modes: [ir.TokenMode(id: 'm', name: 'Default')],
            defaultModeId: 'm',
          ),
        ],
      );
      await h.repo.save(i1.id, d1.copyWith(tokens: tokens));

      // Issue 2 (blank) starts with the library.
      final i2 = await h.repo.createIssue(p.id);
      expect(i2.title, 'Issue 2');
      final d2 = (await h.repo.load(i2.id))!;
      expect(d2.tokens.collections.single.name, 'Brand');

      // A library change in issue 2 reaches issue 1 when it opens.
      await h.repo.save(
        i2.id,
        d2.copyWith(
          tokens: d2.tokens.copyWith(
            collections: [
              d2.tokens.collections.single.copyWith(name: 'Brand 2'),
            ],
          ),
        ),
      );
      final again = (await h.repo.open(i1.id))!.document!;
      expect(again.tokens.collections.single.name, 'Brand 2');

      // Issue 3 copies issue 2 as its template (scenes and all).
      final i3 = await h.repo.createIssue(p.id, fromStoryId: i2.id);
      final d3 = (await h.repo.load(i3.id))!;
      expect(d3.id, isNot(d2.id));
      expect(d3.scenes.map((s) => s.id), d2.scenes.map((s) => s.id));
      expect(d3.meta.title, 'Issue 3');

      final listed = await h.repo.projects();
      expect(listed.single.issueCount, 3);
      final standalone = await h.repo.create(title: 'Alone');
      expect(
        (await h.repo.list())
            .firstWhere((s) => s.id == standalone.id)
            .projectId,
        isNull,
      );

      await h.repo.renameProject(p.id, 'Weekly letter');
      expect((await h.repo.projects()).single.title, 'Weekly letter');
      await h.repo.deleteProject(p.id);
      expect(await h.repo.projects(), isEmpty);
      expect(await h.repo.load(i1.id), isNull);
      expect(await h.repo.load(standalone.id), isNotNull);
    });

    test('a draft moved into a project lends it its library', () async {
      final p = await h.repo.createProject();
      final s = await h.repo.create(title: 'Loose');
      final d = (await h.repo.load(s.id))!;
      await h.repo.save(
        s.id,
        d.copyWith(
          tokens: d.tokens.copyWith(
            collections: [
              const ir.VariableCollection(
                id: 'c',
                name: 'Mine',
                modes: [ir.TokenMode(id: 'm', name: 'Default')],
                defaultModeId: 'm',
              ),
            ],
          ),
        ),
      );
      await h.repo.moveToProject(s.id, p.id);
      expect(
        (await h.repo.list()).firstWhere((x) => x.id == s.id).projectId,
        p.id,
      );
      final next = await h.repo.createIssue(p.id);
      expect(
        (await h.repo.load(next.id))!.tokens.collections.single.name,
        'Mine',
      );
    });
  });
}
