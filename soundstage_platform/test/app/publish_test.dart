import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/ir/ir.dart';

class FakeBackend implements CloudBackend {
  FakeBackend(this.uid);

  @override
  String? uid;

  /// uid → handle.
  final handles = <String, String>{'u1': 'ada', 'u2': 'bob'};
  final files = <String, Uint8List>{};

  /// Firestore path → record.
  final records = <String, PublishedRecord>{};
  final meta = <String, Map<String, Object?>>{};
  int uploads = 0;

  @override
  Future<String?> handle() async => handles[uid];

  @override
  Future<void> claimHandle(String handle, {String name = ''}) async {
    if (handles.containsValue(handle)) {
      throw PublishException('@$handle is taken.');
    }
    handles[uid!] = handle;
  }

  final deleted = <String>[];

  @override
  Future<void> deleteFolder(String prefix) async {
    deleted.add(prefix);
    files.removeWhere((k, _) => k.startsWith('$prefix/'));
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> upload(String path, Uint8List bytes, String mime) async {
    uploads++;
    files[path] = bytes;
  }

  @override
  String publicUrl(String path) =>
      'https://cdn.test/o/${Uri.encodeComponent(path)}?alt=media';

  @override
  Future<PublishedRecord?> published(PublishTarget t) async =>
      records[t.docPath];

  @override
  Future<void> setPublished(PublishTarget t, PublishedRecord r) async =>
      records[t.docPath] = r;

  @override
  Future<void> setStoryMeta(String id, Map<String, Object?> data) async =>
      meta[id] = {...?meta[id], ...data};

  @override
  Future<PublishTarget?> publishedTargetOf(String id) async =>
      PublishTarget.fromMap(meta[id]?['published']);

  final seriesRecords = <PublicationRef, SeriesRecord>{};

  @override
  Future<SeriesRecord?> series(PublicationRef ref) async => seriesRecords[ref];

  @override
  Future<void> setSeries(PublicationRef ref, SeriesRecord r) async =>
      seriesRecords[ref] = r;

  @override
  Future<PublicationRef?> publicationOf(String projectId) async => seriesRecords
      .entries
      .where(
        (e) => e.key.handle == handles[uid] && e.value.projectId == projectId,
      )
      .map((e) => e.key)
      .firstOrNull;

  @override
  Future<SiteListing?> site(String handle) async => null;

  Uint8List fetch(String url) {
    final path = Uri.decodeComponent(
      url.substring('https://cdn.test/o/'.length, url.indexOf('?')),
    );
    return files[path]!;
  }
}

DraftTarget _d(String slug) => DraftTarget('ada', slug);

StageDocument _doc() =>
    StageDocument.empty(
      ids: IdGenerator.seeded(3),
      meta: const StageMeta(title: 'Night walk'),
    ).copyWith(
      assets: const {
        'img': Asset(
          id: 'img',
          kind: AssetKind.image,
          uri: 'local://img',
          mime: 'image/png',
        ),
        'seq': Asset(
          id: 'seq',
          kind: AssetKind.imageSequence,
          uri: 'local://seq_{0001}',
          mime: 'image/webp',
          frameCount: 2,
        ),
      },
    );

Future<Uint8List?> _bytes(Asset a) async => switch (a.uri) {
  'local://img' => Uint8List.fromList([1, 2, 3]),
  'local://seq_0001' => Uint8List.fromList([7]),
  'local://seq_0002' => Uint8List.fromList([8]),
  _ => null,
};

void main() {
  test('handles and targets', () {
    expect(isValidHandle('ada'), isTrue);
    expect(isValidHandle('ad'), isFalse);
    expect(isValidHandle('admin'), isFalse);
    expect(isValidHandle('Ada'), isFalse);
    expect(handleFor('Ada.Lovelace@example.org'), 'ada-lovelace');
    expect(handleFor('x@y.z'), 'xxx');
    expect(handleFor('admin@y.z'), 'admin-1');
    expect(isValidPublication('weekly'), isTrue);
    expect(isValidPublication('s'), isFalse);
    final issue = IssueTarget(const PublicationRef('ada', 'weekly'), 'one');
    expect(issue.route, '/@ada/weekly/one');
    expect(issue.docPath, 'sites/ada/publications/weekly/issues/one');
    expect(issue.storagePrefix('u1'), 'published/u1/ada/weekly/one');
    expect(PublishTarget.fromMap(issue.toMap()), issue);
    expect(PublishTarget.fromMap(_d('x').toMap()), _d('x'));
    expect(_d('x').route, '/@ada/s/x');
    expect(PublishTarget.fromMap(null), isNull);
  });

  test('slugs', () {
    expect(slugFor('My first story!'), 'my-first-story');
    expect(slugFor('???'), 'story');
    expect(isValidSlug('night-walk'), isTrue);
    expect(isValidSlug('Night'), isFalse);
    expect(isValidSlug('-a'), isFalse);
  });

  test('publishing freezes a version with public asset URLs', () async {
    final b = FakeBackend('u1');
    final r = await publishStory(
      _doc(),
      storyId: 'st',
      target: _d('night-walk'),
      backend: b,
      bytesOf: _bytes,
    );
    expect(r.version, 1);
    expect(r.path, '/@ada/s/night-walk');
    expect(r.warnings, isEmpty);
    final rec = b.records[_d('night-walk').docPath]!;
    expect(rec.ownerId, 'u1');
    expect(rec.path, 'published/u1/ada/s/night-walk/v1.stage.json');
    expect(b.meta['st']!['published'], {'handle': 'ada', 'slug': 'night-walk'});
    expect(await b.publishedTargetOf('st'), _d('night-walk'));

    final loaded = (await loadPublished(
      _d('night-walk'),
      backend: b,
      fetch: (u) async => b.fetch(u),
    ))!;
    final doc = loaded.document!;
    expect(doc.meta.slug, 'night-walk');
    final img = doc.assets['img']!;
    expect(img.uri, startsWith('https://cdn.test/o/'));
    expect(b.fetch(img.uri), [1, 2, 3]);
    // The sequence pattern still has its braces; each frame resolves.
    final seq = doc.assets['seq']!;
    expect(isFramePattern(seq.uri), isTrue);
    expect(b.fetch(sequenceFrameUri(seq, 1)), [8]);
  });

  test('republishing bumps the version and re-uploads only changes', () async {
    final b = FakeBackend('u1');
    Future<PublishResult> go() => publishStory(
      _doc(),
      storyId: 'st',
      target: _d('night-walk'),
      backend: b,
      bytesOf: _bytes,
    );
    await go();
    // 3 asset files, the document, the library chunk and the manifest.
    final first = b.uploads;
    expect(first, 6);
    final r = await go();
    expect(r.version, 2);
    expect(b.uploads - first, 2); // the new document and manifest
  });

  test('another handle, another story, or signed out is refused', () async {
    final b = FakeBackend('u1');
    await publishStory(
      _doc(),
      storyId: 'st',
      target: _d('taken'),
      backend: b,
      bytesOf: _bytes,
    );
    Future<PublishResult> go(String story, PublishTarget t) => publishStory(
      _doc(),
      storyId: story,
      target: t,
      backend: b,
      bytesOf: _bytes,
    );
    // Another of the author's stories cannot replace it.
    await expectLater(go('x', _d('taken')), throwsA(isA<PublishException>()));
    // Someone else cannot publish under @ada.
    b.uid = 'u2';
    await expectLater(go('x', _d('free')), throwsA(isA<PublishException>()));
    expect((await go('x', const DraftTarget('bob', 'taken'))).version, 1);
    b.uid = null;
    await expectLater(go('x', _d('free')), throwsA(isA<PublishException>()));
    // An author without a handle is asked for one first.
    b.uid = 'u3';
    await expectLater(
      go('y', const DraftTarget('cy', 'free')),
      throwsA(isA<PublishException>()),
    );
  });

  test('versions are listed, and any can be made live', () async {
    final b = FakeBackend('u1');
    for (final (i, title) in ['One', 'Two', 'Three'].indexed) {
      await publishStory(
        _doc().copyWith(meta: StageMeta(title: title)),
        storyId: 'st',
        target: _d('walk'),
        backend: b,
        bytesOf: _bytes,
        now: DateTime.utc(2026, 10, 26, i),
      );
    }
    var rec = b.records[_d('walk').docPath]!;
    expect(rec.version, 3);
    expect(rec.latest, 3);
    expect(rec.versions.map((v) => v.version), [1, 2, 3]);
    expect(
      rec.versions.first.publishedAt,
      DateTime.utc(2026, 10, 26).millisecondsSinceEpoch,
    );

    rec = await makeLive(_d('walk'), 1, backend: b);
    expect(rec.version, 1);
    expect(rec.title, 'One');
    expect(rec.path, rec.versions.first.path);
    expect(rec.latest, 3);
    final back = PublishedRecord.fromMap(rec.toMap());
    expect(back.versions, hasLength(3));
    expect(back.version, 1);
    // Readers get version 1.
    final loaded = await loadPublished(
      _d('walk'),
      backend: b,
      fetch: (u) async => b.fetch(u),
    );
    expect(loaded!.document!.meta.title, 'One');

    // Publishing again continues the numbering and goes live.
    final r = await publishStory(
      _doc(),
      storyId: 'st',
      target: _d('walk'),
      backend: b,
      bytesOf: _bytes,
    );
    expect(r.version, 4);
    expect(b.records[_d('walk').docPath]!.version, 4);
    await expectLater(
      makeLive(_d('walk'), 9, backend: b),
      throwsA(isA<PublishException>()),
    );
    b.uid = 'u2';
    await expectLater(
      makeLive(_d('walk'), 1, backend: b),
      throwsA(isA<PublishException>()),
    );
  });

  test(
    'the cover is uploaded once and recorded; a failed render is skipped',
    () async {
      final b = FakeBackend('u1');
      Future<PublishResult> go(Future<Uint8List?> Function() cover) =>
          publishStory(
            _doc(),
            storyId: 'st',
            target: _d('covered'),
            backend: b,
            bytesOf: _bytes,
            cover: cover,
          );
      await go(() async => Uint8List.fromList([9, 9]));
      final image = b.records[_d('covered').docPath]!.image;
      expect(image, startsWith('https://cdn.test/o/'));
      expect(b.fetch(image), [9, 9]);
      final uploads = b.uploads;
      await go(() async => Uint8List.fromList([9, 9]));
      expect(b.uploads - uploads, 2); // the document and manifest only
      await go(() async => throw StateError('no renderer'));
      expect(b.records[_d('covered').docPath]!.image, isEmpty);
      expect(b.records[_d('covered').docPath]!.version, 3);
    },
  );

  test(
    'chunked: manifest, library and scene chunks open scene by scene',
    () async {
      final ids = IdGenerator.seeded(9);
      final base = _doc();
      Scene scene(String name) => Scene.blankPinned(
        ids: ids,
        breakpoint: base.breakpoints.first,
        name: name,
      );
      final scenes = [scene('One'), scene('Two'), scene('Three')];
      final textId = ids.next();
      StageDocument withScenes(String text) {
        final two = scenes[1];
        return base.copyWith(
          scenes: [
            scenes[0],
            two.copyWith(
              root: two.root.copyWith(
                children: [
                  TextNode(
                    common: NodeCommon(id: textId, width: 100, height: 20),
                    content: [
                      Paragraph(spans: [Span(text: text)]),
                    ],
                  ),
                ],
              ),
            ),
            scenes[2],
          ],
        );
      }

      final doc = withScenes('hello');
      final b = FakeBackend('u1');
      await publishStory(
        doc,
        storyId: 'st',
        target: _d('chunky'),
        backend: b,
        bytesOf: _bytes,
      );
      final rec = b.records[_d('chunky').docPath]!;
      expect(rec.manifest, 'published/u1/ada/s/chunky/v1.manifest.json');
      final story = await openPublished(
        _d('chunky'),
        backend: b,
        fetch: (u) async => b.fetch(u),
      );
      final chunkedStory = story! as ChunkedPublishedStory;
      final chunked = chunkedStory.chunked;
      final two = chunked.document.scenes[1];
      expect(two.root.children, isEmpty, reason: 'a stub until fetched');
      expect(two.root.common.height, doc.scenes[1].root.common.height);
      expect(chunked.document.assets['img']!.uri, startsWith('https://'));
      final one = chunked.document.scenes[0];
      expect(await chunkedStory.loadScene(two.id), isTrue);
      expect(await chunkedStory.loadScene(two.id), isFalse, reason: 'once');
      expect(chunked.document.scenes[1].root.children, hasLength(1));
      expect(identical(chunked.document.scenes[0], one), isTrue);
      expect(chunked.complete, isFalse);

      // Republishing with one scene changed sends only that scene's chunk
      // (plus the document and the manifest).
      final before = b.uploads;
      await publishStory(
        withScenes('changed'),
        storyId: 'st',
        target: _d('chunky'),
        backend: b,
        bytesOf: _bytes,
      );
      expect(b.uploads - before, 3);
    },
  );

  test('versions published before chunking open whole', () async {
    final b = FakeBackend('u1');
    await publishStory(
      _doc(),
      storyId: 'st',
      target: _d('old'),
      backend: b,
      bytesOf: _bytes,
    );
    final r = b.records[_d('old').docPath]!;
    b.records[_d('old').docPath] = PublishedRecord(
      ownerId: r.ownerId,
      storyId: r.storyId,
      version: r.version,
      path: r.path,
    );
    final story = await openPublished(
      _d('old'),
      backend: b,
      fetch: (u) async => b.fetch(u),
    );
    expect(story, isA<WholePublishedStory>());
  });

  test('meta-notes and the board are never published', () async {
    final b = FakeBackend('u1');
    await publishStory(
      _doc().copyWith(
        notes: const {'x': 'private'},
        board: const InspirationBoard(
          items: [
            BoardItem(id: 'b', kind: BoardItemKind.note, text: 'secret idea'),
          ],
        ),
        annotations: const [
          Annotation(
            id: 'an',
            kind: AnnotationKind.comment,
            sceneId: 's',
            breakpointId: 'b',
            note: 'draft mark',
          ),
        ],
      ),
      storyId: 'st',
      target: _d('quiet'),
      backend: b,
      bytesOf: _bytes,
    );
    final whole = utf8.decode(b.files[b.records[_d('quiet').docPath]!.path]!);
    expect(whole, isNot(contains('private')));
    expect(whole, isNot(contains('secret idea')));
    expect(whole, isNot(contains('draft mark')));
    final manifest = utf8.decode(
      b.files[b.records[_d('quiet').docPath]!.manifest]!,
    );
    expect(manifest, isNot(contains('private')));
    expect(manifest, isNot(contains('secret idea')));
  });

  test(
    'a publication lists its published issues, in order, and is its own',
    () async {
      final b = FakeBackend('u1');
      const weekly = PublicationRef('ada', 'weekly');
      for (final (id, slug) in [('i2', 'issue-two'), ('i1', 'issue-one')]) {
        final r = await publishStory(
          _doc(),
          storyId: id,
          target: IssueTarget(weekly, slug),
          backend: b,
          bytesOf: _bytes,
        );
        expect(r.path, '/@ada/weekly/$slug');
      }
      expect(
        b.records['sites/ada/publications/weekly/issues/issue-one'],
        isNotNull,
      );
      expect(
        b.files.keys,
        contains('published/u1/ada/weekly/issue-one/v1.stage.json'),
      );
      // A one-off draft is not an issue of it.
      await publishStory(
        _doc(),
        storyId: 'i4',
        target: _d('loose'),
        backend: b,
        bytesOf: _bytes,
      );
      final r = await publishSeries(
        projectId: 'p',
        title: 'Weekly',
        ref: weekly,
        issueIds: ['i3', 'i2', 'i4', 'i1'], // i3 is not published
        backend: b,
      );
      expect(r.issues.map((i) => i.slug), ['issue-two', 'issue-one']);
      expect(b.seriesRecords[weekly]!.title, 'Weekly');
      expect(await b.publicationOf('p'), weekly);
      final back = SeriesRecord.fromMap(r.toMap());
      expect(back.issues.first.title, r.issues.first.title);

      // Another project cannot take the link; nor another handle; nor a
      // reserved slug.
      Future<SeriesRecord> go(String project, PublicationRef ref) =>
          publishSeries(
            projectId: project,
            title: 'X',
            ref: ref,
            issueIds: const [],
            backend: b,
          );
      await expectLater(go('other', weekly), throwsA(isA<PublishException>()));
      await expectLater(
        go('p', const PublicationRef('ada', 's')),
        throwsA(isA<PublishException>()),
      );
      b.uid = 'u2';
      await expectLater(go('p', weekly), throwsA(isA<PublishException>()));
    },
  );

  test('missing files are reported, not fatal', () async {
    final b = FakeBackend('u1');
    final r = await publishStory(
      _doc(),
      storyId: 'st',
      target: _d('gaps'),
      backend: b,
      bytesOf: (a) async => null,
    );
    expect(r.warnings, hasLength(2));
    expect(
      jsonDecode(utf8.decode(b.files[b.records[_d('gaps').docPath]!.path]!)),
      isA<Map<String, Object?>>(),
    );
  });

  test('gated stories keep their files private and open with a pass', () async {
    final b = FakeBackend('u1');
    final r = await publishStory(
      _doc(),
      storyId: 'st',
      target: _d('locked'),
      backend: b,
      bytesOf: _bytes,
      audience: Audience.password,
      cover: () async => Uint8List.fromList([9]),
    );
    final rec = b.records[_d('locked').docPath]!;
    expect(rec.audience, Audience.password);
    expect(rec.image, isEmpty, reason: 'no public cover');
    expect(rec.path, 'gated/u1/ada/s/locked/v1.stage.json');
    expect(b.files.keys.every((k) => k.startsWith('gated/')), isTrue);
    expect(r.warnings, isEmpty);
    final whole = utf8.decode(b.files[rec.path]!);
    expect(whole, contains('gated:gated/u1/ada/s/locked/assets/'));
    expect(whole, isNot(contains('cdn.test')));

    // Without a pass, a reader is sent to the gate.
    await expectLater(
      openPublished(_d('locked'), backend: b, fetch: (u) async => b.fetch(u)),
      throwsA(isA<GateRequired>()),
    );
    expect(
      await loadPublished(
        _d('locked'),
        backend: b,
        fetch: (u) async => b.fetch(u),
      ),
      isNull,
    );

    // With a pass, every URL goes through the gate's file route.
    final pass = GatePass(
      record: rec.toMap(),
      token: 'tok',
      baseUrl: 'https://gate.test',
    );
    final fetched = <String>[];
    Future<Uint8List> fetch(String url) async {
      fetched.add(url);
      final path = Uri.decodeComponent(
        url.substring('https://gate.test/gate/file/'.length, url.indexOf('?')),
      );
      return b.files[path]!;
    }

    final story =
        await openPublished(_d('locked'), backend: b, fetch: fetch, pass: pass)
            as ChunkedPublishedStory;
    expect(
      fetched.every((u) => u.startsWith('https://gate.test/gate/file/')),
      isTrue,
    );
    expect(fetched.every((u) => u.endsWith('?t=tok')), isTrue);
    final assets = story.chunked.document.assets;
    expect(assets['img']!.uri, startsWith('https://gate.test/gate/file/'));
    // Frame patterns keep their braces for the runtime.
    expect(assets['seq']!.uri, contains('{0001}'));
    expect(isFramePattern(assets['seq']!.uri), isTrue);
    expect(await fetch(assets['img']!.uri), [1, 2, 3]);
  });

  test('crossing between public and private removes the other files', () async {
    final b = FakeBackend('u1');
    Future<PublishResult> go(Audience a) => publishStory(
      _doc(),
      storyId: 'st',
      target: _d('walk'),
      backend: b,
      bytesOf: _bytes,
      audience: a,
    );
    await go(Audience.public);
    await go(Audience.unlisted); // same files, no move
    expect(b.deleted, isEmpty);
    expect(b.records[_d('walk').docPath]!.versions, hasLength(2));
    final r = await go(Audience.readers);
    expect(b.deleted, ['published/u1/ada/s/walk']);
    expect(r.warnings.single, contains('public versions were removed'));
    final rec = b.records[_d('walk').docPath]!;
    expect(rec.version, 3, reason: 'numbering continues');
    expect(rec.versions.map((v) => v.version), [3]);
    expect(b.files.keys.where((k) => k.startsWith('published/')), isEmpty);
    await go(Audience.public);
    expect(b.deleted.last, 'gated/u1/ada/s/walk');
  });

  test('a publication lists public and private issues, not unlisted', () async {
    final b = FakeBackend('u1');
    const weekly = PublicationRef('ada', 'weekly');
    for (final (id, slug, a) in [
      ('i1', 'open', Audience.public),
      ('i2', 'quiet', Audience.unlisted),
      ('i3', 'paid', Audience.password),
    ]) {
      await publishStory(
        _doc(),
        storyId: id,
        target: IssueTarget(weekly, slug),
        backend: b,
        bytesOf: _bytes,
        audience: a,
      );
    }
    final r = await publishSeries(
      projectId: 'p',
      title: 'Weekly',
      ref: weekly,
      issueIds: ['i3', 'i2', 'i1'],
      backend: b,
      audience: Audience.readers,
    );
    expect(r.issues.map((i) => (i.slug, i.gated)), [
      ('paid', true),
      ('open', false),
    ]);
    expect(r.audience, Audience.readers);
    // The audience is kept when it is not given.
    final again = await publishSeries(
      projectId: 'p',
      title: 'Weekly',
      ref: weekly,
      issueIds: const [],
      backend: b,
    );
    expect(again.audience, Audience.readers);
    expect(SeriesRecord.fromMap(r.toMap()).issues.first.gated, isTrue);
  });
}
