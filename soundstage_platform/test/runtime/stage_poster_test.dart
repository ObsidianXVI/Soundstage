import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

const _red = ir.StageColor(r: 1, g: 0, b: 0);
const _white = ir.StageColor(r: 1, g: 1, b: 1);

ir.StageDocument _doc() => const ir.StageDocument(
  id: 'd',
  breakpoints: [
    ir.Breakpoint(
      id: 'bp',
      name: 'Bp',
      minWidth: 0,
      designSize: ir.StageSize(width: 200, height: 100),
      primary: true,
    ),
  ],
  scenes: [
    ir.Scene(
      id: 's',
      root: ir.FrameNode(
        common: ir.NodeCommon(id: 'root', width: 200, height: 100),
        appearance: ir.Appearance(
          fills: [ir.Paint.solid(id: 'w', color: _white)],
        ),
        children: [
          ir.FrameNode(
            common: ir.NodeCommon(
              id: 'box',
              x: 120,
              y: 20,
              width: 60,
              height: 40,
            ),
            appearance: ir.Appearance(
              fills: [ir.Paint.solid(id: 'r', color: _red)],
            ),
          ),
        ],
      ),
      clocks: [ir.Clock.sceneScroll(id: 'c', sceneId: 's')],
      tracks: [
        // The box fades in over the scroll: transparent at 0, opaque at 1.
        ir.Track(
          id: 't',
          target: 'box',
          property: 'opacity',
          clockId: 'c',
          keyframes: [
            ir.Keyframe(id: 'k0', t: 0, value: ir.IrValue.number(0)),
            ir.Keyframe(id: 'k1', t: 1, value: ir.IrValue.number(1)),
          ],
        ),
      ],
    ),
  ],
);

Future<(int, int, ByteData)> _decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData())!;
  return (image.width, image.height, data);
}

int _redAt(ByteData d, int width, int x, int y) =>
    d.getUint8((y * width + x) * 4);
int _greenAt(ByteData d, int width, int x, int y) =>
    d.getUint8((y * width + x) * 4 + 1);

void main() {
  testWidgets('a scene renders off screen at its poster clock', (tester) async {
    final doc = _doc();
    final env = StageEnvironment.forDocument(doc, mode: StageRenderMode.edit);
    final (opaque, faded) = (await tester.runAsync(
      () async => (
        await renderStagePoster(doc, env, sceneId: 's', clock: 1),
        await renderStagePoster(doc, env, sceneId: 's', clock: 0),
      ),
    ))!;
    final (w, h, full) = (await tester.runAsync(() => _decode(opaque!)))!;
    expect((w, h), (200, 100));
    // Inside the box: red; outside: white.
    expect(_redAt(full, w, 150, 40), 255);
    expect(_greenAt(full, w, 150, 40), lessThan(10));
    expect(_greenAt(full, w, 20, 20), 255);
    final (_, _, none) = (await tester.runAsync(() => _decode(faded!)))!;
    expect(_greenAt(none, w, 150, 40), 255); // opacity 0: white shows
    expect(tester.takeException(), isNull);
  });

  testWidgets('a node poster is cropped to the node', (tester) async {
    final doc = _doc();
    final env = StageEnvironment.forDocument(doc, mode: StageRenderMode.edit);
    final png = await tester.runAsync(
      () => renderStagePoster(
        doc,
        env,
        sceneId: 's',
        clock: 1,
        nodeId: 'box',
        pixelRatio: 2,
      ),
    );
    final (w, h, d) = (await tester.runAsync(() => _decode(png!)))!;
    expect((w, h), (120, 80));
    expect(_redAt(d, w, 60, 40), 255);
    expect(_greenAt(d, w, 60, 40), lessThan(10));
    expect(
      await tester.runAsync(() => renderStagePoster(doc, env, sceneId: 'nope')),
      isNull,
    );
  });
}
