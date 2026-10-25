import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/overlay/overlay_geometry.dart';
import 'package:soundstage_platform/editor/overlay/selection_frame.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'interaction_harness.dart';

// DECISIONS 26/10/26 T2.0-3: canvas drags, resizes and rotations of
// animated geometry start from the value shown at the playhead and write
// keyframes through the SetProperty routing, as one gesture.

ir.Keyframe _kf(String id, double t, double v) =>
    ir.Keyframe(id: id, t: t, value: ir.IrValue.number(v));

/// [interactionDoc] with a scroll clock and [tracks] on `a` (100,100 100×100).
ir.StageDocument _doc(List<ir.Track> tracks) {
  final doc = interactionDoc();
  final s = doc.scenes.single;
  return doc.copyWith(
    scenes: [
      s.copyWith(
        clocks: const [ir.Clock.sceneScroll(id: 'clk', sceneId: 's1')],
        tracks: tracks,
      ),
    ],
  );
}

ir.Track _track(String id, String property, double from, double to) => ir.Track(
  id: id,
  target: 'a',
  property: property,
  clockId: 'clk',
  keyframes: [_kf('${id}0', 0, from), _kf('${id}1', 1, to)],
);

List<(double, ir.IrValue)> _keys(Harness h, String id) => [
  for (final k
      in h.doc.scenes.single.tracks.singleWhere((t) => t.id == id).keyframes)
    (k.t, k.value),
];

void main() {
  testWidgets('a move of an animated x starts from the playhead and writes '
      'a keyframe; the static axis stays static', (tester) async {
    final h = await pumpCanvas(
      tester,
      doc: _doc([_track('ax', 'x', 100, 300)]),
    );
    h.ctl.setActivePlayhead(0.5); // x shows 200
    await tester.pump();
    final depth = h.ctl.history.undoDepth;
    await h.drag(h.desk(250, 150), h.desk(280, 160), steps: 6);
    expect(_keys(h, 'ax'), [
      (0.0, const ir.IrValue.number(100)),
      (0.5, const ir.IrValue.number(230)),
      (1.0, const ir.IrValue.number(300)),
    ]);
    // x's static value is untouched; y (not animated) moved statically.
    expect(h.common('a').x, 100);
    expect(h.common('a').y, 110);
    expect(h.ctl.history.undoDepth, depth + 1);
    h.ctl.undo();
    await tester.pump();
    expect(_keys(h, 'ax'), hasLength(2));
    expect(h.common('a').y, 100);
  });

  testWidgets('a resize of an animated width starts from the playhead', (
    tester,
  ) async {
    final h = await pumpCanvas(
      tester,
      doc: _doc([_track('aw', 'width', 100, 300)]),
    );
    h.ctl.setActivePlayhead(0.5); // width shows 200: a spans 100..300
    await tester.pump();
    await h.click(h.desk(150, 150));
    await h.drag(h.desk(300, 150), h.desk(340, 150), steps: 6);
    expect(_keys(h, 'aw')[1], (0.5, const ir.IrValue.number(240)));
    expect(h.common('a').width, 100);
  });

  testWidgets('placements (where move, resize and rotate start) read the '
      'rendered node at the playhead', (tester) async {
    final h = await pumpCanvas(
      tester,
      doc: _doc([_track('ar', 'rotation', 0, 90)]),
    );
    h.ctl.setActivePlayhead(0.5);
    await tester.pump();
    final p = placementOf(OverlayGeometry(h.canvas), 'a', 'desktop')!;
    expect(p.rotation, 45);
    // The document keeps its static rotation.
    expect(h.common('a').rotation, 0);
  });
}
