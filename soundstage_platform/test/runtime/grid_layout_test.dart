import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/src/render/layout/auto_layout.dart';
import 'package:soundstage_platform/runtime/src/render/layout/grid_layout.dart';

GridLayoutChild _item(
  double w,
  double h, {
  int? column,
  int? row,
  int columnSpan = 1,
  int rowSpan = 1,
  ir.GridAlign alignX = ir.GridAlign.start,
  ir.GridAlign alignY = ir.GridAlign.start,
  bool inFlow = true,
}) => GridLayoutChild(
  AutoLayoutChild(width: w, height: h, inFlow: inFlow),
  ir.GridPlacement(
    column: column,
    row: row,
    columnSpan: columnSpan,
    rowSpan: rowSpan,
    alignX: alignX,
    alignY: alignY,
  ),
);

const _flex3 = [ir.GridTrack.flex(), ir.GridTrack.flex(), ir.GridTrack.flex()];

void main() {
  test('flex columns share the width; rows hug; auto-placement wraps', () {
    final r = computeGridLayout(
      layout: const ir.GridLayout(columns: _flex3, columnGap: 10, rowGap: 5),
      children: [for (var i = 0; i < 5; i++) _item(50, 40)],
      width: 320,
    );
    expect(r.boxes[0], const Rect.fromLTWH(0, 0, 50, 40));
    expect(r.boxes[1], const Rect.fromLTWH(110, 0, 50, 40));
    expect(r.boxes[2], const Rect.fromLTWH(220, 0, 50, 40));
    expect(r.boxes[3], const Rect.fromLTWH(0, 45, 50, 40));
    expect(r.size, const Size(320, 85));
  });

  test('fixed, hug and flex tracks; padding', () {
    final r = computeGridLayout(
      layout: const ir.GridLayout(
        columns: [
          ir.GridTrack.fixed(60),
          ir.GridTrack.hug(),
          ir.GridTrack.flex(2),
          ir.GridTrack.flex(),
        ],
        padding: ir.EdgeInsetsValue(left: 10, right: 10, top: 4, bottom: 4),
      ),
      children: [
        _item(20, 10),
        _item(80, 10),
        _item(20, 10, alignX: ir.GridAlign.stretch),
        _item(20, 10, alignX: ir.GridAlign.stretch),
      ],
      width: 380,
    );
    // 360 inner: 60 fixed, 80 hug, 220 left → 146.67 / 73.33.
    expect(r.boxes[1]!.left, 70);
    expect(r.boxes[2]!.left, 150);
    expect(r.boxes[2]!.width, closeTo(146.67, 0.01));
    expect(r.boxes[3]!.width, closeTo(73.33, 0.01));
    expect(r.boxes[0]!.top, 4);
    expect(r.size.height, 18);
  });

  test('explicit cells and spans; auto items fill around them', () {
    final r = computeGridLayout(
      layout: const ir.GridLayout(
        columns: [
          ir.GridTrack.fixed(100),
          ir.GridTrack.fixed(100),
          ir.GridTrack.fixed(100),
        ],
        rows: [ir.GridTrack.fixed(50), ir.GridTrack.fixed(50)],
      ),
      children: [
        _item(10, 10),
        _item(
          10,
          10,
          column: 1,
          row: 0,
          columnSpan: 2,
          alignX: ir.GridAlign.stretch,
          alignY: ir.GridAlign.stretch,
        ),
        _item(10, 10),
        _item(10, 10, row: 1),
      ],
      width: 300,
    );
    expect(r.boxes[1], const Rect.fromLTWH(100, 0, 200, 50));
    // Row 1 is taken by the row-only item first (pass 2), so the auto
    // items go to (0,0) and (1,1).
    expect(r.boxes[3]!.topLeft, const Offset(0, 50));
    expect(r.boxes[0]!.topLeft, Offset.zero);
    expect(r.boxes[2]!.topLeft, const Offset(100, 50));
  });

  test('column flow fills down the rows first and adds columns', () {
    final r = computeGridLayout(
      layout: const ir.GridLayout(
        rows: [ir.GridTrack.fixed(30), ir.GridTrack.fixed(30)],
        columns: [ir.GridTrack.fixed(40)],
        autoFlow: ir.GridAutoFlow.column,
      ),
      children: [for (var i = 0; i < 3; i++) _item(20, 20)],
    );
    expect(r.boxes[1]!.topLeft, const Offset(0, 30));
    expect(r.boxes[2]!.topLeft, const Offset(40, 0));
    // The implicit column hugs its item.
    expect(r.size, const Size(60, 60));
  });

  test('alignment in the cell; hidden items are not placed', () {
    final r = computeGridLayout(
      layout: const ir.GridLayout(
        columns: [ir.GridTrack.fixed(100)],
        rows: [ir.GridTrack.fixed(100)],
      ),
      children: [
        _item(20, 10, inFlow: false),
        _item(20, 10, alignX: ir.GridAlign.center, alignY: ir.GridAlign.end),
      ],
    );
    expect(r.boxes[0], isNull);
    expect(r.boxes[1], const Rect.fromLTWH(40, 90, 20, 10));
  });

  test('a hugging grid sizes flex tracks like hug', () {
    final r = computeGridLayout(
      layout: const ir.GridLayout(columns: _flex3, columnGap: 4),
      children: [_item(10, 5), _item(30, 5), _item(20, 5)],
    );
    expect(r.size, const Size(68, 5));
  });
}
