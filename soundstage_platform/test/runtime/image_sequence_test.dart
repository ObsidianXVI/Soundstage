import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

class _Local implements LocalAssetLoader {
  _Local(this.files);

  final Map<String, Uint8List> files;
  final requested = <String>[];

  @override
  Future<Uint8List?> loadBytes(String assetId) async {
    requested.add(assetId);
    return files[assetId];
  }

  @override
  Future<String?> acquireObjectUrl(String assetId) async => null;

  @override
  void releaseObjectUrl(String assetId) {}
}

Future<Uint8List> _png(Color c) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawColor(c, BlendMode.src);
  final image = await rec.endRecording().toImage(2, 2);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

Future<int> _red(ui.Image image) async {
  final data = await image.toByteData();
  return data!.getUint8(0);
}

const _reds = [10, 120, 250];

ir.StageDocument _doc({bool bound = true}) => ir.StageDocument(
  id: 'd',
  breakpoints: [
    const ir.Breakpoint(
      id: 'bp',
      name: 'Bp',
      minWidth: 0,
      designSize: ir.StageSize(width: 400, height: 300),
    ),
  ],
  assets: {
    'seq': const ir.Asset(
      id: 'seq',
      kind: ir.AssetKind.imageSequence,
      uri: 'local://seq_{0001}',
      mime: 'image/png',
      frameCount: 3,
      width: 2,
      height: 2,
    ),
  },
  scenes: [
    ir.Scene(
      id: 's',
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 400, height: 300),
        children: [
          ir.EmbedNode(
            common: const ir.NodeCommon(id: 'e', width: 100, height: 100),
            assetId: 'seq',
            inputBindings: bound ? const {'progress': 'c'} : const {},
            autoplay: true,
          ),
        ],
      ),
      clocks: [const ir.Clock.sceneScroll(id: 'c', sceneId: 's')],
    ),
  ],
);

void main() {
  tearDown(() => StageAssetResolver.defaultLocal = null);

  testWidgets('an image sequence shows the frame its bound clock picks', (
    tester,
  ) async {
    final files = (await tester.runAsync(
      () async => {
        for (final (i, r) in _reds.indexed)
          'seq_000${i + 1}': await _png(Color.fromARGB(255, r, 0, 0)),
      },
    ))!;
    final local = _Local(files);
    StageAssetResolver.defaultLocal = local;

    Future<int?> shownRed(double progress) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StagePlayer(
            document: _doc(),
            mode: StageRenderMode.edit,
            clockOverrides: {'c': progress},
            viewportOverride: const Size(400, 300),
          ),
        ),
      );
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 30));
      }
      final image = tester.widget<RawImage>(find.byType(RawImage)).image;
      if (image == null) return null;
      return tester.runAsync(() => _red(image));
    }

    expect(await shownRed(1), _reds[2]);
    expect(await shownRed(0.5), _reds[1]);
    expect(await shownRed(0), _reds[0]);
    expect(local.requested.toSet(), files.keys.toSet());
    expect(tester.takeException(), isNull);
  });

  testWidgets('unbound, it plays at frameCount / duration and loops', (
    tester,
  ) async {
    final files = (await tester.runAsync(
      () async => {
        for (final (i, r) in _reds.indexed)
          'seq_000${i + 1}': await _png(Color.fromARGB(255, r, 0, 0)),
      },
    ))!;
    StageAssetResolver.defaultLocal = _Local(files);
    final doc = _doc(bound: false);
    final seq = doc.assets['seq']!.copyWith(duration: 3); // 1 fps
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StagePlayer(
          document: doc.copyWith(assets: {'seq': seq}),
          viewportOverride: const Size(400, 300),
        ),
      ),
    );
    Future<int?> red() async {
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
      final image = tester.widget<RawImage>(find.byType(RawImage)).image;
      return image == null ? null : tester.runAsync(() => _red(image));
    }

    expect(await red(), _reds[0]);
    await tester.pump(const Duration(milliseconds: 1000));
    expect(await red(), _reds[1]);
    await tester.pump(const Duration(milliseconds: 2000));
    expect(await red(), _reds[0]); // looped
    await tester.pumpWidget(const SizedBox());
  });
}
