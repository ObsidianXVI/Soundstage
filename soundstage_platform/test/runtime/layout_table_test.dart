// The layout test table (architecture §18): one case per §4.4 step and edge
// case, and every §4.3 constraint at a resized parent, against the pure
// layout functions. Rects are exact.
import 'dart:ui';

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

AutoLayoutChild fixed(
  double w,
  double h, {
  StageAxisSizing hz = StageAxisSizing.fixed,
  StageAxisSizing vt = StageAxisSizing.fixed,
  double? minW,
  double? maxW,
  double? minH,
  double? maxH,
  double rotation = 0,
  EdgeInsets strokes = EdgeInsets.zero,
  bool inFlow = true,
  StageBaseline? baseline,
}) => AutoLayoutChild(
  width: w,
  height: h,
  horizontalSizing: hz,
  verticalSizing: vt,
  minWidth: minW,
  maxWidth: maxW,
  minHeight: minH,
  maxHeight: maxH,
  rotation: rotation,
  strokeOutsets: strokes,
  inFlow: inFlow,
  baseline: baseline,
);

/// A text-like child: [chars] glyphs 10 px wide on 20 px lines. Natural
/// width is one line; a given width wraps.
AutoLayoutChild textLike(
  int chars, {
  StageAxisSizing hz = StageAxisSizing.hug,
  StageAxisSizing vt = StageAxisSizing.hug,
  double? minW,
  double? maxW,
}) => AutoLayoutChild(
  width: 0,
  height: 0,
  horizontalSizing: hz,
  verticalSizing: vt,
  minWidth: minW,
  maxWidth: maxW,
  measure: (w, h) {
    final natural = chars * 10.0;
    final width = w ?? natural;
    final perLine = (width / 10).floor().clamp(1, 1 << 20);
    final lines = (chars / perLine).ceil();
    return Size(width, h ?? lines * 20.0);
  },
  baseline: (_) => 15,
);

ir.AutoLayout row({
  ir.Gap gap = const ir.Gap.fixed(),
  ir.Gap counterAxisGap = const ir.Gap.fixed(),
  ir.EdgeInsetsValue padding = ir.EdgeInsetsValue.zero,
  ir.PrimaryAlign primaryAlign = ir.PrimaryAlign.start,
  ir.CounterAlign counterAlign = ir.CounterAlign.start,
  ir.RowAlign rowAlign = ir.RowAlign.start,
  bool wrap = false,
  bool strokes = false,
  bool reverse = false,
  ir.LayoutDirection direction = ir.LayoutDirection.horizontal,
}) => ir.AutoLayout(
  direction: direction,
  gap: gap,
  counterAxisGap: counterAxisGap,
  padding: padding,
  primaryAlign: primaryAlign,
  counterAlign: counterAlign,
  rowAlign: rowAlign,
  wrap: wrap,
  strokesIncludedInLayout: strokes,
  reverseZIndex: reverse,
);

AutoLayoutResult run(
  ir.AutoLayout layout,
  List<AutoLayoutChild> children, {
  double? width,
  double? height,
  double? minWidth,
  double? maxWidth,
  double? minHeight,
  double? maxHeight,
}) => computeAutoLayout(
  layout: layout,
  children: children,
  width: width,
  height: height,
  minWidth: minWidth,
  maxWidth: maxWidth,
  minHeight: minHeight,
  maxHeight: maxHeight,
);

Rect r(double x, double y, double w, double h) => Rect.fromLTWH(x, y, w, h);

void expectRect(Rect? actual, Rect expected) {
  expect(actual, isNotNull);
  const e = 1e-9;
  expect(actual!.left, closeTo(expected.left, e), reason: '$actual');
  expect(actual.top, closeTo(expected.top, e), reason: '$actual');
  expect(actual.width, closeTo(expected.width, e), reason: '$actual');
  expect(actual.height, closeTo(expected.height, e), reason: '$actual');
}

