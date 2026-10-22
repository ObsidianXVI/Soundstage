// Render-level layout: frame trees pumped at fixed sizes produce the
// expected child rects (RenderBox geometry), through the resolver and the
// widget mapping.
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

ir.LayoutChild cons(ir.HorizontalConstraint h, ir.VerticalConstraint v) =>
    ir.LayoutChild(
      constraints: ir.Constraints(horizontal: h, vertical: v),
    );

void main() {
  testWidgets('free root: constraints against the breakpoint designSize', (
    tester,
  ) async {
    // Desktop design 1440 × 900 rendered at 1200 × 800.
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [
        rect(
          'l',
          common(
            'l',
            x: 100,
            y: 100,
            w: 200,
            h: 100,
            layoutChild: cons(
              ir.HorizontalConstraint.left,
              ir.VerticalConstraint.top,
            ),
          ),
        ),
        rect(
          'r',
          common(
            'r',
            x: 1140,
            y: 700,
            w: 200,
            h: 100,
            layoutChild: cons(
              ir.HorizontalConstraint.right,
              ir.VerticalConstraint.bottom,
            ),
          ),
        ),
        rect(
          'lr',
          common(
            'lr',
            x: 100,
            y: 100,
            w: 1240,
            h: 700,
            layoutChild: cons(
              ir.HorizontalConstraint.leftRight,
              ir.VerticalConstraint.topBottom,
            ),
          ),
        ),
        rect(
          'c',
          common(
            'c',
            x: 620,
            y: 400,
            w: 200,
            h: 100,
            layoutChild: cons(
              ir.HorizontalConstraint.center,
              ir.VerticalConstraint.center,
            ),
          ),
        ),
        rect(
          's',
          common(
            's',
            x: 144,
            y: 90,
            w: 288,
            h: 90,
            layoutChild: cons(
              ir.HorizontalConstraint.scale,
              ir.VerticalConstraint.scale,
            ),
          ),
        ),
      ],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1200, 800));
    expect(globalRect(tester, 'root'), const Rect.fromLTWH(0, 0, 1200, 800));
    expect(globalRect(tester, 'l'), const Rect.fromLTWH(100, 100, 200, 100));
    expect(globalRect(tester, 'r'), const Rect.fromLTWH(900, 600, 200, 100));
    expect(globalRect(tester, 'lr'), const Rect.fromLTWH(100, 100, 1000, 600));
    expect(globalRect(tester, 'c'), const Rect.fromLTWH(500, 350, 200, 100));
    final s = globalRect(tester, 's');
    expect(s.left, closeTo(120, 1e-9));
    expect(s.width, closeTo(240, 1e-9));
    expect(s.top, closeTo(80, 1e-9));
    expect(s.height, closeTo(80, 1e-9));
  });

  testWidgets('auto layout: fill split with a max-width freeze', (
    tester,
  ) async {
    final row = frame(
      'row',
      common('row', w: 600, h: 100),
      autoLayout: ir.AutoLayout(
        gap: const ir.Gap.fixed(10),
        padding: ir.EdgeInsetsValue.all(10),
      ),
      children: [
        rect('a', common('a', w: 100, h: 50)),
        rect(
          'b',
          common(
            'b',
            h: 50,
            layoutChild: const ir.LayoutChild(
              horizontalSizing: ir.Sizing.fill,
              verticalSizing: ir.Sizing.fill,
            ),
          ),
        ),
        rect(
          'c',
          common(
            'c',
            h: 50,
            layoutChild: const ir.LayoutChild(
              horizontalSizing: ir.Sizing.fill,
              maxWidth: 100,
            ),
          ),
        ),
      ],
    );
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [row],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    expect(globalRect(tester, 'row'), const Rect.fromLTWH(0, 0, 600, 100));
    expect(globalRect(tester, 'a'), const Rect.fromLTWH(10, 10, 100, 50));
    expect(globalRect(tester, 'b'), const Rect.fromLTWH(120, 10, 360, 80));
    expect(globalRect(tester, 'c'), const Rect.fromLTWH(490, 10, 100, 50));
  });

  testWidgets('a hug frame wraps its text; hidden children take no space', (
    tester,
  ) async {
    final hug = frame(
      'hug',
      common(
        'hug',
        x: 20,
        y: 30,
        layoutChild: const ir.LayoutChild(
          horizontalSizing: ir.Sizing.hug,
          verticalSizing: ir.Sizing.hug,
        ),
      ),
      autoLayout: ir.AutoLayout(
        direction: ir.LayoutDirection.vertical,
        padding: ir.EdgeInsetsValue.all(5),
        gap: const ir.Gap.fixed(4),
      ),
      children: [
        textNode('t', text: 'abcd'),
        rect('hidden', common('hidden', w: 500, h: 500, visible: false)),
      ],
    );
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [hug],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    final t = globalRect(tester, 't');
    expect(t.width, 40); // 4 glyphs × 10 px in the test font
    expect(t.topLeft, const Offset(25, 35));
    expect(globalRect(tester, 'hug'), Rect.fromLTWH(20, 30, 50, t.height + 10));
  });

  testWidgets('a rotated child is placed by its rotated bounding box', (
    tester,
  ) async {
    final row = frame(
      'row',
      common('row'),
      autoLayout: const ir.AutoLayout(),
      children: [
        rect('rot', common('rot', w: 40, h: 20, rotation: 90)),
        rect('next', common('next', w: 10, h: 10)),
      ],
    );
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [row],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    final rot = globalRect(tester, 'rot');
    expect(rot.left, closeTo(0, 1e-6));
    expect(rot.top, closeTo(0, 1e-6));
    expect(rot.width, closeTo(20, 1e-6));
    expect(rot.height, closeTo(40, 1e-6));
    expect(globalRect(tester, 'next').left, closeTo(20, 1e-6));
    expect(stageBox(tester, 'rot').size, const Size(40, 20));
  });

  testWidgets('baseline alignment across nested frames', (tester) async {
    final row = frame(
      'row',
      common('row', x: 10, y: 10),
      autoLayout: const ir.AutoLayout(counterAlign: ir.CounterAlign.baseline),
      children: [
        textNode('small', text: 'Ab', fontSize: 20),
        textNode('big', text: 'Ab', fontSize: 48),
        frame(
          'nested',
          common('nested'),
          autoLayout: const ir.AutoLayout(
            direction: ir.LayoutDirection.vertical,
            padding: ir.EdgeInsetsValue(top: 6),
          ),
          children: [textNode('inner', text: 'Ab', fontSize: 12)],
        ),
        rect('box', common('box', w: 10, h: 10)),
      ],
    );
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [row],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    double baselineOf(String id) {
      final b = stageBox(tester, id) as RenderStageText;
      return globalRect(tester, id).top + b.firstBaseline!;
    }

    final base = baselineOf('big');
    expect(baselineOf('small'), closeTo(base, 1e-6));
    expect(baselineOf('inner'), closeTo(base, 1e-6));
    // A child without text sits its bottom edge on the baseline.
    expect(globalRect(tester, 'box').bottom, closeTo(base, 1e-6));
  });

  testWidgets('a direction flip keeps each axis sizing (T0.4 regression)', (
    tester,
  ) async {
    final row = ir.FrameNode(
      common: const ir.NodeCommon(
        id: 'row',
        width: 300,
        layoutChild: ir.LayoutChild(verticalSizing: ir.Sizing.hug),
        breakpointOverrides: {
          'mobile': {'autoLayout.direction': ir.IrValue.enumValue('vertical')},
        },
      ),
      autoLayout: const ir.AutoLayout(gap: ir.Gap.fixed(10)),
      children: [
        rect('a', common('a', w: 50, h: 20)),
        rect('b', common('b', w: 50, h: 20)),
      ],
    );
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [row],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    expect(globalRect(tester, 'row'), const Rect.fromLTWH(0, 0, 300, 20));
    await pumpScene(tester, docWithRoot(root), viewport: const Size(390, 844));
    // Width stays fixed at 300, height keeps hugging (now 20 + 10 + 20).
    expect(globalRect(tester, 'row'), const Rect.fromLTWH(0, 0, 300, 50));
  });

  testWidgets('hug without auto layout behaves as fixed', (tester) async {
    final f = frame(
      'f',
      common(
        'f',
        w: 120,
        h: 80,
        layoutChild: const ir.LayoutChild(
          horizontalSizing: ir.Sizing.hug,
          verticalSizing: ir.Sizing.hug,
        ),
      ),
    );
    final root = frame('root', common('root', w: 1440, h: 900), children: [f]);
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    expect(globalRect(tester, 'f'), const Rect.fromLTWH(0, 0, 120, 80));
  });

  testWidgets('a breakpoint patch turns the row vertical on mobile', (
    tester,
  ) async {
    final row = ir.FrameNode(
      common: const ir.NodeCommon(
        id: 'row',
        breakpointOverrides: {
          'mobile': {'autoLayout.direction': ir.IrValue.enumValue('vertical')},
        },
      ),
      autoLayout: const ir.AutoLayout(gap: ir.Gap.fixed(10)),
      children: [
        rect('a', common('a', w: 50, h: 20)),
        rect('b', common('b', w: 50, h: 20)),
      ],
    );
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [row],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    expect(globalRect(tester, 'b').topLeft, const Offset(60, 0));
    await pumpScene(tester, docWithRoot(root), viewport: const Size(390, 844));
    expect(globalRect(tester, 'b').topLeft, const Offset(0, 30));
  });

  testWidgets('a flow scene hugs its root vertically at viewport width', (
    tester,
  ) async {
    final root = frame(
      'root',
      common(
        'root',
        w: 1440,
        h: 10,
        layoutChild: const ir.LayoutChild(verticalSizing: ir.Sizing.hug),
      ),
      autoLayout: ir.AutoLayout(
        direction: ir.LayoutDirection.vertical,
        padding: ir.EdgeInsetsValue.all(20),
      ),
      children: [
        rect(
          'wide',
          common(
            'wide',
            h: 100,
            layoutChild: const ir.LayoutChild(horizontalSizing: ir.Sizing.fill),
          ),
        ),
      ],
    );
    await pumpScene(
      tester,
      docWithRoot(root, kind: ir.SceneKind.flow),
      viewport: const Size(800, 600),
    );
    expect(globalRect(tester, 'root'), const Rect.fromLTWH(0, 0, 800, 140));
    expect(globalRect(tester, 'wide'), const Rect.fromLTWH(20, 20, 760, 100));
    final scene = tester.renderObject<RenderStageScene>(
      find.byType(StageSceneBox),
    );
    expect(scene.size, const Size(800, 140));
  });

  testWidgets('absolute children of an auto-layout frame use constraints', (
    tester,
  ) async {
    final row = frame(
      'row',
      common('row', w: 200, h: 100),
      autoLayout: const ir.AutoLayout(
      ),
      children: [
        rect('a', common('a', w: 50, h: 50)),
        rect(
          'badge',
          common(
            'badge',
            x: 180,
            y: 0,
            w: 20,
            h: 20,
            layoutChild: const ir.LayoutChild(
              positioning: ir.Positioning.absolute,
              constraints: ir.Constraints(
                horizontal: ir.HorizontalConstraint.right,
              ),
            ),
          ),
        ),
        rect('b', common('b', w: 50, h: 50)),
      ],
    );
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [row],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    expect(globalRect(tester, 'b').left, 50); // the badge takes no space
    expect(globalRect(tester, 'badge'), const Rect.fromLTWH(180, 0, 20, 20));
  });

  testWidgets('motion is paint-only: layout and siblings are unaffected', (
    tester,
  ) async {
    final row = frame(
      'row',
      common('row'),
      autoLayout: const ir.AutoLayout(),
      children: [
        const ir.ShapeNode(
          common: ir.NodeCommon(
            id: 'moved',
            width: 20,
            height: 20,
            motion: ir.MotionTransform(translateX: 100, scaleX: 2),
          ),
        ),
        rect('next', common('next', w: 10, h: 10)),
      ],
    );
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [row],
    );
    await pumpScene(tester, docWithRoot(root), viewport: const Size(1440, 900));
    expect(globalRect(tester, 'next').left, 20);
    final moved = stageBox(tester, 'moved');
    expect((moved.parentData! as StageParentData).offset, Offset.zero);
    // Scaled ×2 about the centre, then moved 100 px right.
    expect(globalRect(tester, 'moved'), const Rect.fromLTWH(90, 0, 40, 20));
    final hit = tester.hitTestOnBinding(const Offset(125, 10));
    expect(hit.path.any((e) => e.target == moved), isTrue);
  });
}
