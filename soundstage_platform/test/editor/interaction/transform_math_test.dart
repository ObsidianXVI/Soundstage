import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/interaction/geometry_writes.dart';
import 'package:soundstage_platform/editor/interaction/transform_math.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

Matcher _rect(Rect r, [double eps = 1e-9]) => isA<Rect>()
    .having((p) => p.left, 'left', closeTo(r.left, eps))
    .having((p) => p.top, 'top', closeTo(r.top, eps))
    .having((p) => p.width, 'width', closeTo(r.width, eps))
    .having((p) => p.height, 'height', closeTo(r.height, eps));

void main() {
  const box = Rect.fromLTWH(100, 100, 200, 100);

  group('resizeBox', () {
    // Every handle, plain: the opposite side stays.
    final plain = {
      ResizeHandle.topLeft: const Rect.fromLTRB(110, 120, 300, 200),
      ResizeHandle.top: const Rect.fromLTRB(100, 120, 300, 200),
      ResizeHandle.topRight: const Rect.fromLTRB(100, 120, 310, 200),
      ResizeHandle.right: const Rect.fromLTRB(100, 100, 310, 200),
      ResizeHandle.bottomRight: const Rect.fromLTRB(100, 100, 310, 220),
      ResizeHandle.bottom: const Rect.fromLTRB(100, 100, 300, 220),
      ResizeHandle.bottomLeft: const Rect.fromLTRB(110, 100, 300, 220),
      ResizeHandle.left: const Rect.fromLTRB(110, 100, 300, 200),
    };
    for (final MapEntry(key: h, value: want) in plain.entries) {
      test('$h by (10, 20)', () {
        final r = resizeBox(box: box, handle: h, delta: const Offset(10, 20));
        expect(r.box, _rect(want));
        expect(r.widthChanged, h.hx != 0);
        expect(r.heightChanged, h.hy != 0);
      });
    }

    for (final h in ResizeHandle.values) {
      test('$h from the centre (Alt) keeps the centre', () {
        final r = resizeBox(
          box: box,
          handle: h,
          delta: const Offset(10, 20),
          fromCenter: true,
        );
        expect(r.box.center.dx, closeTo(box.center.dx, 1e-9));
        expect(r.box.center.dy, closeTo(box.center.dy, 1e-9));
        expect(r.box.width, box.width + (h.hx == 0 ? 0 : 20 * h.hx));
        expect(r.box.height, box.height + (h.hy == 0 ? 0 : 40 * h.hy));
      });

      test('$h keeping the aspect ratio (Shift)', () {
        final r = resizeBox(
          box: box,
          handle: h,
          delta: const Offset(40, 10),
          keepAspect: true,
        );
        expect(r.box.width / r.box.height, closeTo(2, 1e-9));
      });
    }

    test('Shift on a corner follows the axis that changed most', () {
      final r = resizeBox(
        box: box,
        handle: ResizeHandle.bottomRight,
        delta: const Offset(10, 50),
        keepAspect: true,
      );
      expect(r.box, _rect(const Rect.fromLTWH(100, 100, 300, 150)));
    });

    test('Shift on an edge scales the other axis about the centre', () {
      final r = resizeBox(
        box: box,
        handle: ResizeHandle.right,
        delta: const Offset(100, 0),
        keepAspect: true,
      );
      expect(r.box, _rect(const Rect.fromLTRB(100, 75, 400, 225)));
    });

    test('min/max clamp; the anchor stays; no flipping through zero', () {
      var r = resizeBox(
        box: box,
        handle: ResizeHandle.left,
        delta: const Offset(-300, 0),
        maxWidth: 250,
      );
      expect(r.box, _rect(const Rect.fromLTRB(50, 100, 300, 200)));
      r = resizeBox(
        box: box,
        handle: ResizeHandle.right,
        delta: const Offset(-500, 0),
      );
      expect(r.box, _rect(const Rect.fromLTRB(100, 100, 101, 200)));
      r = resizeBox(
        box: box,
        handle: ResizeHandle.bottom,
        delta: const Offset(0, -80),
        minHeight: 40,
      );
      expect(r.box.height, 40);
      expect(r.box.top, 100);
    });

    test('Shift with a clamped axis keeps the ratio', () {
      final r = resizeBox(
        box: box,
        handle: ResizeHandle.bottomRight,
        delta: const Offset(200, 0),
        keepAspect: true,
        maxHeight: 150,
      );
      expect(r.box, _rect(const Rect.fromLTWH(100, 100, 300, 150)));
    });

    test('a rotated box resizes in its own frame; the opposite edge stays', () {
      // 90°: local +x points down on screen.
      final r = resizeBox(
        box: const Rect.fromLTWH(450, 250, 100, 50),
        handle: ResizeHandle.right,
        delta: const Offset(0, 20),
        rotation: 90,
      );
      expect(r.box, _rect(const Rect.fromLTWH(440, 260, 120, 50)));
      // The local left edge (top on screen) stays: centre − w/2 along +y.
      final top = r.box.center.dy - r.box.width / 2;
      expect(top, closeTo(225, 1e-9));
    });

    test('a 30° rotation: the anchor corner stays on screen', () {
      const b = Rect.fromLTWH(0, 0, 100, 60);
      Offset corner(Rect r, double deg, int hx, int hy) => rotateAbout(
        r.center + Offset(hx * r.width / 2, hy * r.height / 2),
        r.center,
        deg,
      );
      final r = resizeBox(
        box: b,
        handle: ResizeHandle.bottomRight,
        delta: rotateVector(const Offset(30, 10), 30),
        rotation: 30,
      );
      expect(r.box.width, closeTo(130, 1e-9));
      expect(r.box.height, closeTo(70, 1e-9));
      final before = corner(b, 30, -1, -1), after = corner(r.box, 30, -1, -1);
      expect((after - before).distance, closeTo(0, 1e-9));
    });
  });

  test('mapRectProportionally scales within the union', () {
    expect(
      mapRectProportionally(
        const Rect.fromLTWH(400, 100, 100, 100),
        const Rect.fromLTWH(100, 100, 400, 100),
        const Rect.fromLTWH(100, 100, 800, 200),
      ),
      _rect(const Rect.fromLTWH(700, 100, 200, 200)),
    );
  });

  group('rotation', () {
    test('drag about the centre; Shift snaps to 15°', () {
      const c = Offset(150, 150);
      expect(
        dragRotation(
          centre: c,
          start: const Offset(210, 90),
          now: const Offset(210, 210),
          startRotation: 0,
        ),
        closeTo(90, 1e-9),
      );
      final free = dragRotation(
        centre: c,
        start: const Offset(210, 90),
        now: const Offset(215, 200),
        startRotation: 10,
      );
      expect(free % 15, isNot(0));
      final snapped = dragRotation(
        centre: c,
        start: const Offset(210, 90),
        now: const Offset(215, 200),
        startRotation: 10,
        snap: true,
      );
      expect(snapped % 15, 0);
      expect((snapped - free).abs(), lessThanOrEqualTo(7.5));
    });

    test('normalised to (−180, 180]', () {
      expect(normalizeDegrees(190), -170);
      expect(normalizeDegrees(-180), 180);
      expect(normalizeDegrees(720), 0);
    });

    test('resize cursors snap to 45°', () {
      expect(resizeCursorAngle(0), 0);
      expect(resizeCursorAngle(180), 0);
      expect(resizeCursorAngle(-45), 135);
      expect(resizeCursorAngle(50), 45);
      expect(resizeCursorAngle(95), 90);
    });
  });

  group('flowSlot (insertion index)', () {
    // Horizontal: three 100-wide children with 10 gaps after 10 padding;
    // child 1 is being dragged (indices count it as still there).
    final kids = <FlowSibling>[
      (index: 0, box: const Rect.fromLTWH(10, 10, 100, 100)),
      (index: 2, box: const Rect.fromLTWH(230, 10, 100, 100)),
      (index: 3, box: const Rect.fromLTWH(340, 10, 100, 100)),
    ];
    const content = Rect.fromLTRB(10, 10, 440, 110);
    int at(double x) => flowSlot(
      siblings: kids,
      pointer: Offset(x, 50),
      horizontal: true,
      content: content,
      childCount: 4,
    ).index;

    test('before the first sibling whose midpoint is past the pointer', () {
      expect(at(0), 0);
      expect(at(59), 0);
      expect(at(61), 2);
      expect(at(279), 2);
      expect(at(281), 3);
      expect(at(389), 3);
      expect(at(391), 4);
    });

    test('the indicator sits between neighbours', () {
      final s = flowSlot(
        siblings: kids,
        pointer: const Offset(300, 50),
        horizontal: true,
        content: content,
        childCount: 4,
      );
      expect(s.a, const Offset(335, 10));
      expect(s.b, const Offset(335, 110));
    });

    test('vertical, and an empty frame', () {
      final v = flowSlot(
        siblings: [
          (index: 0, box: const Rect.fromLTWH(0, 0, 50, 40)),
          (index: 1, box: const Rect.fromLTWH(0, 50, 50, 40)),
        ],
        pointer: const Offset(10, 60),
        horizontal: false,
        content: const Rect.fromLTWH(0, 0, 50, 90),
        childCount: 2,
      );
      expect(v.index, 1);
      expect(v.a.dy, 45);
      final e = flowSlot(
        siblings: const [],
        pointer: Offset.zero,
        horizontal: true,
        content: content,
        childCount: 1,
      );
      expect(e.index, 1);
      expect(e.a, content.topLeft);
    });

    test('wrap: the row under the pointer', () {
      final rows = <FlowSibling>[
        (index: 0, box: const Rect.fromLTWH(0, 0, 100, 40)),
        (index: 1, box: const Rect.fromLTWH(110, 0, 100, 40)),
        (index: 2, box: const Rect.fromLTWH(0, 50, 100, 40)),
        (index: 3, box: const Rect.fromLTWH(110, 50, 100, 40)),
      ];
      int at(Offset p) => flowSlot(
        siblings: rows,
        pointer: p,
        horizontal: true,
        wrap: true,
        content: const Rect.fromLTWH(0, 0, 210, 90),
        childCount: 4,
      ).index;
      expect(at(const Offset(200, 20)), 2); // end of row 1
      expect(at(const Offset(20, 70)), 2); // start of row 2
      expect(at(const Offset(150, 70)), 3);
      expect(at(const Offset(200, 70)), 4);
    });
  });

  group('geometryWrites (inverse constraints)', () {
    // A parent designed at 1000 wide, shown at 1200 (free width).
    Placement place(
      ir.HorizontalConstraint hc, {
      double x = 100,
      double w = 100,
    }) {
      final node = ir.ShapeNode(
        common: ir.NodeCommon(
          id: 'n',
          x: x,
          width: w,
          height: 50,
          layoutChild: ir.LayoutChild(
            constraints: ir.Constraints(horizontal: hc),
          ),
        ),
      );
      final p = ir.resolveAxisConstraint(
        constraint: ir.horizontalAxisConstraint(hc),
        position: x,
        size: w,
        reference: 1000,
        parent: 1200,
      );
      return Placement(
        id: 'n',
        node: node,
        box: Rect.fromLTWH(p.offset, 0, p.size, 50),
        parentSize: const Size(1200, 800),
        reference: const Size(1000, 800),
      );
    }

    for (final hc in ir.HorizontalConstraint.values) {
      test('$hc: a move and a resize at a free width round-trip', () {
        final p = place(hc);
        final target = p.box.shift(const Offset(30, 0));
        final moved = geometryWrites(p, target, moveX: true);
        final x = (moved['x']! as ir.NumberValue).value;
        var back = ir.resolveAxisConstraint(
          constraint: ir.horizontalAxisConstraint(hc),
          position: x,
          size: 100,
          reference: 1000,
          parent: 1200,
        );
        expect(back.offset, closeTo(target.left, 0.01));
        // At the design size the node moved by the same design amount.
        final atDesign = ir.resolveAxisConstraint(
          constraint: ir.horizontalAxisConstraint(hc),
          position: x,
          size: 100,
          reference: 1000,
          parent: 1000,
        );
        final k = hc == ir.HorizontalConstraint.scale ? 1000 / 1200 : 1.0;
        expect(atDesign.offset, closeTo(100 + 30 * k, 0.01));

        final grown = Rect.fromLTWH(p.box.left, 0, p.box.width + 40, 50);
        final sized = geometryWrites(p, grown, sizeX: true);
        back = ir.resolveAxisConstraint(
          constraint: ir.horizontalAxisConstraint(hc),
          position: (sized['x']! as ir.NumberValue).value,
          size: (sized['width']! as ir.NumberValue).value,
          reference: 1000,
          parent: 1200,
        );
        expect(back.offset, closeTo(grown.left, 0.01));
        expect(back.size, closeTo(grown.width, 0.01));
      });
    }

    test('in-flow children write sizes only; hug/fill become fixed', () {
      final p = const Placement(
        id: 'n',
        node: ir.ShapeNode(
          common: ir.NodeCommon(
            id: 'n',
            width: 100,
            height: 50,
            layoutChild: ir.LayoutChild(
              horizontalSizing: ir.Sizing.fill,
              verticalSizing: ir.Sizing.hug,
            ),
          ),
        ),
        box: Rect.fromLTWH(10, 10, 100, 50),
        parentSize: Size(300, 100),
        reference: Size(300, 100),
        inFlow: true,
      );
      final w = geometryWrites(
        p,
        const Rect.fromLTWH(10, 10, 140, 50),
        moveX: true,
        sizeX: true,
      );
      expect(w, {
        'layoutChild.horizontalSizing': const ir.IrValue.enumValue('fixed'),
        'width': const ir.IrValue.number(140),
      });
    });

    test('text auto-resize: width → height mode; height → fixed', () {
      Placement text(ir.TextAutoResize mode) => Placement(
        id: 't',
        node: ir.TextNode(
          common: const ir.NodeCommon(id: 't', width: 10, height: 10),
          autoResize: mode,
        ),
        box: const Rect.fromLTWH(0, 0, 80, 20),
        parentSize: const Size(500, 500),
        reference: const Size(500, 500),
        hugsWidth: mode == ir.TextAutoResize.widthAndHeight,
        hugsHeight: mode != ir.TextAutoResize.fixed,
      );
      var w = geometryWrites(
        text(ir.TextAutoResize.widthAndHeight),
        const Rect.fromLTWH(0, 0, 120, 20),
        sizeX: true,
      );
      expect(w['autoResize'], const ir.IrValue.enumValue('height'));
      expect(w['width'], const ir.IrValue.number(120));
      expect(w.containsKey('height'), isFalse);
      w = geometryWrites(
        text(ir.TextAutoResize.widthAndHeight),
        const Rect.fromLTWH(0, 0, 80, 40),
        sizeY: true,
      );
      expect(w['autoResize'], const ir.IrValue.enumValue('fixed'));
      expect(w['width'], const ir.IrValue.number(80));
      expect(w['height'], const ir.IrValue.number(40));
      w = geometryWrites(
        text(ir.TextAutoResize.fixed),
        const Rect.fromLTWH(0, 0, 90, 20),
        sizeX: true,
      );
      expect(w.containsKey('autoResize'), isFalse);
    });

    test('geometry is rounded to 1/100 px', () {
      expect(roundGeometry(10.004), 10);
      expect(roundGeometry(10.005), closeTo(10.01, 1e-12));
      expect(roundGeometry(-0.001), 0);
    });
  });
}
