import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../interaction/interaction_harness.dart';

/// One scene of [kind]: a 1000×800 clipped root holding `top` (inside),
/// `low` (below the stored height, 900..1000), `rotLow` (rotated 90°, its
/// rotated box reaching 1150) and `pinB` (bottom-anchored, 50 from the
/// bottom).
ir.StageDocument _doc(ir.SceneKind kind) => ir.StageDocument(
  id: 'doc',
  breakpoints: kBps,
  scenes: [
    ir.Scene(
      id: 's1',
      name: 'One',
      kind: kind,
      scrollLength: kind == ir.SceneKind.pinned ? 1 : 0,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 1000, height: 800),
        clipContent: true,
        children: [
          rect('top', 100, 100, 100, 100),
          rect('low', 100, 900, 100, 100),
          rect('rotLow', 400, 1000, 200, 100, rotation: 90),
          rect(
            'pinB',
            700,
            700,
            100,
            50,
            layoutChild: const ir.LayoutChild(
              constraints: ir.Constraints(
                vertical: ir.VerticalConstraint.bottom,
              ),
            ),
          ),
        ],
      ),
    ),
  ],
);

void main() {
  const cam = CanvasCamera(zoom: 0.5, panX: 40, panY: 40);

  testWidgets('a flow artboard grows to its content; nodes below the '
      'stored height draw and can be selected', (tester) async {
    final h = await pumpCanvas(
      tester,
      doc: _doc(ir.SceneKind.flow),
      camera: cam,
    );
    final board = h.canvas.artboards['desktop']!.worldRect;
    // rotLow: centre y 1050, rotated extent 200 → bottom 1150.
    expect(board.height, closeTo(1150, 1e-6));
    expect(
      h.worldRect('low'),
      rectNear(const Rect.fromLTWH(100, 900, 100, 100)),
    );
    // Top-anchored nodes keep their place; bottom-anchored ones follow.
    expect(
      h.worldRect('top'),
      rectNear(const Rect.fromLTWH(100, 100, 100, 100)),
    );
    expect(h.worldRect('pinB')!.bottom, closeTo(1150 - 50, 1e-6));

    // Selectable by a click below the stored height.
    await h.click(h.desk(150, 950));
    expect(h.st.selection, {'low'});
    expect(h.canvas.overlay.hitTest(h.desk(150, 950)).first.nodeId, 'low');

    // Drawn: the root's clip now covers it (the root itself grew).
    final root = h.canvas.artboards['desktop']!.registry['root']!;
    expect(root.size.height, closeTo(1150, 1e-6));
  });

  testWidgets('pinned artboards keep the viewport height', (tester) async {
    final h = await pumpCanvas(
      tester,
      doc: _doc(ir.SceneKind.pinned),
      camera: cam,
    );
    final board = h.canvas.artboards['desktop']!.worldRect;
    expect(board.height, closeTo(800, 1e-6));
    final root = h.canvas.artboards['desktop']!.registry['root']!;
    expect(root.size.height, closeTo(800, 1e-6));
    expect(h.worldRect('pinB')!.bottom, closeTo(800 - 50, 1e-6));
    // Below the clip: not hittable.
    expect(h.canvas.overlay.hitTest(h.desk(150, 950)), isEmpty);
  });

  testWidgets('a flow scene whose content fits keeps its stored height', (
    tester,
  ) async {
    final doc = _doc(ir.SceneKind.flow);
    final s = doc.scenes.single;
    final fits = doc.copyWith(
      scenes: [
        s.copyWith(
          root: s.root.copyWith(
            children: [s.root.children.first, s.root.children.last],
          ),
        ),
      ],
    );
    final h = await pumpCanvas(tester, doc: fits, camera: cam);
    expect(h.canvas.artboards['desktop']!.worldRect.height, closeTo(800, 1e-6));
  });
}
