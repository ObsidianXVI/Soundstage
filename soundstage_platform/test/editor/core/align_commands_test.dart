import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

double _x(ProviderContainer c, String id, String bp) =>
    c.resolved(id, bp).node.common.x;

StageDocument _row(List<Node> children) => StageDocument(
  id: 'd',
  breakpoints: kBreakpoints,
  scenes: [
    Scene(
      id: 's1',
      name: 'One',
      kind: SceneKind.pinned,
      scrollLength: 1,
      root: FrameNode(
        common: const NodeCommon(id: 'root', width: 1000, height: 800),
        children: children,
      ),
      clocks: const [Clock.sceneScroll(id: 'clk1', sceneId: 's1')],
    ),
  ],
);

void main() {
  group('AlignNodes', () {
    test('several nodes align to their common bounds, undoable', () {
      final c = editorContainer();
      // a1 (x 10) and a2 (x 40), both children of a.
      expectRoundTrip(c, const AlignNodes(['a1', 'a2'], AlignEdge.left));
      expect(c.node('a1').common.x, 10);
      expect(c.node('a2').common.x, 10);
    });

    test('one node aligns to its parent; the scene root uses the '
        'breakpoint design size', () {
      final c = editorContainer();
      c.ctl.execute(const AlignNodes(['a1'], AlignEdge.right));
      expect(c.node('a1').common.x, 290); // a is 300 wide, a1 is 10
      final c2 = editorContainer();
      c2.ctl.setEditingBreakpoint('mobile'); // design width 400
      c2.ctl.execute(const AlignNodes(['b'], AlignEdge.horizontalCenter));
      expect(c2.node('b').common.x, 100); // (400 - 200) / 2, shared base
      expect(_x(c2, 'b', 'desktop'), 100);
    });

    test('nodes in different parents align in scene space', () {
      final c = editorContainer();
      // a1 sits at 100 + 10 = 110 on the scene; b1 at 500 + 1 = 501.
      c.ctl.execute(const AlignNodes(['a1', 'b1'], AlignEdge.left));
      expect(c.node('a1').common.x, 10);
      expect(c.node('b1').common.x, -390); // scene x 501 -> 110
    });

    test('works on what the edited breakpoint sees and scopes the write', () {
      final c = editorContainer();
      // a1's mobile patch says x 30; a2 is at 40.
      c.ctl
        ..setEditingBreakpoint('mobile')
        ..setEditScope(EditScope.thisBreakpoint);
      c.ctl.execute(const AlignNodes(['a1', 'a2'], AlignEdge.left));
      expect(_x(c, 'a2', 'mobile'), 30);
      expect(_x(c, 'a2', 'desktop'), 40, reason: 'desktop untouched');
      expect(_x(c, 'a1', 'mobile'), 30);
    });

    test('rotated nodes align by their visible bounds', () {
      final doc = _row([
        const ShapeNode(
          common: NodeCommon(
            id: 'r',
            x: 10,
            width: 20,
            height: 10,
            rotation: 90,
          ),
        ),
      ]);
      final c = editorContainer(doc);
      c.ctl.execute(const AlignNodes(['r'], AlignEdge.left));
      // Centre x = 20; rotated width = 10, so the left edge is 15.
      expect(c.node('r').common.x, -5);
    });

    test('children placed by auto layout are skipped with a warning', () {
      final c = editorContainer();
      final r = c.ctl.execute(const AlignNodes(['r1', 'r2'], AlignEdge.top));
      expect(r.changed, isFalse);
      expect(r.diagnostics, isNotEmpty);
      expect(identical(c.doc, fixtureDoc()), isFalse);
    });

    test('vertical edges write y', () {
      final c = editorContainer();
      c.ctl.execute(const AlignNodes(['a1', 'a2'], AlignEdge.bottom));
      // a1 bottom 30 (20 + 10), a2 bottom 200: both end at 200.
      expect(c.node('a1').common.y, 190);
      expect(c.node('a2').common.y, 100);
    });
  });

  group('DistributeNodes', () {
    StageDocument three() => _row([
      for (final (id, x) in [('p', 0.0), ('q', 120.0), ('r', 500.0)])
        ShapeNode(
          common: NodeCommon(id: id, x: x, width: 100, height: 10),
        ),
    ]);

    test('equalises the gaps; the outer two stay', () {
      final c = editorContainer(three());
      expectRoundTrip(
        c,
        const DistributeNodes(['p', 'q', 'r'], horizontal: true),
      );
      expect(c.node('p').common.x, 0);
      expect(c.node('q').common.x, 250);
      expect(c.node('r').common.x, 500);
    });

    test('needs three nodes', () {
      final c = editorContainer(three());
      final r = c.ctl.execute(
        const DistributeNodes(['p', 'q'], horizontal: true),
      );
      expect(r.changed, isFalse);
      expect(r.diagnostics, isNotEmpty);
    });

    test('is independent of selection order', () {
      final c = editorContainer(three());
      c.ctl.execute(const DistributeNodes(['r', 'p', 'q'], horizontal: true));
      expect(c.node('q').common.x, 250);
    });
  });
}
