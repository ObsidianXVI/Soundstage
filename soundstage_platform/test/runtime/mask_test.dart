import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

ir.ShapeNode _rect(
  String id,
  double x,
  double y,
  double w,
  ir.StageColor color, {
  ir.MaskMode mask = ir.MaskMode.none,
}) => ir.ShapeNode(
  common: ir.NodeCommon(id: id, x: x, y: y, width: w, height: w, mask: mask),
  appearance: ir.Appearance(
    fills: [ir.Paint.solid(id: 'f', color: color)],
  ),
);

const _red = ir.StageColor(r: 1, g: 0, b: 0);

Future<List<int>> _pixel(
  WidgetTester tester,
  GlobalKey key,
  int x,
  int y,
) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final data = await tester.runAsync(() async {
    final image = await boundary.toImage();
    return image.toByteData(format: ui.ImageByteFormat.rawRgba);
  });
  final i = (y * 100 + x) * 4;
  return [for (var k = 0; k < 4; k++) data!.getUint8(i + k)];
}

Future<GlobalKey> _pump(WidgetTester tester, List<ir.Node> children) async {
  setViewport(tester, const Size(100, 100));
  final doc = docWithRoot(
    ir.FrameNode(
      common: const ir.NodeCommon(id: 'root', width: 100, height: 100),
      children: children,
    ),
    breakpoints: const [kDesktop],
  );
  final resolved = ir.resolveDocument(doc);
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: StageScope(
        environment: StageEnvironment.forDocument(doc),
        child: RepaintBoundary(
          key: key,
          child: StageSceneView(
            scene: resolved.scenes.first,
            viewportSize: const Size(100, 100),
            breakpoint: resolved.breakpoint,
          ),
        ),
      ),
    ),
  );
  return key;
}

void main() {
  testWidgets('an alpha mask shows the siblings above it only where it is '
      'opaque, and does not show itself', (tester) async {
    final key = await _pump(tester, [
      _rect('m', 0, 0, 50, ir.StageColor.white, mask: ir.MaskMode.alpha),
      _rect('a', 0, 0, 100, _red),
    ]);
    expect(await _pixel(tester, key, 25, 25), [255, 0, 0, 255]);
    expect((await _pixel(tester, key, 75, 75))[3], 0);
  });

  testWidgets('a luminance mask: black hides, white shows', (tester) async {
    final key = await _pump(tester, [
      _rect('m', 0, 0, 100, ir.StageColor.black, mask: ir.MaskMode.luminance),
      _rect('w', 0, 0, 50, ir.StageColor.white, mask: ir.MaskMode.none),
      _rect('a', 0, 0, 100, _red),
    ]);
    // `w` is above the mask, so it is masked too (fully hidden).
    expect((await _pixel(tester, key, 75, 75))[3], 0);
    expect((await _pixel(tester, key, 25, 25))[3], 0);
  });

  testWidgets('a white luminance mask shows what it covers', (tester) async {
    final key = await _pump(tester, [
      _rect('m', 0, 0, 50, ir.StageColor.white, mask: ir.MaskMode.luminance),
      _rect('a', 0, 0, 100, _red),
    ]);
    expect(await _pixel(tester, key, 25, 25), [255, 0, 0, 255]);
    expect((await _pixel(tester, key, 75, 75))[3], 0);
  });
}
