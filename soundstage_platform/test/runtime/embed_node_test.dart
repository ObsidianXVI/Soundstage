import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';
import 'package:soundstage_platform/runtime/src/render/render_stage_host.dart';

class _Local implements LocalAssetLoader {
  _Local(this.files);

  final Map<String, Uint8List> files;

  @override
  Future<Uint8List?> loadBytes(String assetId) async => files[assetId];

  @override
  Future<String?> acquireObjectUrl(String assetId) async => null;

  @override
  void releaseObjectUrl(String assetId) {}
}

/// The smallest valid Lottie: 100×100, one second, no layers.
final Uint8List _lottie = Uint8List.fromList(
  utf8.encode(
    '{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"layers":[]}',
  ),
);

void main() {
  tearDown(() => StageAssetResolver.defaultLocal = null);

  testWidgets('a Lottie embed renders, and a bound clock drives its '
      'progress input', (tester) async {
    StageAssetResolver.defaultLocal = _Local({'lot': _lottie});
    final doc = const ir.StageDocument(
      id: 'd',
      breakpoints: [
        ir.Breakpoint(
          id: 'bp',
          name: 'Bp',
          minWidth: 0,
          designSize: ir.StageSize(width: 400, height: 300),
        ),
      ],
      assets: {
        'lot': ir.Asset(
          id: 'lot',
          kind: ir.AssetKind.lottie,
          uri: 'local://lot',
        ),
      },
      scenes: [
        ir.Scene(
          id: 's',
          root: ir.FrameNode(
            common: ir.NodeCommon(id: 'root', width: 400, height: 300),
            children: [
              ir.EmbedNode(
                common: ir.NodeCommon(id: 'e', width: 100, height: 100),
                assetId: 'lot',
                inputBindings: {'progress': 'c'},
              ),
            ],
          ),
          clocks: [ir.Clock.sceneScroll(id: 'c', sceneId: 's')],
        ),
      ],
    );
    final c = StagePlayerController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StagePlayer(
          document: doc,
          mode: StageRenderMode.edit,
          clockOverrides: const {'c': 0.25},
          viewportOverride: const Size(400, 300),
          controller: c,
        ),
      ),
    );
    // Bytes, the deferred library and the composition load asynchronously.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    final host = c.nodes!['e']! as RenderStageHost;
    expect(host.inputs['progress'], 0.25);
    expect(find.byType(Lottie), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
