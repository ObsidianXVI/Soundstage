import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/ir/ir.dart';

class FakeBackend implements CloudBackend {
  FakeBackend(this.uid);

  @override
  String? uid;

  final files = <String, Uint8List>{};
  final records = <String, PublishedRecord>{};
  final meta = <String, Map<String, Object?>>{};
  int uploads = 0;

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
  Future<PublishedRecord?> published(String slug) async => records[slug];

  @override
  Future<void> setPublished(String slug, PublishedRecord r) async =>
      records[slug] = r;

  @override
  Future<void> setStoryMeta(String id, Map<String, Object?> data) async =>
      meta[id] = data;

  @override
  Future<String?> publishedSlugOf(String id) async =>
      meta[id]?['publishedSlug'] as String?;

  Uint8List fetch(String url) {
    final path = Uri.decodeComponent(
      url.substring('https://cdn.test/o/'.length, url.indexOf('?')),
    );
    return files[path]!;
  }
}

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
      slug: 'night-walk',
      backend: b,
      bytesOf: _bytes,
    );
    expect(r.version, 1);
    expect(r.path, '/s/night-walk');
    expect(r.warnings, isEmpty);
    final rec = b.records['night-walk']!;
    expect(rec.ownerId, 'u1');
    expect(rec.path, 'published/u1/night-walk/v1.stage.json');
    expect(b.meta['st']!['publishedSlug'], 'night-walk');

    final loaded = (await loadPublished(
      'night-walk',
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
      slug: 'night-walk',
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

  test('a slug owned by someone else, or signed out, is refused', () async {
    final b = FakeBackend('u1');
    await publishStory(
      _doc(),
      storyId: 'st',
      slug: 'taken',
      backend: b,
      bytesOf: _bytes,
    );
    b.uid = 'u2';
    await expectLater(
      publishStory(
        _doc(),
        storyId: 'x',
        slug: 'taken',
        backend: b,
        bytesOf: _bytes,
      ),
      throwsA(isA<PublishException>()),
    );
    b.uid = null;
    await expectLater(
      publishStory(
        _doc(),
        storyId: 'x',
        slug: 'free',
        backend: b,
        bytesOf: _bytes,
      ),
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
            slug: 'covered',
            backend: b,
            bytesOf: _bytes,
            cover: cover,
          );
      await go(() async => Uint8List.fromList([9, 9]));
      final image = b.records['covered']!.image;
      expect(image, startsWith('https://cdn.test/o/'));
      expect(b.fetch(image), [9, 9]);
      final uploads = b.uploads;
      await go(() async => Uint8List.fromList([9, 9]));
      expect(b.uploads - uploads, 2); // the document and manifest only
      await go(() async => throw StateError('no renderer'));
      expect(b.records['covered']!.image, isEmpty);
      expect(b.records['covered']!.version, 3);
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
        slug: 'chunky',
        backend: b,
        bytesOf: _bytes,
      );
      final rec = b.records['chunky']!;
      expect(rec.manifest, 'published/u1/chunky/v1.manifest.json');
      final story = await openPublished(
        'chunky',
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
        slug: 'chunky',
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
      slug: 'old',
      backend: b,
      bytesOf: _bytes,
    );
    final r = b.records['old']!;
    b.records['old'] = PublishedRecord(
      ownerId: r.ownerId,
      storyId: r.storyId,
      version: r.version,
      path: r.path,
    );
    final story = await openPublished(
      'old',
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
      slug: 'quiet',
      backend: b,
      bytesOf: _bytes,
    );
    final whole = utf8.decode(b.files[b.records['quiet']!.path]!);
    expect(whole, isNot(contains('private')));
    expect(whole, isNot(contains('secret idea')));
    expect(whole, isNot(contains('draft mark')));
    final manifest = utf8.decode(b.files[b.records['quiet']!.manifest]!);
    expect(manifest, isNot(contains('private')));
    expect(manifest, isNot(contains('secret idea')));
  });

  test('missing files are reported, not fatal', () async {
    final b = FakeBackend('u1');
    final r = await publishStory(
      _doc(),
      storyId: 'st',
      slug: 'gaps',
      backend: b,
      bytesOf: (a) async => null,
    );
    expect(r.warnings, hasLength(2));
    expect(
      jsonDecode(utf8.decode(b.files[b.records['gaps']!.path]!)),
      isA<Map<String, Object?>>(),
    );
  });
}
