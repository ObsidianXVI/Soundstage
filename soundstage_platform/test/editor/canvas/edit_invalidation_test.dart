import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/canvas/artboard.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../interaction/interaction_harness.dart';

// An edit on the canvas must invalidate only the edited path (§17.1; the
// T1.5 5,000-node drag budget): no relayout of untouched text, no full
// scene repaint.
void main() {
  test('resolved paragraphs keep their identity across reads', () {
    final doc = interactionDoc();
    final r = ir.Resolver().resolve(
      doc,
      const ir.ResolveContext(breakpointId: 'desktop'),
    );
    final txt = r.nodeIndex['txt']!;
    expect(identical(txt.paragraphs, txt.paragraphs), isTrue);
    expect(identical(txt.children, txt.children), isTrue);
  });

  testWidgets('moving a shape relays out its path only', (tester) async {
    final h = await pumpCanvas(tester);
    final layouts = RenderStageBox.debugLayoutCount;
    h.ctl.execute(SetProperty(['a'], 'x', const ir.IrValue.number(130)));
    await tester.pump();
    // The root (both artboards) and the shape (both artboards); the text
    // node beside it is not laid out again.
    expect(RenderStageBox.debugLayoutCount - layouts, lessThanOrEqualTo(4));
  });

  test('large subtrees become repaint boundaries on the artboards', () {
    ir.ResolvedNode leaf(String id) => ir.ResolvedNode(
      id: id,
      node: ir.ShapeNode(common: ir.NodeCommon(id: id)),
    );
    ir.ResolvedNode frame(String id, List<ir.ResolvedNode> kids) =>
        ir.ResolvedNode(
          id: id,
          node: ir.FrameNode(common: ir.NodeCommon(id: id)),
          children: kids,
        );
    final big = frame('big', [
      for (var i = 0; i < kEditRepaintBoundaryMin; i++) leaf('b$i'),
    ]);
    final small = frame('small', [leaf('s0'), leaf('s1')]);
    final outer = frame('outer', [big, small]);
    final root = frame('root', [outer, leaf('x')]);
    expect(editRepaintBoundaries(root), {'outer', 'big'});
  });
}
