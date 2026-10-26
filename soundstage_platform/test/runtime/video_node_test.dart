import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/src/render/render_stage_host.dart';

import 'stage_test_helpers.dart';

void main() {
  testWidgets('a video renders in a stage host; without a video platform it '
      'shows its appearance and reports nothing', (tester) async {
    final doc =
        docWithRoot(
          frame(
            'root',
            common('root', w: 800, h: 600),
            children: [
              const ir.VideoNode(
                common: ir.NodeCommon(
                  id: 'v',
                  x: 10,
                  y: 20,
                  width: 320,
                  height: 180,
                ),
                assetId: 'vid',
                controls: ir.VideoControls.full,
                appearance: ir.Appearance(
                  fills: [ir.Paint.solid(id: 'f', color: ir.StageColor.black)],
                ),
              ),
            ],
          ),
          breakpoints: const [kDesktop],
        ).copyWith(
          assets: const {
            'vid': ir.Asset(
              id: 'vid',
              kind: ir.AssetKind.video,
              uri: 'https://example.com/v.mp4',
            ),
          },
        );
    await pumpScene(tester, doc, viewport: const Size(800, 600));
    await tester.pump();
    final box = stageBox(tester, 'v');
    expect(box, isA<RenderStageHost>());
    expect(box.size, const Size(320, 180));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