void main() {
  group('§4.4 auto layout', () {
    test('step 1/4: hug sums children, gaps and padding', () {
      final res = run(
        row(
          gap: const ir.Gap.fixed(5),
          padding: const ir.EdgeInsetsValue(
            top: 10,
            right: 10,
            bottom: 10,
            left: 10,
          ),
        ),
        [fixed(20, 10), fixed(30, 20)],
      );
      expect(res.size, const Size(75, 40));
      expectRect(res.boxes[0], r(10, 10, 20, 10));
      expectRect(res.boxes[1], r(35, 10, 30, 20));
    });

    test('step 2: a hug child takes its content size', () {
      final res = run(row(), [textLike(4), fixed(10, 10)]);
      expectRect(res.boxes[0], r(0, 0, 40, 20));
      expectRect(res.boxes[1], r(40, 0, 10, 10));
      expect(res.size, const Size(50, 20));
    });

    test('step 4: fill behaves as hug in a hugging primary axis', () {
      final res = run(row(), [
        textLike(3, hz: StageAxisSizing.fill),
        fixed(10, 10),
      ]);
      expectRect(res.boxes[0], r(0, 0, 30, 20));
      expect(res.size, const Size(40, 20));
    });

    test('step 4: a hugging frame is clamped by its own min/max', () {
      expect(
        run(row(), [fixed(20, 10)], minWidth: 50, maxHeight: 5).size,
        const Size(50, 5),
      );
      expect(run(row(), [fixed(80, 10)], maxWidth: 50).size.width, 50);
    });

    test('step 5: free space splits equally among fill children', () {
      final res = run(
        row(gap: const ir.Gap.fixed(10)),
        [
          fixed(50, 10),
          fixed(0, 10, hz: StageAxisSizing.fill),
          fixed(0, 10, hz: StageAxisSizing.fill),
        ],
        width: 200,
        height: 10,
      );
      expectRect(res.boxes[0], r(0, 0, 50, 10));
      expectRect(res.boxes[1], r(60, 0, 65, 10));
      expectRect(res.boxes[2], r(135, 0, 65, 10));
    });

    test('step 5: a fill child frozen at max redistributes the rest', () {
      final res = run(
        row(),
        [
          fixed(0, 10, hz: StageAxisSizing.fill, maxW: 50),
          fixed(0, 10, hz: StageAxisSizing.fill),
          fixed(0, 10, hz: StageAxisSizing.fill),
        ],
        width: 300,
        height: 10,
      );
      expectRect(res.boxes[0], r(0, 0, 50, 10));
      expectRect(res.boxes[1], r(50, 0, 125, 10));
      expectRect(res.boxes[2], r(175, 0, 125, 10));
    });

    test('step 5: a fill child frozen at min takes from the others', () {
      final res = run(
        row(),
        [
          fixed(0, 10, hz: StageAxisSizing.fill, minW: 80),
          fixed(0, 10, hz: StageAxisSizing.fill),
        ],
        width: 100,
        height: 10,
      );
      expectRect(res.boxes[0], r(0, 0, 80, 10));
      expectRect(res.boxes[1], r(80, 0, 20, 10));
    });

    test('step 5: overflowing fill children shrink to zero, not below', () {
      final res = run(
        row(),
        [fixed(120, 10), fixed(0, 10, hz: StageAxisSizing.fill)],
        width: 100,
        height: 10,
      );
      expectRect(res.boxes[1], r(120, 0, 0, 10));
    });

    test('step 5: a fill text child rewraps at its share', () {
      final res = run(
        row(),
        [fixed(60, 10), textLike(8, hz: StageAxisSizing.fill)],
        width: 100,
      );
      // 40 px share → 4 glyphs a line → 2 lines.
      expectRect(res.boxes[1], r(60, 0, 40, 40));
      expect(res.size, const Size(100, 40));
    });

    test('step 6: gap auto spreads n > 1 children', () {
      final res = run(
        row(gap: const ir.Gap.auto()),
        [fixed(20, 10), fixed(20, 10), fixed(20, 10)],
        width: 100,
        height: 10,
      );
      expectRect(res.boxes[0], r(0, 0, 20, 10));
      expectRect(res.boxes[1], r(40, 0, 20, 10));
      expectRect(res.boxes[2], r(80, 0, 20, 10));
    });

    test('step 6: gap auto with one child sits at the start', () {
      final res = run(
        row(gap: const ir.Gap.auto(), primaryAlign: ir.PrimaryAlign.center),
        [fixed(20, 10)],
        width: 100,
        height: 10,
      );
      expectRect(res.boxes[0], r(0, 0, 20, 10));
    });

    test('negative gaps overlap children', () {
      final res = run(row(gap: const ir.Gap.fixed(-10)), [
        fixed(30, 10),
        fixed(30, 10),
      ]);
      expect(res.size, const Size(50, 10));
      expectRect(res.boxes[1], r(20, 0, 30, 10));
    });

    for (final (align, x) in [
      (ir.PrimaryAlign.start, 0.0),
      (ir.PrimaryAlign.center, 25.0),
      (ir.PrimaryAlign.end, 50.0),
    ]) {
      test('step 7: primaryAlign ${align.name}', () {
        final res = run(
          row(gap: const ir.Gap.fixed(10), primaryAlign: align),
          [fixed(20, 10), fixed(20, 10)],
          width: 100,
          height: 10,
        );
        expectRect(res.boxes[0], r(x, 0, 20, 10));
        expectRect(res.boxes[1], r(x + 30, 0, 20, 10));
      });
    }

    for (final (align, y) in [
      (ir.CounterAlign.start, 0.0),
      (ir.CounterAlign.center, 20.0),
      (ir.CounterAlign.end, 40.0),
    ]) {
      test('step 7: counterAlign ${align.name}', () {
        final res = run(
          row(counterAlign: align),
          [fixed(20, 10)],
          width: 100,
          height: 50,
        );
        expectRect(res.boxes[0], r(0, y, 20, 10));
      });
    }

    test('step 7: baseline aligns first baselines; no text = bottom edge', () {
      final res = run(row(counterAlign: ir.CounterAlign.baseline), [
        fixed(30, 40, baseline: (_) => 30),
        fixed(20, 20, baseline: (_) => 15),
        fixed(10, 10),
      ]);
      expectRect(res.boxes[0], r(0, 0, 30, 40));
      expectRect(res.boxes[1], r(30, 15, 20, 20));
      expectRect(res.boxes[2], r(50, 20, 10, 10));
      expect(res.size, const Size(60, 40));
    });

    test('step 7: baseline across nested frames', () {
      // An inner vertical frame: 8 px top padding above a text whose
      // baseline is 15 → the frame's first baseline is 23.
      final innerLayout = row(
        direction: ir.LayoutDirection.vertical,
        padding: const ir.EdgeInsetsValue(top: 8),
      );
      final innerChildren = [textLike(2)];
      final inner = AutoLayoutChild(
        width: 0,
        height: 0,
        horizontalSizing: StageAxisSizing.hug,
        verticalSizing: StageAxisSizing.hug,
        measure: (w, h) =>
            run(innerLayout, innerChildren, width: w, height: h).size,
        baseline: (size) {
          final l = run(
            innerLayout,
            innerChildren,
            width: size.width,
            height: size.height,
          );
          return firstBaselineOf(innerChildren, l.boxes);
        },
      );
      final res = run(row(counterAlign: ir.CounterAlign.baseline), [
        fixed(10, 50, baseline: (_) => 40),
        inner,
      ]);
      expectRect(res.boxes[1], r(10, 17, 20, 28));
      expect(firstBaselineOf([fixed(10, 50, baseline: (_) => 40), inner], [
        res.boxes[0],
        res.boxes[1],
      ]), 40);
    });

    test('step 3: fill on the counter axis takes the content box', () {
      final res = run(
        row(padding: const ir.EdgeInsetsValue(top: 5, bottom: 5)),
        [fixed(20, 10, vt: StageAxisSizing.fill)],
        width: 100,
        height: 50,
      );
      expectRect(res.boxes[0], r(0, 5, 20, 40));
    });

    test('counter fill in a hugging counter axis stretches to the tallest',
        () {
      final res = run(row(), [
        fixed(20, 30),
        fixed(20, 10, vt: StageAxisSizing.fill),
      ]);
      expectRect(res.boxes[1], r(20, 0, 20, 30));
      expect(res.size, const Size(40, 30));
    });

    test('step 3: min/max clamp a hug child and rewrap it', () {
      final res = run(row(), [textLike(10, maxW: 50)]);
      expectRect(res.boxes[0], r(0, 0, 50, 40));
    });

    test('step 8: wrap breaks rows, stacks them with counterAxisGap', () {
      final res = run(
        row(
          wrap: true,
          gap: const ir.Gap.fixed(10),
          counterAxisGap: const ir.Gap.fixed(5),
        ),
        [fixed(40, 10), fixed(40, 20), fixed(40, 10)],
        width: 100,
      );
      expectRect(res.boxes[0], r(0, 0, 40, 10));
      expectRect(res.boxes[1], r(50, 0, 40, 20));
      expectRect(res.boxes[2], r(0, 25, 40, 10));
      expect(res.size, const Size(100, 35));
    });

    test('step 8: rows align within the row; the block by rowAlign', () {
      final res = run(
        row(
          wrap: true,
          gap: const ir.Gap.fixed(10),
          counterAxisGap: const ir.Gap.fixed(5),
          counterAlign: ir.CounterAlign.end,
          rowAlign: ir.RowAlign.center,
        ),
        [fixed(40, 10), fixed(40, 20), fixed(40, 10)],
        width: 100,
        height: 55,
      );
      // Block = 20 + 5 + 10 = 35 → 10 above it.
      expectRect(res.boxes[0], r(0, 20, 40, 10));
      expectRect(res.boxes[1], r(50, 10, 40, 20));
      expectRect(res.boxes[2], r(0, 35, 40, 10));
    });

    test('step 8: counterAxisGap auto spreads rows', () {
      final res = run(
        row(wrap: true, counterAxisGap: const ir.Gap.auto()),
        [fixed(60, 10), fixed(60, 20)],
        width: 100,
        height: 55,
      );
      expectRect(res.boxes[0], r(0, 0, 60, 10));
      expectRect(res.boxes[1], r(0, 35, 60, 20));
    });

    test('step 8: fill children in a wrapped row split that row', () {
      final res = run(
        row(wrap: true, gap: const ir.Gap.fixed(10)),
        [
          fixed(60, 10),
          fixed(0, 10, hz: StageAxisSizing.fill, minW: 50),
          fixed(0, 10, hz: StageAxisSizing.fill),
        ],
        width: 100,
      );
      // 60 + 10 + 50 > 100 → the min-width fill wraps; it and the last fill
      // share row 2: (100 − 10) / 2 = 45 < 50 → frozen at 50, other gets 40.
      expectRect(res.boxes[0], r(0, 0, 60, 10));
      expectRect(res.boxes[1], r(0, 10, 50, 10));
      expectRect(res.boxes[2], r(60, 10, 40, 10));
    });

    test('wrap is ignored in a hugging primary axis', () {
      final res = run(row(wrap: true), [fixed(60, 10), fixed(60, 10)]);
      expect(res.size, const Size(120, 10));
    });

    test('strokesIncludedInLayout inflates by the outside strokes', () {
      final res = run(
        row(strokes: true, gap: const ir.Gap.fixed(10)),
        [
          fixed(20, 20, strokes: const EdgeInsets.all(2)),
          fixed(20, 20),
        ],
      );
      expectRect(res.boxes[0], r(2, 2, 20, 20));
      expectRect(res.boxes[1], r(34, 0, 20, 20));
      expect(res.size, const Size(54, 24));
      // Without the flag strokes take no space.
      final off = run(
        row(gap: const ir.Gap.fixed(10)),
        [fixed(20, 20, strokes: const EdgeInsets.all(2)), fixed(20, 20)],
      );
      expectRect(off.boxes[1], r(30, 0, 20, 20));
    });

    test('rotated children use their rotated bounding box', () {
      final res = run(row(), [fixed(40, 20, rotation: 90), fixed(10, 10)]);
      // Footprint 20 × 40; the 40 × 20 box is centred in it.
      expectRect(res.boxes[0], r(-10, 10, 40, 20));
      expectRect(res.boxes[1], r(20, 0, 10, 10));
      expect(res.size.width, closeTo(30, 1e-9));
      expect(res.size.height, closeTo(40, 1e-9));
      final diag = run(row(), [fixed(10, 10, rotation: 45)]);
      expect(diag.size.width, closeTo(14.142135623730951, 1e-9));
    });

    test('step 1: hidden and absolute children are skipped', () {
      final res = run(row(gap: const ir.Gap.fixed(10)), [
        fixed(20, 10),
        fixed(500, 500, inFlow: false),
        fixed(20, 10),
      ]);
      expect(res.boxes[1], isNull);
      expectRect(res.boxes[2], r(30, 0, 20, 10));
      expect(res.size, const Size(50, 10));
    });

    test('step 10: paint order is child order unless reverseZIndex', () {
      final children = [fixed(1, 1), fixed(1, 1), fixed(1, 1)];
      expect(run(row(), children).paintOrder, [0, 1, 2]);
      expect(run(row(reverse: true), children).paintOrder, [2, 1, 0]);
    });

    test('vertical layouts are the transpose', () {
      final res = run(
        row(
          direction: ir.LayoutDirection.vertical,
          gap: const ir.Gap.fixed(4),
          padding: const ir.EdgeInsetsValue(top: 1, left: 2),
          counterAlign: ir.CounterAlign.end,
        ),
        [fixed(10, 20), fixed(30, 5)],
      );
      expect(res.size, const Size(32, 30));
      expectRect(res.boxes[0], r(22, 1, 10, 20));
      expectRect(res.boxes[1], r(2, 25, 30, 5));
    });

    test('vertical fill splits height; counter fill takes the width', () {
      final res = run(
        row(direction: ir.LayoutDirection.vertical),
        [
          fixed(10, 0, vt: StageAxisSizing.fill, hz: StageAxisSizing.fill),
          fixed(10, 30),
        ],
        width: 50,
        height: 100,
      );
      expectRect(res.boxes[0], r(0, 0, 50, 70));
      expectRect(res.boxes[1], r(0, 70, 10, 30));
    });
  });

  group('§4.3 constraints at a resized parent (R = 100, P = 200)', () {
    AxisPlacement place(
      AxisConstraint c, {
      double? min,
      double? max,
      double? content,
    }) => resolveAxisConstraint(
      constraint: c,
      position: 10,
      size: 30,
      reference: 100,
      parent: 200,
      min: min,
      max: max,
      contentSize: content,
    );

    test('left/top keeps position and size', () {
      expect(place(AxisConstraint.start), (offset: 10.0, size: 30.0));
    });
    test('right/bottom keeps the far margin', () {
      expect(place(AxisConstraint.end), (offset: 110.0, size: 30.0));
    });
    test('leftRight/topBottom keeps both margins', () {
      expect(place(AxisConstraint.stretch), (offset: 10.0, size: 130.0));
    });
    test('center keeps the centre offset', () {
      expect(place(AxisConstraint.center), (offset: 60.0, size: 30.0));
    });
    test('scale scales position and size', () {
      expect(place(AxisConstraint.scale), (offset: 20.0, size: 60.0));
    });
    test('min/max clamp, anchored by the constraint', () {
      expect(place(AxisConstraint.stretch, max: 100), (
        offset: 10.0,
        size: 100.0,
      ));
      expect(place(AxisConstraint.end, min: 50), (offset: 90.0, size: 50.0));
      expect(place(AxisConstraint.center, max: 20), (
        offset: 65.0,
        size: 20.0,
      ));
      expect(place(AxisConstraint.scale, max: 40), (offset: 20.0, size: 40.0));
    });
    test('a hugging child keeps its margins at its content size', () {
      expect(place(AxisConstraint.end, content: 50), (
        offset: 90.0,
        size: 50.0,
      ));
      expect(place(AxisConstraint.center, content: 50), (
        offset: 50.0,
        size: 50.0,
      ));
      // Stretch and scale decide the size themselves.
      expect(place(AxisConstraint.stretch, content: 50).size, 130);
    });
    test('a shrunk parent', () {
      final p = resolveAxisConstraint(
        constraint: AxisConstraint.end,
        position: 60,
        size: 30,
        reference: 100,
        parent: 50,
      );
      expect(p, (offset: 10.0, size: 30.0));
    });
    test('both axes, every vertical constraint', () {
      for (final (v, rect) in [
        (ir.VerticalConstraint.top, r(10, 20, 30, 40)),
        (ir.VerticalConstraint.bottom, r(10, 120, 30, 40)),
        (ir.VerticalConstraint.topBottom, r(10, 20, 30, 140)),
        (ir.VerticalConstraint.center, r(10, 70, 30, 40)),
        (ir.VerticalConstraint.scale, r(10, 40, 30, 80)),
      ]) {
        final got = resolveConstraints(
          constraints: ir.Constraints(vertical: v),
          stored: r(10, 20, 30, 40),
          referenceWidth: 100,
          referenceHeight: 100,
          parentWidth: 300,
          parentHeight: 200,
        );
        expect(got, rect, reason: v.name);
      }
    });
  });
}
