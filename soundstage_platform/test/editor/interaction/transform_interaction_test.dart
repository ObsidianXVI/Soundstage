import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/overlay/interaction_model.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'interaction_harness.dart';

(double, double) _xy(Harness h, String id) => (h.common(id).x, h.common(id).y);
(double, double) _wh(Harness h, String id) =>
    (h.common(id).width, h.common(id).height);
List<String> _kids(Harness h, String id) => [
  for (final c in (h.node(id) as ir.FrameNode).children) c.id,
];
String? _parent(Harness h, String id) =>
    ir.DocumentIndex.of(h.doc).locate(id)!.parentId;

void main() {
  group('move', () {
    testWidgets('an absolute node moves; one undo step per drag', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      final depth = h.ctl.history.undoDepth;
      await h.drag(h.desk(150, 150), h.desk(203, 127), steps: 6);
      expect(h.st.selection, {'a'});
      expect(_xy(h, 'a'), (153.0, 77.0));
      expect(h.ctl.history.undoDepth, depth + 1);
      expect(h.st.history.undoLabel, 'Move layer');
      h.ctl.undo();
      await tester.pump();
      expect(_xy(h, 'a'), (100.0, 100.0));
    });

    testWidgets('a drag back to the start leaves no undo entry', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      final depth = h.ctl.history.undoDepth;
      final g = await h.press(h.desk(150, 150));
      await g.moveTo(h.desk(180, 180));
      await tester.pump();
      await g.moveTo(h.desk(150, 150));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect(_xy(h, 'a'), (100.0, 100.0));
      expect(h.ctl.history.undoDepth, depth);
    });

    testWidgets('Esc cancels a drag', (tester) async {
      final h = await pumpCanvas(tester);
      final g = await h.press(h.desk(150, 150));
      await g.moveTo(h.desk(260, 250));
      await tester.pump();
      expect(_xy(h, 'a'), isNot((100.0, 100.0)));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(_xy(h, 'a'), (100.0, 100.0));
      await g.up();
      await tester.pump();
      expect(_xy(h, 'a'), (100.0, 100.0));
      expect(h.st.selection, {'a'});
    });

    testWidgets('Shift locks the axis', (tester) async {
      final h = await pumpCanvas(tester);
      await h.withKeys([LogicalKeyboardKey.shiftLeft], () async {
        // Select first (a Shift-click would toggle).
        h.ctl.select({'a'});
        await h.drag(h.desk(150, 150), h.desk(230, 171));
      });
      expect(_xy(h, 'a'), (180.0, 100.0));
    });

    testWidgets('at a free width the move writes through inverse constraints '
        '(round trip at the design size)', (tester) async {
      final h = await pumpCanvas(
        tester,
        camera: const CanvasCamera(zoom: 0.5, panX: 40, panY: 60),
      );
      h.canvas.setPreviewWidth('desktop', 1200, designWidth: 1000);
      await tester.pump();
      // Right-anchored: at 1200 wide it sits 200 px further right.
      expect(
        h.worldRect('pinR'),
        rectNear(const Rect.fromLTWH(1050, 650, 100, 50)),
      );
      await h.drag(h.desk(1100, 675), h.desk(1120, 675));
      expect(
        h.worldRect('pinR'),
        rectNear(const Rect.fromLTWH(1070, 650, 100, 50)),
      );
      // Stored geometry means the same at the design size: 20 px right.
      expect(_xy(h, 'pinR'), (870.0, 650.0));
      h.canvas.resetPreviewWidth('desktop');
      await tester.pump();
      expect(
        h.worldRect('pinR'),
        rectNear(const Rect.fromLTWH(870, 650, 100, 50)),
      );
    });

    testWidgets('scope routing during a drag: the toolbar scope, never Alt', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl
        ..setEditScope(EditScope.thisBreakpoint)
        ..setScopeFlipped(true); // Alt was held (the shell's flip)
      // Resize with Alt (from centre) on the mobile artboard.
      h.ctl.select({'a'});
      await tester.pump();
      await h.withKeys([LogicalKeyboardKey.altLeft], () async {
        await h.drag(h.mob(200, 150), h.mob(210, 150));
      });
      final c = h.common('a');
      expect(c.width, 100, reason: 'the base is untouched');
      expect(
        c.breakpointOverrides['mobile']!['width'],
        const ir.IrValue.number(120),
      );
      expect(
        c.breakpointOverrides['mobile']!['x'],
        const ir.IrValue.number(90),
      );
    });
  });

  group('auto layout', () {
    testWidgets('dragging an in-flow child reorders with an insertion '
        'indicator, applied on drop', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'i1'});
      await tester.pump();
      final g = await h.press(h.desk(160, 460));
      await g.moveTo(h.desk(300, 460));
      await tester.pump();
      await g.moveTo(h.desk(420, 460));
      await tester.pump();
      final m = h.canvas.interaction;
      expect(m.gesture, CanvasGestureKind.reorder);
      expect(m.insertion, isNotNull);
      // After i3 (its right edge).
      expect(m.insertion!.$1.dx, closeTo(100 + 330, 1e-6));
      expect(m.ghosts, hasLength(1));
      expect(_kids(h, 'row'), ['i1', 'i2', 'i3'], reason: 'not until drop');
      await g.up();
      await tester.pump();
      expect(_kids(h, 'row'), ['i2', 'i3', 'i1']);
      expect(m.insertion, isNull);
      h.ctl.undo();
      expect(_kids(h, 'row'), ['i1', 'i2', 'i3']);
    });

    testWidgets('over a sibling frame inside the auto-layout parent: still a '
        'reorder, not a reparent', (tester) async {
      final h = await pumpCanvas(
        tester,
        doc: interactionDoc().copyWith(
          scenes: [
            for (final s in interactionDoc().scenes)
              s.copyWith(
                root: s.root.copyWith(
                  children: [
                    for (final c in s.root.children)
                      if (c.id == 'row')
                        (c as ir.FrameNode).copyWith(
                          children: [
                            ...c.children.take(2),
                            const ir.FrameNode(
                              common: ir.NodeCommon(
                                id: 'i3',
                                width: 100,
                                height: 100,
                              ),
                            ),
                          ],
                        )
                      else
                        c,
                  ],
                ),
              ),
          ],
        ),
      );
      h.ctl.select({'i1'});
      await tester.pump();
      await h.drag(h.desk(160, 460), h.desk(400, 460));
      expect(_parent(h, 'i1'), 'row');
      expect(_kids(h, 'row'), ['i2', 'i3', 'i1']);
    });

    testWidgets('a node dragged into an auto-layout frame joins the flow at '
        'the slot', (tester) async {
      final h = await pumpCanvas(tester);
      await h.drag(h.desk(150, 150), h.desk(220, 450));
      expect(_parent(h, 'a'), 'row');
      expect(_kids(h, 'row'), ['i1', 'a', 'i2', 'i3']);
    });

    testWidgets('arrows reorder in auto layout (along its direction only)', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'i1'});
      h.ctl.perform(const NudgeIntent(1, 0));
      expect(_kids(h, 'row'), ['i2', 'i1', 'i3']);
      h.ctl.perform(const NudgeIntent(10, 0)); // Shift: still one place
      expect(_kids(h, 'row'), ['i2', 'i3', 'i1']);
      h.ctl.perform(const NudgeIntent(1, 0)); // at the end
      expect(_kids(h, 'row'), ['i2', 'i3', 'i1']);
      h.ctl.perform(const NudgeIntent(0, 1)); // across: nothing
      expect(_kids(h, 'row'), ['i2', 'i3', 'i1']);
      h.ctl.perform(const NudgeIntent(-1, 0));
      expect(_kids(h, 'row'), ['i2', 'i1', 'i3']);
      expect(h.st.history.undoLabel, 'Reorder layer');
      // An absolute node nudges.
      h.ctl.select({'a'});
      h.ctl.perform(const NudgeIntent(10, 0));
      expect(_xy(h, 'a'), (110.0, 100.0));
    });
  });

  group('reparent', () {
    testWidgets('into a free frame (live), keeping the visual position', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      final g = await h.press(h.desk(150, 150));
      await g.moveTo(h.desk(400, 300));
      await tester.pump();
      await g.moveTo(h.desk(700, 450));
      await tester.pump();
      expect(_parent(h, 'a'), 'box');
      expect(h.canvas.interaction.dropTargetId, 'box');
      await g.up();
      await tester.pump();
      expect(_parent(h, 'a'), 'box');
      expect(_xy(h, 'a'), (50.0, 0.0));
      expect(
        h.worldRect('a'),
        rectNear(const Rect.fromLTWH(650, 400, 100, 100)),
      );
      h.ctl.undo();
      expect(_parent(h, 'a'), 'root');
      expect(_xy(h, 'a'), (100.0, 100.0));
    });

    testWidgets('out of a frame onto the scene root', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'inner'});
      await tester.pump();
      await h.drag(h.desk(645, 445), h.desk(310, 300));
      expect(_parent(h, 'inner'), 'root');
      expect(_xy(h, 'inner'), (285.0, 275.0));
    });

    testWidgets('Cmd/Ctrl: no reparenting (and no snapping)', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'a'});
      await h.withKeys([LogicalKeyboardKey.metaLeft], () async {
        await h.drag(h.desk(150, 150), h.desk(700, 450));
      });
      expect(_parent(h, 'a'), 'root');
      expect(_xy(h, 'a'), (650.0, 400.0));
    });

    testWidgets('Alt-drag duplicates: the copy moves, one undo removes it', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'a'});
      final before = _kids(h, 'root').length;
      await h.withKeys([LogicalKeyboardKey.altLeft], () async {
        await h.drag(h.desk(150, 150), h.desk(150, 260));
      });
      final kids = _kids(h, 'root');
      expect(kids.length, before + 1);
      final copy = h.st.selection.single;
      expect(copy, isNot('a'));
      expect(_xy(h, 'a'), (100.0, 100.0));
      expect(_xy(h, copy), (100.0, 210.0));
      expect(kids.indexOf(copy), kids.indexOf('a') + 1);
      h.ctl.undo();
      expect(_kids(h, 'root').length, before);
      expect(h.st.selection, {'a'});
    });
  });

  group('resize', () {
    testWidgets('corner handle; Shift keeps the ratio; Alt from the centre', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'a'});
      await tester.pump();
      await h.drag(h.desk(200, 200), h.desk(250, 212));
      expect(_wh(h, 'a'), (150.0, 112.0));
      expect(h.st.history.undoLabel, 'Resize');
      h.ctl.undo();
      await tester.pump();
      await h.withKeys([LogicalKeyboardKey.shiftLeft], () async {
        await h.drag(h.desk(200, 200), h.desk(250, 210));
      });
      expect(_wh(h, 'a'), (150.0, 150.0));
      h.ctl.undo();
      await tester.pump();
      await h.withKeys([LogicalKeyboardKey.altLeft], () async {
        await h.drag(h.desk(200, 150), h.desk(220, 150));
      });
      expect(_wh(h, 'a'), (140.0, 100.0));
      expect(_xy(h, 'a'), (80.0, 100.0));
    });

    testWidgets('top-left handle moves the origin; edges resize one axis', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'a'});
      await tester.pump();
      await h.drag(h.desk(100, 100), h.desk(80, 70));
      expect(_xy(h, 'a'), (80.0, 70.0));
      expect(_wh(h, 'a'), (120.0, 130.0));
      await h.drag(h.desk(140, 200), h.desk(140, 240));
      expect(_wh(h, 'a'), (120.0, 170.0));
      expect(_xy(h, 'a'), (80.0, 70.0));
    });

    testWidgets('respects max width', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'b'});
      await tester.pump();
      await h.drag(h.desk(500, 150), h.desk(600, 150));
      expect(h.common('b').width, 120);
    });

    testWidgets('a hugging axis becomes fixed', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.execute(
        SetProperty(
          ['row'],
          'layoutChild.horizontalSizing',
          const ir.IrValue.enumValue('hug'),
        ),
      );
      h.ctl.select({'row'});
      await tester.pump();
      await h.drag(h.desk(440, 460), h.desk(500, 460));
      final c = h.common('row');
      expect(c.layoutChild.horizontalSizing, ir.Sizing.fixed);
      expect(c.width, 400);
    });

    testWidgets('a fill child becomes fixed; only its size is written', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.execute(
        SetProperty(
          ['i3'],
          'layoutChild.horizontalSizing',
          const ir.IrValue.enumValue('fill'),
        ),
      );
      h.ctl.select({'i3'});
      await tester.pump();
      final w0 = h.worldRect('i3')!;
      await h.drag(h.desk(w0.right, 460), h.desk(w0.right - 20, 460));
      final c = h.common('i3');
      expect(c.layoutChild.horizontalSizing, ir.Sizing.fixed);
      expect(c.width, closeTo(w0.width - 20, 1e-6));
      expect((c.x, c.y), (0.0, 0.0));
    });

    testWidgets('text: a width drag makes auto-width text wrap', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'txt'});
      await tester.pump();
      final r = h.worldRect('txt')!;
      await h.drag(
        h.desk(r.right, r.center.dy),
        h.desk(r.right + 40, r.center.dy),
      );
      final t = h.node('txt') as ir.TextNode;
      expect(t.autoResize, ir.TextAutoResize.height);
      expect(t.common.width, closeTo(r.width + 40, 1e-6));
    });

    testWidgets('text: a height drag makes it fixed at its current width', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'txt'});
      await tester.pump();
      final r = h.worldRect('txt')!;
      await h.drag(
        h.desk(r.center.dx, r.bottom),
        h.desk(r.center.dx, r.bottom + 20),
      );
      final t = h.node('txt') as ir.TextNode;
      expect(t.autoResize, ir.TextAutoResize.fixed);
      expect(t.common.width, closeTo(r.width, 1e-6));
      expect(t.common.height, closeTo(r.height + 20, 1e-6));
    });

    testWidgets('a rotated node resizes in its own frame', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'rot'});
      await tester.pump();
      // Rotated 90°: its local right edge is at the bottom on screen.
      await h.drag(h.desk(500, 325), h.desk(500, 345));
      expect(_wh(h, 'rot'), (120.0, 50.0));
      expect(_xy(h, 'rot'), (440.0, 260.0));
      expect(
        h.worldRect('rot'),
        rectNear(const Rect.fromLTWH(475, 225, 50, 120)),
      );
    });

    testWidgets('a multi-selection scales proportionally', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'a', 'b'});
      await tester.pump();
      await h.withKeys([LogicalKeyboardKey.metaLeft], () async {
        await h.drag(h.desk(500, 150), h.desk(900, 150));
      });
      expect((_xy(h, 'a'), _wh(h, 'a')), ((100.0, 100.0), (200.0, 100.0)));
      // b's own max width (120) clamps it.
      expect(_xy(h, 'b'), (700.0, 100.0));
    });
  });

  group('rotate', () {
    testWidgets('outside a corner; Shift snaps to 15°', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'a'});
      await tester.pump();
      await h.drag(h.desk(210, 90), h.desk(210, 210));
      expect(h.common('a').rotation, closeTo(90, 1e-6));
      expect(h.st.history.undoLabel, 'Rotate');
      h.ctl.undo();
      await tester.pump();
      await h.drag(h.desk(210, 90), h.desk(215, 205));
      final free = h.common('a').rotation;
      expect(free, isNot(closeTo(90, 0.5)));
      h.ctl.undo();
      await tester.pump();
      await h.withKeys([LogicalKeyboardKey.shiftLeft], () async {
        await h.drag(h.desk(210, 90), h.desk(215, 205));
      });
      expect(h.common('a').rotation, 90);
    });

    testWidgets('the cursor over a rotation zone is painted by the overlay', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'a'});
      await tester.pump();
      final g = await h.hoverAt(h.desk(210, 90));
      expect(h.canvas.interaction.rotateCursor, isNotNull);
      await g.moveTo(h.desk(150, 150));
      await tester.pump();
      expect(h.canvas.interaction.rotateCursor, isNull);
      await g.removePointer();
    });
  });
}
