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
    final first = b.uploads; // 3 assets files + 1 document
    expect(first, 4);
    final r = await go();
    expect(r.version, 2);
    expect(b.uploads - first, 1); // only the new document
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
      expect(b.uploads - uploads, 1); // the document only
      await go(() async => throw StateError('no renderer'));
      expect(b.records['covered']!.image, isEmpty);
      expect(b.records['covered']!.version, 3);
    },
  );

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
