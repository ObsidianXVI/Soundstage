import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

String _json(String title) {
  final doc = ir.StageDocument.empty(
    ids: ir.IdGenerator.seeded(3),
    meta: ir.StageMeta(title: title),
  );
  return jsonEncode(doc.toJson());
}

void main() {
  late InMemoryStoryRepository repo;
  var clock = DateTime(2026, 10, 23);
  setUp(() {
    clock = DateTime(2026, 10, 23);
    repo = InMemoryStoryRepository(
      loadAsset: (path) async => _json('Loaded $path'),
      now: () => clock = clock.add(const Duration(minutes: 1)),
    );
  });

  test('lists the bundled demos', () async {
    final list = await repo.list();
    expect(list.map((s) => s.id), kBundledStories.map((b) => b.id));
    expect(list.every((s) => s.bundled), isTrue);
  });

  test('creates a story with one blank pinned scene, listed first, '
      'loadable', () async {
    final s = await repo.create(title: 'My story');
    final list = await repo.list();
    expect(list.first.id, s.id);
    expect(list.first.title, 'My story');
    expect(list.first.bundled, isFalse);
    final doc = await repo.load(s.id);
    expect(doc, isNotNull);
    expect(doc!.scenes, hasLength(1));
    expect(doc.scenes.single.kind, ir.SceneKind.pinned);
    expect(list.first.sceneCount, 1);
    expect(doc.meta.title, 'My story');
  });

  test('bundled stories load from assets once', () async {
    var loads = 0;
    final r = InMemoryStoryRepository(
      loadAsset: (path) async {
        loads++;
        return _json('x');
      },
    );
    final a = await r.load('demo-static');
    final b = await r.load('demo-static');
    expect(identical(a, b), isTrue);
    expect(loads, 1);
  });

  test('unknown ids load as null', () async {
    expect(await repo.load('nope'), isNull);
  });

  test('save, rename and delete', () async {
    final s = await repo.create();
    final doc = (await repo.load(s.id))!;
    await repo.save(
      s.id,
      doc.copyWith(meta: doc.meta.copyWith(title: 'Renamed in doc')),
    );
    expect((await repo.list()).first.title, 'Renamed in doc');
    await repo.rename(s.id, 'Final');
    expect((await repo.list()).first.title, 'Final');
    await repo.delete(s.id);
    expect(await repo.load(s.id), isNull);
    expect((await repo.list()).any((x) => x.id == s.id), isFalse);

    await repo.delete('demo-motion');
    expect((await repo.list()).any((x) => x.id == 'demo-motion'), isFalse);
    expect(await repo.load('demo-motion'), isNull);
  });

  test('the most recently updated own story is first', () async {
    final a = await repo.create(title: 'A');
    final b = await repo.create(title: 'B');
    expect((await repo.list()).first.id, b.id);
    await repo.rename(a.id, 'A2');
    expect((await repo.list()).first.id, a.id);
  });
}
