import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/overlay/interaction_model.dart';

import 'interaction_harness.dart';

void main() {
  group('hover', () {
    testWidgets('mouse moves hover the topmost node in context', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      final g = await h.hoverAt(h.desk(150, 150));
      expect(h.st.hoverId, 'a');
      // Over an auto-layout child: the frame is what a click would select.
      await g.moveTo(h.desk(150, 450));
      await tester.pump();
      expect(h.st.hoverId, 'row');
      // Inside the frame's context, the child.
      h.ctl.select({'i1'});
      await g.moveTo(h.desk(270, 450));
      await tester.pump();
      expect(h.st.hoverId, 'i2');
      // The same node hovers on the mirrored artboard.
      await g.moveTo(h.mob(150, 150));
      await tester.pump();
      expect(h.st.hoverId, isNotNull);
      await g.moveTo(h.desk(950, 50));
      await tester.pump();
      expect(h.st.hoverId, isNull);
      await g.removePointer();
    });
  });

  group('click selection', () {
    testWidgets('click, Shift-click, Cmd-click, empty click', (tester) async {
      final h = await pumpCanvas(tester);
      await h.click(h.desk(150, 150));
      expect(h.st.selection, {'a'});
      await h.withKeys([LogicalKeyboardKey.shiftLeft], () async {
        await h.click(h.desk(450, 150));
      });
      expect(h.st.selection, {'a', 'b'});
      await h.withKeys([LogicalKeyboardKey.shiftLeft], () async {
        await h.click(h.desk(150, 150));
      });
      expect(h.st.selection, {'b'});
      await h.click(h.desk(150, 450));
      expect(h.st.selection, {'row'});
      await h.withKeys([LogicalKeyboardKey.metaLeft], () async {
        await h.click(h.desk(150, 450));
      });
      expect(h.st.selection, {'i1'});
      expect(h.st.selectionContext, 'row');
      await h.click(h.desk(950, 50));
      expect(h.st.selection, isEmpty);
    });

    testWidgets('double-click enters a frame; on text requests editing', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      await h.doubleClick(h.desk(150, 450));
      expect(h.st.selection, {'i1'});
      expect(h.st.selectionContext, 'row');
      final requests = <TextEditRequest>[];
      final sub = h.ctl.events.textEditRequests.listen(requests.add);
      addTearDown(sub.cancel);
      await h.doubleClick(h.mob(105, 655));
      expect(h.st.textEditId, 'txt');
      expect(requests, [(nodeId: 'txt', breakpointId: 'mobile')]);
    });

    testWidgets('clicking either artboard selects everywhere and makes it the '
        'edited artboard', (tester) async {
      final h = await pumpCanvas(tester);
      expect(h.st.breakpointId, 'desktop');
      await h.click(h.mob(150, 150));
      expect(h.st.selection, {'a'});
      expect(h.st.breakpointId, 'mobile');
      // Mirrored: the node is laid out on both artboards.
      expect(h.worldRect('a', 'desktop'), isNotNull);
      expect(h.worldRect('a', 'mobile'), isNotNull);
      await h.click(h.desk(450, 150));
      expect(h.st.breakpointId, 'desktop');
      expect(h.st.selection, {'b'});
    });

    testWidgets('locked nodes are clicked through', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.execute(const SetLocked(['a'], true));
      await tester.pump();
      await h.click(h.desk(150, 150));
      expect(h.st.selection, isEmpty);
    });
  });

  group('marquee', () {
    testWidgets('from empty canvas selects the boxes fully inside, live', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      final g = await h.press(h.desk(50, 50));
      await g.moveTo(h.desk(300, 300));
      await tester.pump();
      expect(h.st.selection, {'a'});
      expect(h.canvas.interaction.marquee, isNotNull);
      expect(h.canvas.interaction.gesture, CanvasGestureKind.marquee);
      await g.moveTo(h.desk(520, 220));
      await tester.pump();
      expect(h.st.selection, {'a', 'b'});
      await g.moveTo(h.desk(300, 300));
      await tester.pump();
      expect(h.st.selection, {'a'});
      await g.up();
      await tester.pump();
      expect(h.canvas.interaction.marquee, isNull);
      expect(h.st.selection, {'a'});
    });

    testWidgets('Shift adds to the selection', (tester) async {
      final h = await pumpCanvas(tester);
      h.ctl.select({'c'});
      await h.withKeys([LogicalKeyboardKey.shiftLeft], () async {
        await h.drag(h.desk(50, 50), h.desk(300, 300));
      });
      expect(h.st.selection, {'c', 'a'});
    });

    testWidgets('a marquee outside the artboards picks the nearest one', (
      tester,
    ) async {
      final h = await pumpCanvas(
        tester,
        camera: const CanvasCamera(zoom: 0.5, panX: 200, panY: 200),
      );
      await h.drag(h.desk(50, -100), h.desk(250, 250));
      expect(h.st.selection, {'a'});
    });
  });

  group('keys and rename', () {
    testWidgets('Cmd+R asks the Layers panel to rename the selection', (
      tester,
    ) async {
      final h = await pumpCanvas(tester);
      final ids = <String>[];
      final sub = h.ctl.events.renameRequests.listen(ids.add);
      addTearDown(sub.cancel);
      h.ctl.select({'b'});
      h.ctl.perform(const RenameSelectionIntent());
      expect(ids, ['b']);
      unawaited(sub.cancel());
    });
  });
}
