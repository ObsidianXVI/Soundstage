import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Easing;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/easing/easing_curve.dart';
import 'package:soundstage_platform/editor/timeline/timeline_model.dart';
import 'package:soundstage_platform/ir/ir.dart';

import '../inspector/inspector_harness.dart' as insp;
import '../timeline/timeline_harness.dart';

// The easing editor against the document (m2.md "Easing editor"): opening it
// from the timeline and the Motion section, one segment or many (Mixed), and
// undo: one step per committed change, handle drags coalesced.

Finder _key(String k) => find.byKey(ValueKey<String>(k));

const _bx = 3; // lane row of track `bx` (see timelineDoc)
const _ease = Easing.preset(EasingPreset.easeInOut);

Easing _easingOf(TimelineRig r, String track, String kf) =>
    r.track(track).keyframes.firstWhere((k) => k.id == kf).easing;

Future<void> _openBx(TimelineRig r) async {
  await r.click(r.at(_bx, 0.5));
  await r.click(r.at(_bx, 0.5));
  await r.tester.pump();
}

Offset _handle(WidgetTester tester, int i) {
  final p =
      tester.widget<CustomPaint>(_key('easing-curve')).painter!
          as EasingCurvePainter;
  final c = p.controls!;
  final size = tester.getSize(_key('easing-curve'));
  return tester.getTopLeft(_key('easing-curve')) +
      (i == 0 ? p.toPx(size, c.$1, c.$2) : p.toPx(size, c.$3, c.$4));
}

