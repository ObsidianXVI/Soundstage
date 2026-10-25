import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'interaction_harness.dart';

const _stops = [
  ir.ColorStop(position: 0, color: ir.StageColor.black),
  ir.ColorStop(position: 0.5, color: ir.StageColor(r: 1, g: 0, b: 0)),
  ir.ColorStop(position: 1, color: ir.StageColor.white),
];

/// 'a' (desktop 100,100 100×100) with a radial fill 'g' centred, its end
/// at the right edge: on screen (pan 40,60) start (190,210), end (240,210).
ir.StageDocument gradientDoc() => ir
    .updateNode(
      interactionDoc(),
      'a',
      (n) => ir.PropertyRegistry.standard.trySet(
        n,
        'fills',
        const ir.IrValue.paints([
          ir.Paint.gradient(
            id: 'g',
            kind: ir.GradientKind.radial,
            stops: _stops,
            handles: ir.GradientHandles(
              start: ir.StagePoint(x: 0.5, y: 0.5),
              end: ir.StagePoint(x: 1, y: 0.5),
            ),
          ),
        ]),
      )!,
    )
    .document;

ir.GradientPaint _paint(Harness h) =>
    (h.node('a') as ir.ShapeNode).appearance.fills.single as ir.GradientPaint;

Future<Harness> _editing(WidgetTester tester) async {
  final h = await pumpCanvas(tester, doc: gradientDoc());
  h.ctl.select({'a'});
  h.canvas.gradientEdit.value = const GradientEditTarget('a', 'fills', 'g');
  await tester.pump();
  return h;
}

void main() {
  testWidgets('dragging the end handle writes normalised handles, one undo '
      'step', (tester) async {
    final h = await _editing(tester);
    final depth = h.ctl.history.undoDepth;
    await h.drag(h.desk(200, 150), h.desk(150, 100));
    final g = _paint(h);
    expect(g.handles.end, const ir.StagePoint(x: 0.5, y: 0));
    expect(g.handles.start, const ir.StagePoint(x: 0.5, y: 0.5));
    expect(h.ctl.history.undoDepth, depth + 1);
    expect(h.st.selection, {'a'}, reason: 'the drag did not select');
    h.ctl.undo();
    expect(_paint(h).handles.end, const ir.StagePoint(x: 1, y: 0.5));
  });

  testWidgets('the centre moves the whole gradient; the width handle sets '
      'the second axis', (tester) async {
    final h = await _editing(tester);
    await h.drag(h.desk(150, 150), h.desk(140, 130));
    var g = _paint(h);
    expect(g.handles.start, const ir.StagePoint(x: 0.4, y: 0.3));
    expect(g.handles.end, const ir.StagePoint(x: 0.9, y: 0.3));
    // Width handle (derived): 50 px clockwise from the axis → (140, 180).
    await h.drag(h.desk(140, 180), h.desk(160, 160));
    g = _paint(h);
    expect(g.handles.width, const ir.StagePoint(x: 0.4, y: 0.6));
  });

  testWidgets('Shift snaps the axis angle to 15°', (tester) async {
    final h = await _editing(tester);
    await h.withKeys([LogicalKeyboardKey.shiftLeft], () async {
      await h.drag(h.desk(200, 150), h.desk(190, 178));
    });
    final g = _paint(h);
    final dx = (g.handles.end.x - g.handles.start.x) * 100;
    final dy = (g.handles.end.y - g.handles.start.y) * 100;
    final deg = math.atan2(dy, dx) * 180 / math.pi;
    expect((deg / 15 - (deg / 15).roundToDouble()).abs(), lessThan(1e-3));
    expect(deg, closeTo(30, 1e-3));
  });

  testWidgets('stops drag along the line; Alt-click on the line adds one', (
    tester,
  ) async {
    final h = await _editing(tester);
    await h.drag(h.desk(175, 150), h.desk(190, 158));
    expect(_paint(h).stops[1].position, 0.8);
    final depth = h.ctl.history.undoDepth;
    await h.withKeys([LogicalKeyboardKey.altLeft], () async {
      await h.click(h.desk(160, 150));
    });
    final stops = _paint(h).stops;
    expect(stops.map((s) => s.position), [0, 0.2, 0.8, 1]);
    expect(h.ctl.history.undoDepth, depth + 1);
    expect(h.st.selection, {'a'});
  });

  testWidgets('Esc leaves gradient editing and keeps the selection; so does '
      'selecting another layer', (tester) async {
    final h = await _editing(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(h.canvas.gradientEdit.value, isNull);
    expect(h.st.selection, {'a'});

    h.canvas.gradientEdit.value = const GradientEditTarget('a', 'fills', 'g');
    h.ctl.select({'b'});
    await tester.pump();
    expect(h.canvas.gradientEdit.value, isNull);
  });

  testWidgets('with This breakpoint, a handle drag writes a patch', (
    tester,
  ) async {
    final h = await _editing(tester);
    h.ctl.setEditScope(EditScope.thisBreakpoint);
    await h.drag(h.desk(200, 150), h.desk(150, 100));
    expect(_paint(h).handles.end, const ir.StagePoint(x: 1, y: 0.5));
    final patch = h.node('a').common.breakpointOverrides['desktop']!;
    expect(patch.keys, ['fills.g.handles.end']);
  });

  testWidgets('B5: a handle at a frame corner beats the rotate and resize '
      'zones', (tester) async {
    final h = await pumpCanvas(
      tester,
      doc: ir
          .updateNode(
            interactionDoc(),
            'a',
            (n) => ir.PropertyRegistry.standard.trySet(
              n,
              'fills',
              const ir.IrValue.paints([
                ir.Paint.gradient(
                  id: 'g',
                  kind: ir.GradientKind.radial,
                  stops: _stops,
                  handles: ir.GradientHandles(
                    start: ir.StagePoint(x: 0.5, y: 0.5),
                    end: ir.StagePoint(x: 1, y: 1),
                  ),
                ),
              ]),
            )!,
          )
          .document,
    );
    h.ctl.select({'a'});
    h.canvas.gradientEdit.value = const GradientEditTarget('a', 'fills', 'g');
    await tester.pump();
    final rotation = h.node('a').common.rotation;
    // 10 px outside the corner: inside the rotate zone, off the handle dot.
    await h.drag(h.desk(210, 200), h.desk(180, 160));
    expect(h.node('a').common.rotation, rotation, reason: 'did not rotate');
    final g = _paint(h);
    expect(g.handles.end.x, lessThan(1), reason: 'the end handle moved');
    expect(g.handles.start, const ir.StagePoint(x: 0.5, y: 0.5));
  });
}
