import 'package:flutter/material.dart' hide Easing;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/shell/editor_layout.dart';
import 'package:soundstage_platform/editor/timeline/timeline_panel.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'timeline_harness.dart';

// Rows on the scroll clock: 0 group a1, 1 Opacity (op), 2 group b1, 3 X (bx).
const _op = 1, _bx = 3;

void main() {
  testWidgets('lanes: groups by node, labels from the registry', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    expect(find.byKey(const ValueKey('timeline-group:a1')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-group:b1')), findsOneWidget);
    expect(find.text('Opacity'), findsOneWidget);
    expect(find.text('X'), findsOneWidget);
    // The timeline clock's track is not on this clock's lanes.
    expect(find.text('Width'), findsNothing);
    // A breakpoint-specific track names its breakpoint.
    r.ctl.execute(
      UpdateTrack('s1', 'bx', (t) => t.copyWith(breakpoints: ['mobile'])),
    );
    await tester.pump();
    expect(find.text('X · Mobile'), findsOneWidget);
  });

  testWidgets(
    'scrub: dragging the ruler moves the playhead, not the document',
    (tester) async {
      final r = await pumpTimeline(tester);
      final doc = r.st.document;
      await r.drag(r.onRuler(0.1), r.onRuler(0.6));
      expect(r.st.playhead, closeTo(0.6, 0.002));
      expect(identical(r.st.document, doc), isTrue);
      expect(r.st.history.canUndo, isFalse);
      expect(find.text('60%'), findsWidgets); // readout
      // Dragging the playhead line in the lanes scrubs too.
      await r.drag(
        r.at(0, 0.6) + const Offset(0, 40),
        r.at(0, 0.3) + const Offset(0, 40),
      );
      expect(r.st.playhead, closeTo(0.3, 0.002));
      // The ruler clamps to the clock's span.
      await r.drag(r.onRuler(0.3), r.onRuler(1.4));
      expect(r.st.playhead, 1);
    },
  );

  testWidgets('Cmd/Ctrl+wheel zooms about the pointer; the wheel pans', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    final before = r.view;
    final anchor = r.at(_op, 0.5);
    await r.holding(LogicalKeyboardKey.controlLeft, () async {
      await r.wheel(anchor, const Offset(0, -200));
    });
    expect(r.view.pxPerUnit, greaterThan(before.pxPerUnit * 2));
    expect(r.view.tOf(anchor.dx - r.lanesTopLeft.dx), closeTo(0.5, 1e-6));
    final zoomed = r.view;
    // Horizontal wheel pans time; vertical wheel over the ruler too.
    await r.wheel(anchor, const Offset(100, 0));
    expect(r.view.start, greaterThan(zoomed.start));
    expect(r.view.pxPerUnit, zoomed.pxPerUnit);
    final panned = r.view;
    await r.wheel(r.onRuler(0.5), const Offset(0, -50));
    expect(r.view.start, lessThan(panned.start));
  });

  testWidgets('click and Shift-click select keyframes; a lane click selects '
      'its node', (tester) async {
    final r = await pumpTimeline(tester);
    await r.click(r.at(_op, 1));
    expect(r.selection, {(track: 'op', keyframe: 'o1')});
    expect(r.st.selection, {'a1'});
    await r.holding(LogicalKeyboardKey.shiftLeft, () async {
      await r.click(r.at(_bx, 0.25));
    });
    expect(r.selection, {
      (track: 'op', keyframe: 'o1'),
      (track: 'bx', keyframe: 'x0'),
    });
    // Shift-click again removes it.
    await r.holding(LogicalKeyboardKey.shiftLeft, () async {
      await r.click(r.at(_op, 1) + const Offset(1, 0));
    });
    expect(r.selection, {(track: 'bx', keyframe: 'x0')});
    // A click on an empty part of a lane selects the node, clears keyframes.
    await r.click(r.at(_op, 0.6));
    expect(r.selection, isEmpty);
    expect(r.st.selection, {'a1'});
    // So does the label.
    await tester.tap(find.byKey(const ValueKey('timeline-label:bx')));
    await tester.pump();
    expect(r.st.selection, {'b1'});
  });

  testWidgets('box-select over rows and times; Shift adds', (tester) async {
    final r = await pumpTimeline(tester);
    // From above o0's row at 0.1 down past bx at 0.4: o0 is left of it,
    // so only x0 (0.25) is inside.
    await r.drag(r.at(_op, 0.1) - const Offset(0, 8), r.at(_bx, 0.4));
    expect(r.selection, {(track: 'bx', keyframe: 'x0')});
    // A wider box catches o0 too; Shift keeps x0.
    await r.holding(LogicalKeyboardKey.shiftLeft, () async {
      await r.drag(r.at(0, 0.7), r.at(_bx, 1) + const Offset(8, 0));
    });
    expect(r.selection, {
      (track: 'bx', keyframe: 'x0'),
      (track: 'op', keyframe: 'o1'),
      (track: 'bx', keyframe: 'x1'),
    });
  });

  testWidgets('drag snaps to the playhead and is one undo step; Shift does '
      'not snap', (tester) async {
    final r = await pumpTimeline(tester);
    r.ctl.setActivePlayhead(0.5);
    await tester.pump();
    final before = r.st.document;
    // x0 (0.25) dragged to 3 px left of the playhead: snaps onto it.
    final target = r.at(_bx, 0.5) - const Offset(3, 0);
    await r.drag(r.at(_bx, 0.25), target, steps: 8);
    expect(r.times('bx'), [0.5, 0.75]);
    expect(r.st.history.undoLabel, 'Move keyframe');
    r.ctl.undo();
    await tester.pump();
    expect(identical(r.st.document, before), isTrue);
    // Snaps to another keyframe (o1 at 1.0 is out of range: x1 to 0.75 is
    // itself; use o0 at 0): x0 dragged near 0.
    await r.drag(r.at(_bx, 0.25), r.at(_bx, 0) + const Offset(4, 0));
    expect(r.times('bx').first, 0);
    r.ctl.undo();
    await tester.pump();
    // With Shift held, the keyframe lands where the pointer is.
    await r.holding(LogicalKeyboardKey.shiftLeft, () async {
      await r.drag(r.at(_bx, 0.25), target, steps: 8);
    });
    final t = r.times('bx').first;
    expect(t, isNot(0.5));
    expect(t, closeTo(0.5 - 3 / r.view.pxPerUnit, 0.002));
  });

  testWidgets('dragging a selection moves every selected keyframe', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    r.tl.select({(track: 'bx', keyframe: 'x0'), (track: 'bx', keyframe: 'x1')});
    await r.holding(LogicalKeyboardKey.shiftLeft, () async {
      // Shift: no snapping, and a selected keyframe stays selected.
      await r.drag(r.at(_bx, 0.75), r.at(_bx, 0.85));
    });
    expect(r.times('bx')[0], closeTo(0.35, 0.002));
    expect(r.times('bx')[1], closeTo(0.85, 0.002));
    expect(r.ctl.history.undoLabel, 'Move 2 keyframes');
  });

  testWidgets('Alt-drag duplicates; the copies become the selection', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    await r.holding(LogicalKeyboardKey.altLeft, () async {
      await r.drag(r.at(_bx, 0.75), r.at(_bx, 0.9));
    });
    final kfs = r.track('bx').keyframes;
    expect(kfs, hasLength(3));
    expect(kfs[1].id, 'x1');
    expect(kfs[1].t, 0.75);
    expect(kfs[2].t, closeTo(0.9, 0.002));
    expect(kfs[2].value, const IrValue.number(100));
    expect(r.selection, {(track: 'bx', keyframe: kfs[2].id)});
    expect(r.st.history.undoLabel, 'Duplicate keyframe');
    r.ctl.undo();
    expect(r.track('bx').keyframes, hasLength(2));
  });

  testWidgets('Delete removes selected keyframes (and an emptied track)', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    await r.click(r.at(_bx, 0.25));
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(r.times('bx'), [0.75]);
    expect(r.selection, isEmpty);
    await r.click(r.at(_bx, 0.75));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(r.scene.tracks.any((t) => t.id == 'bx'), isFalse);
    expect(find.byKey(const ValueKey('timeline-label:bx')), findsNothing);
    // The node itself was not deleted.
    expect(DocumentIndex.of(r.st.document).contains('b1'), isTrue);
  });

  testWidgets('Cmd/Ctrl+C / V paste at the playhead, keeping relative times', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    await r.click(r.at(_bx, 0.25));
    await r.holding(LogicalKeyboardKey.shiftLeft, () async {
      await r.click(r.at(_bx, 0.75));
    });
    await r.holding(LogicalKeyboardKey.controlLeft, () async {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    });
    r.ctl.setActivePlayhead(0.1);
    await tester.pump();
    await r.holding(LogicalKeyboardKey.controlLeft, () async {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    });
    await tester.pump();
    final kfs = r.track('bx').keyframes;
    expect(
      [for (final k in kfs) k.t],
      [closeTo(0.1, 1e-9), 0.25, closeTo(0.6, 1e-9), 0.75],
    );
    expect(kfs[0].value, const IrValue.number(0));
    expect(kfs[2].value, const IrValue.number(100));
    expect(r.selection, {
      (track: 'bx', keyframe: kfs[0].id),
      (track: 'bx', keyframe: kfs[2].id),
    });
    expect(r.st.history.undoLabel, 'Paste 2 keyframes');
    // The document's node clipboard was not used: no node was pasted.
    expect(
      r.scene.root.children.length,
      timelineDoc().scenes.first.root.children.length,
    );
  });

  testWidgets('arrow keys nudge selected keyframes (Shift ×10)', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    await r.click(r.at(_bx, 0.25));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(r.times('bx').first, closeTo(0.26, 1e-9));
    await r.holding(LogicalKeyboardKey.shiftLeft, () async {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    });
    await tester.pump();
    expect(r.times('bx').first, closeTo(0.16, 1e-9));
    // Nudges did not move the node on the canvas (no NudgeNodes).
    expect(DocumentIndex.of(r.st.document).node('b1')!.common.x, 1);
    expect(r.st.history.undoLabel, 'Nudge keyframe');
  });

  testWidgets('Escape and an outside click hand the keys back', (tester) async {
    final r = await pumpTimeline(tester);
    await r.click(r.at(_bx, 0.25));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(r.selection, isEmpty);
    await r.click(r.at(_bx, 0.25));
    // A click outside the timeline (the toolbar title) unfocuses it: Delete
    // then goes to the editor (the node selection), not the keyframes.
    await tester.tap(find.byKey(const ValueKey('toolbar-title')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(r.times('bx'), [0.25, 0.75]);
  });

  testWidgets('double-clicking a segment opens the easing hook', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    r.ctl.execute(
      const SetSegmentEasing('s1', {
        'bx': {'x0'},
      }, Easing.preset(EasingPreset.easeInOut)),
    );
    await tester.pump();
    await r.click(r.at(_bx, 0.5));
    await r.click(r.at(_bx, 0.5));
    expect(r.tl.easingSegment.value, (track: 'bx', keyframe: 'x0'));
    await tester.pump();
    expect(find.byKey(const ValueKey('easing-hook')), findsOneWidget);
    expect(find.byKey(const ValueKey('easing-editor')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('easing-hook')),
        matching: find.text('Ease in out'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.bySemanticsLabel('Close easing editor'));
    await tester.pump();
    expect(find.byKey(const ValueKey('easing-hook')), findsNothing);
    expect(find.byKey(const ValueKey('easing-editor')), findsNothing);
  });

  testWidgets('groups collapse; canvas selection reveals and highlights a '
      'group', (tester) async {
    final extra = [
      for (var i = 0; i < 40; i++)
        Track(
          id: 'e$i',
          target: 'a1',
          property: i.isEven ? 'motion.translateX' : 'motion.translateY',
          clockId: 'clk1',
          breakpoints: [if (i % 4 < 2) 'desktop' else 'mobile'],
          keyframes: [kf('k$i', i / 40, i.toDouble())],
        ),
    ];
    final r = await pumpTimeline(tester, doc: timelineDoc(extra: extra));
    // b1's group sits below 40+ lanes, out of view.
    expect(find.byKey(const ValueKey('timeline-group:b1')), findsNothing);
    r.ctl.select({'b1'});
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline-group:b1')), findsOneWidget);
    // Collapsing a1's group hides its lanes.
    tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('timeline-rows')),
            matching: find.byType(Scrollable),
          ),
        )
        .position
        .jumpTo(0);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('timeline-toggle:a1')));
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-label:op')), findsNothing);
    expect(find.byKey(const ValueKey('timeline-label:bx')), findsOneWidget);
  });

  testWidgets('transport plays timeline clocks in real time, loops, and '
      'Space toggles it', (tester) async {
    final r = await pumpTimeline(tester);
    // Scene scroll: transport is off (play and Space do nothing).
    await tester.tap(find.byKey(const ValueKey('timeline-play')));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 100));
    expect(r.tl.playing.value, isFalse);
    expect(r.st.playhead, 0);
    r.ctl.setActiveClock('s1', 'tl');
    await tester.pump();
    expect(find.text('Width'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('timeline-play')));
    await tester.pump();
    expect(r.tl.playing.value, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(r.st.playhead, closeTo(1, 0.05));
    // Space pauses (no text input focused).
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(r.tl.playing.value, isFalse);
    final paused = r.st.playhead;
    await tester.pump(const Duration(milliseconds: 300));
    expect(r.st.playhead, paused);
    // Without loop it stops at the end; with loop it wraps.
    r.ctl.setActivePlayhead(3.8);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(r.st.playhead, 4);
    expect(r.tl.playing.value, isFalse);
    await tester.tap(find.byKey(const ValueKey('timeline-loop')));
    await tester.pump();
    expect(r.tl.loopsOn(r.scene.clocks.last), isTrue);
    // A focused button takes Space itself (it would toggle loop again), so
    // move the focus off it, as a click on the canvas does.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    r.ctl.setActivePlayhead(3.8);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(r.st.playhead, closeTo(0.3, 0.05));
    expect(r.tl.playing.value, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
  });

  testWidgets('auto-key: the toolbar toggle tints the timeline red and edits '
      'create tracks', (tester) async {
    final r = await pumpTimeline(tester);
    expect(find.byKey(const ValueKey('timeline-autokey-tint')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toolbar-autokey')));
    await tester.pump();
    expect(r.st.autoKey, isTrue);
    expect(find.byKey(const ValueKey('timeline-autokey-tint')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-autokey')), findsOneWidget);
    // An edit at the playhead creates a track and its lane.
    r.ctl.setActivePlayhead(0.5);
    r.ctl.execute(SetProperty(['b1'], 'y', const IrValue.number(40)));
    await tester.pump();
    expect(find.text('Y'), findsOneWidget);
    final y = r.scene.tracks.singleWhere((t) => t.property == 'y');
    expect(y.keyframes.map((k) => k.t), [0.0, 0.5]);
    await tester.tap(find.byKey(const ValueKey('toolbar-autokey')));
    await tester.pump();
    expect(find.byKey(const ValueKey('timeline-autokey-tint')), findsNothing);
  });

  testWidgets('the top edge resizes; height and open state persist', (
    tester,
  ) async {
    final r = await pumpTimeline(tester);
    final h0 = tester.getSize(find.byKey(const ValueKey('timeline'))).height;
    await tester.drag(
      find.byKey(const ValueKey('timeline-resize')),
      const Offset(0, -100),
    );
    await tester.pump();
    final h1 = tester.getSize(find.byKey(const ValueKey('timeline'))).height;
    // (The drag's first pixels are its slop.)
    expect(h1, greaterThan(h0 + 60));
    expect(r.root.read(editorLayoutProvider).timelineHeight, closeTo(h1, 1));
    await tester.tap(find.bySemanticsLabel('Collapse timeline'));
    await tester.pump();
    expect(r.root.read(editorLayoutProvider).timelineOpen, isFalse);
    expect(
      tester.getSize(find.byKey(const ValueKey('timeline'))).height,
      kTimelineHeaderHeight + 1,
    );
  });
}