void main() {
  group('from the timeline', () {
    testWidgets('double-clicking a segment opens the editor on it', (
      tester,
    ) async {
      final r = await pumpTimeline(tester);
      r.ctl.execute(
        const SetSegmentEasing('s1', {
          'bx': {'x0'},
        }, _ease),
      );
      await tester.pump();
      await _openBx(r);
      expect(_key('easing-editor'), findsOneWidget);
      expect(find.text('Easing'), findsWidgets);
      expect(_key('easing-mixed'), findsNothing);
      // It shows that segment's curve: ease-in-out is selected.
      await tester.tap(_key('easing-preset:easeOutBack'));
      await tester.pump();
      expect(
        _easingOf(r, 'bx', 'x0'),
        const Easing.preset(EasingPreset.easeOutBack),
      );
      // Only that segment changed.
      expect(_easingOf(r, 'op', 'o0'), const Easing.linear());
      expect(r.st.history.undoLabel, 'Change easing');
    });

    testWidgets(
      'each committed change is one undo step; a handle drag is one',
      (tester) async {
        final r = await pumpTimeline(tester);
        await _openBx(r);
        expect(_easingOf(r, 'bx', 'x0'), const Easing.linear());

        await tester.tap(_key('easing-preset:easeIn'));
        await tester.pump();
        await tester.tap(_key('easing-preset:easeOut'));
        await tester.pump();
        await tester.tap(find.text('Bezier'));
        await tester.pump();
        final seeded = _easingOf(r, 'bx', 'x0');
        expect(seeded, const Easing.cubicBezier(0, 0, 0.58, 1));

        final g = await tester.startGesture(
          _handle(tester, 0),
          kind: PointerDeviceKind.mouse,
        );
        for (var i = 0; i < 8; i++) {
          await g.moveBy(const Offset(5, -12));
          await tester.pump();
        }
        await g.up();
        await tester.pump();
        final dragged = _easingOf(r, 'bx', 'x0') as CubicBezierEasing;
        expect(dragged.x1, greaterThan(0));
        expect(dragged.y1, greaterThan(0));

        // A number entry after the drag is another step.
        final f = find.descendant(
          of: _key('easing-field:y2'),
          matching: find.byType(EditableText),
        );
        await tester.tap(f);
        await tester.pump();
        await tester.enterText(f, '1.5');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        expect((_easingOf(r, 'bx', 'x0') as CubicBezierEasing).y2, 1.5);

        // Undo: the entry, then the whole drag, then the tab, then each
        // preset, in turn.
        expect(r.ctl.undo(), isTrue);
        expect(_easingOf(r, 'bx', 'x0'), dragged);
        expect(r.ctl.undo(), isTrue);
        expect(_easingOf(r, 'bx', 'x0'), seeded);
        expect(r.ctl.undo(), isTrue);
        expect(
          _easingOf(r, 'bx', 'x0'),
          const Easing.preset(EasingPreset.easeOut),
        );
        expect(r.ctl.undo(), isTrue);
        expect(
          _easingOf(r, 'bx', 'x0'),
          const Easing.preset(EasingPreset.easeIn),
        );
        expect(r.ctl.undo(), isTrue);
        expect(_easingOf(r, 'bx', 'x0'), const Easing.linear());
        // The editor follows the document.
        await tester.pump();
        expect(_key('easing-editor'), findsOneWidget);
        expect(r.ctl.redo(), isTrue);
        await tester.pump();
        expect(
          _easingOf(r, 'bx', 'x0'),
          const Easing.preset(EasingPreset.easeIn),
        );
      },
    );

    testWidgets('selected segments are edited together; differing is Mixed', (
      tester,
    ) async {
      final r = await pumpTimeline(tester);
      r.ctl.execute(
        const SetSegmentEasing('s1', {
          'bx': {'x0'},
        }, _ease),
      );
      r.tl.select({
        (track: 'bx', keyframe: 'x0'),
        (track: 'op', keyframe: 'o0'),
        // The last keyframe of a track starts no segment: ignored.
        (track: 'op', keyframe: 'o1'),
      });
      r.tl.easingSegment.value = (track: 'bx', keyframe: 'x0');
      await tester.pump();
      await tester.pump();
      expect(_key('easing-mixed'), findsOneWidget);
      expect(find.text('Easing · 2 segments'), findsOneWidget);
      expect(
        find.descendant(of: _key('easing-hook'), matching: find.text('Mixed')),
        findsOneWidget,
      );
      await tester.tap(_key('easing-preset:easeIn'));
      await tester.pump();
      const easeIn = Easing.preset(EasingPreset.easeIn);
      expect(_easingOf(r, 'bx', 'x0'), easeIn);
      expect(_easingOf(r, 'op', 'o0'), easeIn);
      expect(_key('easing-mixed'), findsNothing);
      // One command for both: one undo.
      expect(r.ctl.undo(), isTrue);
      expect(_easingOf(r, 'bx', 'x0'), _ease);
      expect(_easingOf(r, 'op', 'o0'), const Easing.linear());
      await tester.pump();
      expect(_key('easing-mixed'), findsOneWidget);
    });

    testWidgets('a segment outside the selection is edited alone', (
      tester,
    ) async {
      final r = await pumpTimeline(tester);
      r.tl.select({(track: 'op', keyframe: 'o0')});
      r.tl.easingSegment.value = (track: 'bx', keyframe: 'x0');
      await tester.pump();
      await tester.pump();
      await tester.tap(_key('easing-preset:ease'));
      await tester.pump();
      expect(_easingOf(r, 'bx', 'x0'), const Easing.preset(EasingPreset.ease));
      expect(_easingOf(r, 'op', 'o0'), const Easing.linear());
    });

    testWidgets('Escape and the close button close it', (tester) async {
      final r = await pumpTimeline(tester);
      await _openBx(r);
      expect(_key('easing-editor'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump();
      expect(_key('easing-editor'), findsNothing);
      expect(r.tl.easingSegment.value, isNull);
      expect(_key('easing-hook'), findsNothing);

      await _openBx(r);
      expect(_key('easing-editor'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Close easing editor'));
      await tester.pump();
      await tester.pump();
      expect(_key('easing-editor'), findsNothing);
      expect(r.tl.easingSegment.value, isNull);
    });

    testWidgets('the segment being deleted closes the editor', (tester) async {
      final r = await pumpTimeline(tester);
      await _openBx(r);
      r.ctl.execute(
        const RemoveKeyframes('s1', {
          'bx': {'x1'},
        }),
      );
      await tester.pump();
      await tester.pump();
      expect(_key('easing-editor'), findsNothing);
    });
  });

  group('from the Motion section', () {
    Future<ProviderContainer> pump(WidgetTester tester) async {
      final d = insp.inspectorDoc([insp.rect('r', x: 10, y: 20)]);
      final s = d.scenes.single;
      final c = await insp.pumpInspector(
        tester,
        d.copyWith(
          scenes: [
            s.copyWith(
              tracks: [
                const Track(
                  id: 'tx',
                  target: 'r',
                  property: 'x',
                  clockId: 'clk1',
                  keyframes: [
                    Keyframe(id: 'k0', t: 0, value: IrValue.number(0)),
                    Keyframe(id: 'k1', t: 0.5, value: IrValue.number(50)),
                    Keyframe(id: 'k2', t: 1, value: IrValue.number(100)),
                  ],
                ),
              ],
            ),
          ],
        ),
        select: {'r'},
        width: 288,
        height: 1000,
      );
      return c;
    }

    List<Easing> easings(ProviderContainer c) => [
      for (final k
          in c
              .read(editorControllerProvider)
              .document
              .scenes
              .single
              .tracks
              .single
              .keyframes)
        k.easing,
    ];

    testWidgets('a track\'s easing button edits all its segments', (
      tester,
    ) async {
      final c = await pump(tester);
      await tester.tap(_key('motion-easing:X'));
      await tester.pump();
      expect(_key('easing-editor'), findsOneWidget);
      expect(find.text('Easing · 2 segments'), findsOneWidget);
      await tester.tap(find.text('Hold'));
      await tester.pump();
      expect(easings(c), [
        const Easing.hold(),
        const Easing.hold(),
        const Easing.linear(),
      ]);
      // The last keyframe starts no segment, so it was not touched.
      c.read(editorControllerProvider.notifier).undo();
      expect(easings(c).first, const Easing.linear());
    });

    testWidgets('selected keyframes get their own entry', (tester) async {
      final c = await pump(tester);
      expect(_key('motion-selected-easing'), findsNothing);
      c.read(timelineControllerProvider).select({
        (track: 'tx', keyframe: 'k1'),
      });
      await tester.pump();
      expect(find.text('Selected segment easing…'), findsOneWidget);
      await tester.tap(_key('motion-selected-easing'));
      await tester.pump();
      expect(find.text('Easing'), findsWidgets);
      await tester.tap(_key('easing-preset:easeOut'));
      await tester.pump();
      expect(easings(c), [
        const Easing.linear(),
        const Easing.preset(EasingPreset.easeOut),
        const Easing.linear(),
      ]);
    });

    testWidgets('a track with one keyframe has no segment to edit', (
      tester,
    ) async {
      final d = insp.inspectorDoc([insp.rect('r')]);
      final s = d.scenes.single;
      await insp.pumpInspector(
        tester,
        d.copyWith(
          scenes: [
            s.copyWith(
              tracks: [
                const Track(
                  id: 'tx',
                  target: 'r',
                  property: 'x',
                  clockId: 'clk1',
                  keyframes: [
                    Keyframe(id: 'k0', t: 0, value: IrValue.number(0)),
                  ],
                ),
              ],
            ),
          ],
        ),
        select: {'r'},
      );
      await tester.tap(_key('motion-easing:X'), warnIfMissed: false);
      await tester.pump();
      expect(_key('easing-editor'), findsNothing);
    });
  });
}
