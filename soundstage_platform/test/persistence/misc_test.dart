import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/persistence/autosave.dart';
import 'package:soundstage_platform/app/persistence/db_story_repository.dart';
import 'package:soundstage_platform/app/persistence/dominant_color.dart';
import 'package:soundstage_platform/app/persistence/records.dart';
import 'package:soundstage_platform/app/persistence/story_database.dart';
import 'package:soundstage_platform/app/persistence/story_package.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'contract.dart';

ir.StageDocument doc(String t) => ir.StageDocument.empty(
  ids: ir.IdGenerator.seeded(1),
  meta: ir.StageMeta(title: t),
);

void main() {
  group('autosave', () {
    test('debounces 800 ms after the last change', () {
      fakeAsync((async) {
        final saved = <String>[];
        final a = AutosaveController(
          save: (d) async => saved.add(d.meta.title),
        );
        a.notifyChanged(doc('1'));
        async.elapse(const Duration(milliseconds: 700));
        a.notifyChanged(doc('2'));
        async.elapse(const Duration(milliseconds: 700));
        expect(saved, isEmpty);
        expect(a.status.value.state, SaveState.saving);
        async.elapse(const Duration(milliseconds: 150));
        expect(saved, ['2']);
        expect(a.status.value.state, SaveState.saved);
      });
    });

    test('saves at most 5 s into continuous edits', () {
      fakeAsync((async) {
        final saved = <String>[];
        final a = AutosaveController(
          save: (d) async => saved.add(d.meta.title),
        );
        for (var i = 0; i < 80; i++) {
          a.notifyChanged(doc('$i'));
          async.elapse(const Duration(milliseconds: 100));
        }
        expect(saved, isNotEmpty);
        expect(saved.length, lessThanOrEqualTo(2));
      });
    });

    test('flush writes now; read-only and offline never write', () {
      fakeAsync((async) {
        final saved = <String>[];
        final a = AutosaveController(
          save: (d) async => saved.add(d.meta.title),
        );
        a.notifyChanged(doc('x'));
        a.flush();
        async.flushMicrotasks();
        expect(saved, ['x']);
        final ro = AutosaveController(
          save: (d) async => saved.add('ro'),
          readOnly: true,
        );
        ro.notifyChanged(doc('y'));
        async.elapse(const Duration(seconds: 10));
        expect(saved, ['x']);
        expect(ro.status.value.state, SaveState.readOnly);
        final off = AutosaveController(save: (d) async {}, available: false);
        expect(off.status.value.state, SaveState.offline);
      });
    });

    test('a failed write reports an error and retries', () {
      fakeAsync((async) {
        var fail = true;
        final saved = <String>[];
        final a = AutosaveController(
          save: (d) async {
            if (fail) throw const StorageFullException();
            saved.add(d.meta.title);
          },
        );
        a.notifyChanged(doc('q'));
        async.elapse(const Duration(seconds: 1));
        expect(a.status.value.state, SaveState.error);
        fail = false;
        async.elapse(const Duration(seconds: 6));
        expect(saved, ['q']);
        expect(a.status.value.state, SaveState.saved);
      });
    });
  });

  test('retention keeps newest N, head, and one per hour for a day', () {
    final now = DateTime(2026, 10, 23, 12);
    final base = now.millisecondsSinceEpoch;
    final revs = [
      for (var i = 1; i <= 100; i++)
        RevisionInfo(rev: i, savedAt: base - (100 - i) * 60000 * 10, size: 1),
    ];
    final doomed = revisionsToDelete(revs, head: 100, now: now);
    expect(doomed.contains(100), isFalse);
    expect({for (var i = 51; i <= 100; i++) i}.intersection(doomed), isEmpty);
    expect(doomed, isNotEmpty);
    // an old revision outside the day and the last N is dropped
    final old = revisionsToDelete(
      [
        RevisionInfo(rev: 1, savedAt: base - 3 * 86400000, size: 1),
        ...[
          for (var i = 2; i <= 60; i++)
            RevisionInfo(rev: i, savedAt: base, size: 1),
        ],
      ],
      head: 60,
      now: now,
    );
    expect(old, contains(1));
  });

  test('dominant colour prefers a saturated subject over grey', () {
    final px = Uint8List(4 * 100);
    for (var i = 0; i < 100; i++) {
      final red = i < 45;
      px.setRange(
        i * 4,
        i * 4 + 4,
        red ? [220, 20, 20, 255] : [128, 128, 128, 255],
      );
    }
    final c = dominantColorOfRgba(px)!;
    expect((c >> 16) & 0xFF, greaterThan(200));
    expect(dominantColorOfRgba(Uint8List(16)), isNull);
  });

  test('zip round trip with assets, collision remap', () async {
    final db = MemoryStoryDatabase();
    final h = Harness(db, DateTime.now);
    final a = await h.assets.put(
      Uint8List.fromList([5, 6, 7]),
      'image/png',
      name: 'a',
    );
    final d = doc('Zipped').copyWith(assets: {a.id: a});
    final zip = await exportStageZip(d, (x) => h.assets.get(x.id));
    expect(looksLikeZip(zip), isTrue);

    // Same store: identical content reuses the id.
    final same = await importStoryFile(zip, h.assets);
    expect(same.document!.assets.keys, [a.id]);
    expect(same.assetCount, 1);

    // Fresh store: ids kept.
    final h2 = Harness(MemoryStoryDatabase(), DateTime.now);
    final fresh = await importStoryFile(zip, h2.assets);
    expect(fresh.document!.assets[a.id]!.uri, 'local://${a.id}');
    expect(await h2.assets.get(a.id), Uint8List.fromList([5, 6, 7]));

    // Collision with different bytes: remapped.
    await db.putAsset(
      AssetRecord(
        AssetMeta(id: a.id, mime: 'image/png', byteSize: 1, createdAt: 0),
        Uint8List.fromList([0]),
      ),
    );
    final h3 = Harness(db, DateTime.now);
    final clash = await importStoryFile(zip, h3.assets);
    final newId = clash.document!.assets.keys.single;
    expect(newId, isNot(a.id));
    expect(clash.document!.assets[newId]!.uri, 'local://$newId');
    expect(await h3.assets.get(newId), Uint8List.fromList([5, 6, 7]));
  });

  test(
    'zip round trip of an image sequence, collision remaps all frames',
    () async {
      final db = MemoryStoryDatabase();
      final h = Harness(db, DateTime.now);
      final seq = await h.assets.putSequence([
        for (var i = 0; i < 3; i++) (Uint8List.fromList([i, i]), 'image/webp'),
      ], name: 'walk');
      final d = doc('Seq').copyWith(assets: {seq.id: seq});
      Future<Uint8List?> bytesOf(ir.Asset x) =>
          h.assets.get(x.uri.substring('local://'.length));
      final zip = await exportStageZip(d, bytesOf);

      final h2 = Harness(MemoryStoryDatabase(), DateTime.now);
      final fresh = await importStoryFile(zip, h2.assets);
      expect(fresh.warnings, isEmpty);
      expect(fresh.document!.assets[seq.id]!.uri, seq.uri);
      expect(await h2.assets.get('${seq.id}_0002'), Uint8List.fromList([1, 1]));

      // A different frame under the same id: the whole sequence moves.
      await db.putAsset(
        AssetRecord(
          AssetMeta(
            id: '${seq.id}_0003',
            mime: 'image/webp',
            byteSize: 1,
            createdAt: 0,
          ),
          Uint8List.fromList([9]),
        ),
      );
      final clash = await importStoryFile(
        zip,
        Harness(db, DateTime.now).assets,
      );
      final newId = clash.document!.assets.keys.single;
      expect(newId, isNot(seq.id));
      expect(clash.document!.assets[newId]!.uri, 'local://${newId}_{0001}');
      for (var i = 1; i <= 3; i++) {
        expect(
          await db.getAsset('${newId}_000$i'),
          isNotNull,
          reason: 'frame $i',
        );
      }
      expect(
        ir
            .validateDocument(clash.document!)
            .where((x) => x.severity == ir.IrSeverity.error),
        isEmpty,
      );
    },
  );

  test('json import and bad input', () async {
    final h = Harness(MemoryStoryDatabase(), DateTime.now);
    final json = Uint8List.fromList(exportStageJson(doc('J')).codeUnits);
    expect((await importStoryFile(json, h.assets)).document!.meta.title, 'J');
    await expectLater(
      importStoryFile(Uint8List.fromList([1, 2, 3]), h.assets),
      throwsA(isA<ImportException>()),
    );
    await expectLater(
      importStoryFile(Uint8List.fromList('PKxx'.codeUnits), h.assets),
      throwsA(isA<ImportException>()),
    );
  });

  test('local:// resolves through the resolver', () async {
    final h = Harness(MemoryStoryDatabase(), DateTime.now);
    final a = await h.assets.put(Uint8List.fromList([4, 2]), 'image/png');
    final r = StageAssetResolver(local: h.assets);
    expect(await r.load(a.uri), Uint8List.fromList([4, 2]));
    await expectLater(r.load('local://missing'), throwsStateError);
    await expectLater(
      StageAssetResolver().load('local://x'),
      throwsUnsupportedError,
    );
  });

  test('a full disk fails the save and keeps the last good head', () async {
    final db = MemoryStoryDatabase();
    final h = Harness(db, DateTime.now);
    final s = await h.repo.create(title: 'ok');
    db.quotaBytes = db.usedBytes + 1;
    final d = (await h.repo.load(s.id))!;
    await expectLater(
      h.repo.save(s.id, d.copyWith(meta: d.meta.copyWith(title: 'big'))),
      throwsA(isA<StorageFullException>()),
    );
    expect((await h.repo.load(s.id))!.meta.title, 'ok');
  });
}
