import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/data/project_library.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

void main() {
  ir.StageDocument doc() =>
      ir.StageDocument.empty(ids: ir.IdGenerator.seeded(1)).copyWith(
        fonts: const {
          'serif': ir.FontFamily(
            id: 'serif',
            name: 'Fraunces',
            faces: [ir.FontFace(assetId: 'font-file')],
          ),
        },
        assets: const {
          'font-file': ir.Asset(
            id: 'font-file',
            kind: ir.AssetKind.font,
            uri: 'local://font-file',
            mime: 'font/ttf',
          ),
          'photo': ir.Asset(
            id: 'photo',
            kind: ir.AssetKind.image,
            uri: 'local://photo',
            mime: 'image/png',
          ),
        },
      );

  test('the library takes the design system and the assets it uses', () {
    final lib = ProjectLibrary.of(doc());
    expect(lib.fonts.keys, ['serif']);
    expect(lib.assets.keys, ['font-file'], reason: 'the photo is content');
    final back = ProjectLibrary.fromJson(
      jsonDecode(jsonEncode(lib.toJson())) as Map<String, Object?>,
    );
    expect(back.fonts['serif']!.name, 'Fraunces');
    expect(back.assets.keys, ['font-file']);
  });

  test('applying keeps the issue content and its own assets', () {
    final lib = ProjectLibrary.of(doc());
    final issue = lib.blankIssue(title: 'Issue 1');
    expect(issue.meta.title, 'Issue 1');
    expect(issue.scenes, hasLength(1));
    expect(issue.fonts.keys, ['serif']);
    expect(issue.assets.keys, ['font-file']);
  });

  test('in memory: issues, templates and the shared library', () async {
    final repo = InMemoryStoryRepository(loadAsset: (_) async => '{}');
    final p = await repo.createProject(title: 'Letters');
    final i1 = await repo.createIssue(p.id);
    await repo.save(i1.id, doc().copyWith(id: i1.id));
    final i2 = await repo.createIssue(p.id);
    expect((await repo.open(i2.id))!.document!.fonts.keys, ['serif']);
    final i3 = await repo.createIssue(p.id, fromStoryId: i1.id);
    expect(i3.title, 'Issue 3');
    expect((await repo.projects()).single.issueCount, 3);
    await repo.deleteProject(p.id);
    expect(await repo.load(i1.id), isNull);
  });
}
