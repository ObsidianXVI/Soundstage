import 'dart:typed_data';

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/insert/insert_nodes.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'fakes.dart';

EditorFile _f(String name, [String mime = 'image/png']) =>
    (name: name, bytes: Uint8List.fromList(name.codeUnits), mime: mime);

void main() {
  test('frames sort by name with numbers compared as numbers', () {
    final sorted = sortFrames([_f('f10.png'), _f('f2.png'), _f('f1.png')]);
    expect(sorted.map((f) => f.name), ['f1.png', 'f2.png', 'f10.png']);
  });

  test('a sequence is named after its frames', () {
    expect(sequenceName([_f('walk_0001.webp'), _f('walk_0002.webp')]), 'walk');
    expect(sequenceName([_f('0001.png'), _f('0002.png')]), 'Image sequence');
    expect(sequenceName([_f('intro-01.png')]), 'intro');
  });

  test('ingest stores the frames in order; a non-image is refused', () async {
    final service = FakeAssetService();
    final a = await ingestSequence(service, [_f('s2.png'), _f('s1.png')]);
    expect(a.kind, ir.AssetKind.imageSequence);
    expect(a.frameCount, 2);
    expect(
      service.files['${a.id}_0001'],
      Uint8List.fromList('s1.png'.codeUnits),
    );
    await expectLater(
      ingestSequence(service, [_f('s1.png'), _f('x.mp3', 'audio/mpeg')]),
      throwsA(isA<AssetServiceException>()),
    );
  });

  test('a sequence asset becomes an embed node', () {
    const a = ir.Asset(
      id: 'q',
      kind: ir.AssetKind.imageSequence,
      uri: 'local://q_{0001}',
      frameCount: 2,
    );
    final n = buildMediaNode(a, 'n', 'p', const Rect.fromLTWH(0, 0, 64, 36));
    expect(n, isA<ir.EmbedNode>());
    expect(n.common.role, ir.NodeRole.figure);
  });

  test('placeable kinds: everything but audio and fonts', () {
    expect(
      {
        for (final k in ir.AssetKind.values)
          if (isPlaceableKind(k)) k,
      },
      {
        ir.AssetKind.image,
        ir.AssetKind.video,
        ir.AssetKind.lottie,
        ir.AssetKind.rive,
        ir.AssetKind.imageSequence,
      },
    );
  });
}
