// The Clocks UI of the scene settings (m2.md T2.4): list, per-kind fields,
// add dialog, delete dialog paths, duration warning and scaling, undo.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/inspector.dart';
import 'package:soundstage_platform/editor/inspector/sections/clock_commands.dart';
import 'package:soundstage_platform/editor/inspector/sections/clocks_section.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../panels/panels_harness.dart';

ir.Keyframe _kf(String id, double t, double v) =>
    ir.Keyframe(id: id, t: t, value: ir.IrValue.number(v));

/// s1: root [f1, f2]; clocks scroll1, time1 (2 s), point1 (over f2), beh1;
/// tracks tr1 (f1 opacity on scroll1), tr2 (f2 opacity on time1: 0, 1, 3),
/// tr3 (f1 opacity on time1: 0, 4).
ir.StageDocument _doc() => ir.StageDocument(
  id: 'doc',
  breakpoints: breakpoints,
  scenes: [
    ir.Scene(
      id: 's1',
      name: 'One',
      kind: ir.SceneKind.pinned,
      scrollLength: 1,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 1000, height: 800),
        children: [frame('f1'), frame('f2')],
      ),
      clocks: const [
        ir.Clock.sceneScroll(id: 'scroll1', sceneId: 's1'),
        ir.Clock.timeline(id: 'time1', duration: 2, name: 'Intro'),
        ir.Clock.pointer(id: 'point1', frameId: 'f2'),
        ir.Clock.behavior(id: 'beh1', nodeId: 'f1', name: 'index'),
      ],
      tracks: [
        ir.Track(
          id: 'tr1',
          target: 'f1',
          property: 'opacity',
          clockId: 'scroll1',
          keyframes: [_kf('a', 0, 0), _kf('b', 1, 1)],
        ),
        ir.Track(
          id: 'tr2',
          target: 'f2',
          property: 'opacity',
          clockId: 'time1',
          keyframes: [_kf('a', 0, 0), _kf('b', 1, 1), _kf('c', 3, 0.5)],
        ),
        ir.Track(
          id: 'tr3',
          target: 'f1',
          property: 'opacity',
          clockId: 'time1',
          keyframes: [_kf('a', 0, 0), _kf('b', 4, 1)],
        ),
      ],
    ),
  ],
);

Future<ProviderContainer> _pump(WidgetTester tester) => pumpPanel(
  tester,
  SingleChildScrollView(
    child: Consumer(
      builder: (context, ref, _) => ClocksSection(
        scene: ref.watch(
          editorControllerProvider.select((s) => s.activeScene!),
        ),
      ),
    ),
  ),
  doc: _doc(),
  height: 2600,
);

ir.Scene _scene(ProviderContainer c) => c.doc.scenes.first;
ir.Clock _clock(ProviderContainer c, String id) =>
    _scene(c).clocks.firstWhere((x) => x.id == id);
ir.TimelineClock _tl(ProviderContainer c) =>
    _clock(c, 'time1') as ir.TimelineClock;

Finder _row(String id) => find.byKey(ValueKey('clock-$id'));

Finder _in(String id, Finder f) => find.descendant(of: _row(id), matching: f);

Finder _numField(String clockId, String label) => _in(
  clockId,
  find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is SsNumberField && w.semanticLabel == label,
    ),
    matching: find.byType(EditableText),
  ),
);

Future<void> _type(WidgetTester tester, Finder field, String text) async {
  await tester.tap(field);
  await tester.pump();
  await tester.enterText(field, text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

Finder _segment<T>(String clockId, String semanticLabel, String label) => _in(
  clockId,
  find.descendant(
    of: find.byWidgetPredicate(
      (w) => w is SsSegmented<T> && w.semanticLabel == semanticLabel,
    ),
    matching: find.text(label),
  ),
);

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is SsButton && w.label == label);

Future<void> _tapAndSettle(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void _expectUndoRedo(ProviderContainer c, ir.StageDocument before) {
  final after = c.doc;
  expect(c.ctl.undo(), isTrue);
  expect(identical(c.doc, before), isTrue);
  expect(c.ctl.redo(), isTrue);
  expect(identical(c.doc, after), isTrue);
}

void main() {
  group('list', () {
    testWidgets('shows every clock with its usage count', (tester) async {
      await _pump(tester);
      expect(find.text('Clocks'), findsOneWidget);
      expect(_in('scroll1', find.text('used by 1 track')), findsOneWidget);
      expect(_in('time1', find.text('used by 2 tracks')), findsOneWidget);
      expect(_in('point1', find.text('used by 0 tracks')), findsOneWidget);
      expect(_in('time1', find.text('Intro')), findsWidgets);
      expect(_in('scroll1', find.text('Scene scroll')), findsWidgets);
    });

    testWidgets("the scene's scroll clock cannot be deleted", (tester) async {
      await _pump(tester);
      expect(
        _in('scroll1', find.bySemanticsLabel('Delete clock')),
        findsNothing,
      );
      expect(
        _in('time1', find.bySemanticsLabel('Delete clock')),
        findsOneWidget,
      );
    });

    testWidgets('a behaviour clock is read-only', (tester) async {
      await _pump(tester);
      expect(_in('beh1', find.text('Behaviour · index')), findsOneWidget);
      expect(_in('beh1', find.byType(SsNumberField)), findsNothing);
      expect(_in('beh1', find.byType(SsTextField)), findsNothing);
      expect(
        _in('beh1', find.bySemanticsLabel('Delete clock')),
        findsOneWidget,
      );
    });

    testWidgets('appears in the Inspector scene settings', (tester) async {
      await pumpPanel(tester, const Inspector(), doc: _doc(), height: 2600);
      expect(find.text('Clocks'), findsOneWidget);
      expect(find.text('Scene settings'), findsOneWidget);
    });
  });

  group('fields', () {
    testWidgets('smoothing on the scroll clock; undo/redo', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _type(tester, _numField('scroll1', 'Smoothing'), '0.4');
      expect(_clock(c, 'scroll1').smoothing, closeTo(0.4, 1e-9));
      _expectUndoRedo(c, before);
    });

    testWidgets('timeline clock: duration, rate, loop, trigger, name', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _type(tester, _numField('time1', 'Duration'), '6');
      expect(_tl(c).duration, 6);
      await _type(tester, _numField('time1', 'Rate'), '2');
      expect(_tl(c).rate, 2);
      await _type(tester, _numField('time1', 'Smoothing'), '0.25');
      expect(_tl(c).smoothing, closeTo(0.25, 1e-9));

      await _tapAndSettle(
        tester,
        _segment<ir.TimelineLoop>('time1', 'Loop', 'Ping-pong'),
      );
      expect(_tl(c).loop, ir.TimelineLoop.pingPong);
      await _tapAndSettle(
        tester,
        _segment<ir.TimelineTrigger>('time1', 'Trigger', 'Autoplay'),
      );
      expect(_tl(c).trigger, ir.TimelineTrigger.autoplay);

      final name = _in('time1', find.byType(EditableText)).first;
      await tester.tap(name);
      await tester.enterText(name, 'Hero in');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_tl(c).name, 'Hero in');

      // Every edit is undoable down to the start.
      while (c.ctl.undo()) {}
      expect(identical(c.doc, before), isTrue);
    });

    testWidgets('the interaction trigger is disabled and marked M3', (
      tester,
    ) async {
      final c = await _pump(tester);
      expect(_in('time1', find.text('M3')), findsOneWidget);
      final seg = tester.widget<SsSegmented<ir.TimelineTrigger>>(
        _in('time1', find.byType(SsSegmented<ir.TimelineTrigger>)),
      );
      final interaction = seg.segments.firstWhere(
        (s) => s.value == ir.TimelineTrigger.interaction,
      );
      expect(interaction.enabled, isFalse);
      await tester.tap(_in('time1', find.text('M3')), warnIfMissed: false);
      await tester.pump();
      expect(_tl(c).trigger, ir.TimelineTrigger.sceneEnter);
    });

    testWidgets('pointer clock: axis, frame, smoothing', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _tapAndSettle(
        tester,
        _segment<ir.PointerAxis>('point1', 'Axis', 'Y'),
      );
      expect((_clock(c, 'point1') as ir.PointerClock).axis, ir.PointerAxis.y);

      await _tapAndSettle(tester, _in('point1', find.text('f1')));
      expect((_clock(c, 'point1') as ir.PointerClock).frameId, 'f1');

      await _type(tester, _numField('point1', 'Smoothing'), '1');
      expect(_clock(c, 'point1').smoothing, 1);
      while (c.ctl.undo()) {}
      expect(identical(c.doc, before), isTrue);
    });

    testWidgets('the frame picker lists frames in layer order and searches', (
      tester,
    ) async {
      final c = await _pump(tester);
      Iterable<String> shown() => [
        for (final w in tester.widgetList<SsInteractive>(
          _in(
            'point1',
            find.byWidgetPredicate(
              (w) => w is SsInteractive && w.key.toString().contains('frame-'),
            ),
          ),
        ))
          (w.key! as ValueKey).value as String,
      ];
      // Topmost first: f2 is above f1 in paint order.
      expect(shown(), ['frame-root', 'frame-f2', 'frame-f1']);
      expect(find.text('Use selection'), findsNothing);

      final search = _in(
        'point1',
        find.descendant(
          of: find.byWidgetPredicate(
            (w) => w is SsTextField && w.semanticLabel == 'Search frames',
          ),
          matching: find.byType(EditableText),
        ),
      );
      await tester.enterText(search, 'f1');
      await tester.pump();
      expect(shown(), ['frame-f1']);
      await tester.enterText(search, 'zzz');
      await tester.pump();
      expect(find.text('No frames match.'), findsOneWidget);
      expect((_clock(c, 'point1') as ir.PointerClock).frameId, 'f2');
    });

    testWidgets('the scroll and pointer clocks can be renamed', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      for (final (id, name) in [
        ('scroll1', 'Main scroll'),
        ('point1', 'Hover'),
      ]) {
        final f = _in(id, find.byType(EditableText)).first;
        await tester.tap(f);
        await tester.enterText(f, name);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(_in(id, find.text(name)), findsWidgets);
      }
      expect((_clock(c, 'scroll1') as ir.SceneScrollClock).name, 'Main scroll');
      expect((_clock(c, 'point1') as ir.PointerClock).name, 'Hover');
      // Clearing the name restores the derived label.
      final f = _in('scroll1', find.byType(EditableText)).first;
      await tester.tap(f);
      await tester.enterText(f, '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(_in('scroll1', find.text('Scene scroll')), findsWidgets);
      while (c.ctl.undo()) {}
      expect(identical(c.doc, before), isTrue);
    });
  });

  group('add clock', () {
    Future<void> openDialog(WidgetTester tester) async {
      await _tapAndSettle(tester, find.bySemanticsLabel('Add clock').first);
      expect(find.byType(SsDialog), findsOneWidget);
    }

    Finder inDialog(Finder f) =>
        find.descendant(of: find.byType(SsDialog), matching: f);

    testWidgets('a timeline clock with chosen settings', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await openDialog(tester);
      final d = inDialog(find.byType(EditableText));
      // The first text field is the name; number fields follow.
      await tester.enterText(d.first, 'Outro');
      await tester.pump();
      await _type(
        tester,
        inDialog(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is SsNumberField && w.semanticLabel == 'Duration',
            ),
            matching: find.byType(EditableText),
          ),
        ),
        '8',
      );
      await tester.tap(inDialog(find.text('Loop')).last);
      await tester.pump();
      await tester.tap(inDialog(find.text('Autoplay')));
      await tester.pump();
      await _tapAndSettle(tester, inDialog(_button('Add clock')));

      expect(find.byType(SsDialog), findsNothing);
      final added = _scene(c).clocks.last as ir.TimelineClock;
      expect(_scene(c).clocks, hasLength(5));
      expect(added.name, 'Outro');
      expect(added.duration, 8);
      expect(added.loop, ir.TimelineLoop.loop);
      expect(added.trigger, ir.TimelineTrigger.autoplay);
      expect(find.text('Outro'), findsWidgets);
      _expectUndoRedo(c, before);
    });

    testWidgets('the dialog can be cancelled', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await openDialog(tester);
      await _tapAndSettle(tester, inDialog(_button('Cancel')));
      expect(identical(c.doc, before), isTrue);
    });

    testWidgets('a pointer clock for a chosen frame and axis', (tester) async {
      final c = await _pump(tester);
      await openDialog(tester);
      await tester.tap(inDialog(find.text('Pointer')));
      await tester.pump();
      await tester.tap(inDialog(find.text('Y')));
      await tester.pump();
      await _tapAndSettle(tester, inDialog(_button('Add clock')));
      final added = _scene(c).clocks.last as ir.PointerClock;
      expect(added.axis, ir.PointerAxis.y);
      expect(added.frameId, 'root');
      expect(_scene(c).clocks, hasLength(5));
    });

    testWidgets('both axes make two clocks in one undo step', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await openDialog(tester);
      await tester.tap(inDialog(find.text('Pointer')));
      await tester.pump();
      await tester.tap(inDialog(find.byType(SsCheckbox)));
      await tester.pump();
      await _tapAndSettle(tester, inDialog(_button('Add clock')));
      final added = _scene(c).clocks.sublist(4).cast<ir.PointerClock>();
      expect(added.map((x) => x.axis), [ir.PointerAxis.x, ir.PointerAxis.y]);
      expect(added[0].frameId, added[1].frameId);
      expect(added[0].id, isNot(added[1].id));
      _expectUndoRedo(c, before);
    });
  });

  group('delete clock', () {
    testWidgets('a clock no track uses is deleted without asking', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _tapAndSettle(
        tester,
        _in('point1', find.bySemanticsLabel('Delete clock')),
      );
      expect(find.byType(SsDialog), findsNothing);
      expect(_scene(c).clocks.map((x) => x.id), isNot(contains('point1')));
      _expectUndoRedo(c, before);
    });

    testWidgets('"Delete N tracks" removes the clock and its tracks', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _tapAndSettle(
        tester,
        _in('time1', find.bySemanticsLabel('Delete clock')),
      );
      expect(find.byType(SsDialog), findsOneWidget);
      expect(find.text('2 tracks use this clock.'), findsOneWidget);
      await _tapAndSettle(tester, _button('Delete 2 tracks'));
      expect(find.byType(SsDialog), findsNothing);
      expect(_scene(c).clocks.map((x) => x.id), isNot(contains('time1')));
      expect(_scene(c).tracks.map((t) => t.id), ['tr1']);
      // One undo step restores the clock and both tracks.
      _expectUndoRedo(c, before);
      expect(c.ctl.undo(), isTrue);
      expect(_scene(c).tracks, hasLength(3));
      expect(_scene(c).clocks.map((x) => x.id), contains('time1'));
    });

    testWidgets('"Move to clock" rebinds the tracks', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _tapAndSettle(
        tester,
        _in('time1', find.bySemanticsLabel('Delete clock')),
      );
      await _tapAndSettle(
        tester,
        find.descendant(
          of: find.byType(SsDialog),
          matching: find.byType(SsDropdown<String>),
        ),
      );
      await _tapAndSettle(tester, find.text('Scene scroll').last);
      expect(find.byType(SsDialog), findsNothing);
      final s = _scene(c);
      expect(s.clocks.map((x) => x.id), isNot(contains('time1')));
      expect(s.tracks.map((t) => t.clockId), everyElement('scroll1'));
      expect(s.tracks, hasLength(3));
      // Timeline times (0-2 s) are remapped onto the scroll range 0-1.
      expect(s.tracks[1].keyframes.map((k) => k.t), [0, 0.5, 1.5]);
      expect(s.tracks[2].keyframes.map((k) => k.t), [0, 2]);
      _expectUndoRedo(c, before);
    });

    testWidgets('cancelling the dialog changes nothing', (tester) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _tapAndSettle(
        tester,
        _in('time1', find.bySemanticsLabel('Delete clock')),
      );
      await _tapAndSettle(tester, _button('Cancel'));
      expect(identical(c.doc, before), isTrue);
      expect(find.byType(SsDialog), findsNothing);
    });
  });

  group('duration and keyframes past the end', () {
    testWidgets('a warning chip counts keyframes past the end', (tester) async {
      final c = await _pump(tester);
      // 2 s: tr2 has one at 3, tr3 one at 4.
      expect(
        _in('time1', find.text('2 keyframes past the end')),
        findsOneWidget,
      );
      await _type(tester, _numField('time1', 'Duration'), '3.5');
      expect(
        _in('time1', find.text('1 keyframe past the end')),
        findsOneWidget,
      );
      // The keyframes are kept.
      expect(_scene(c).tracks[2].keyframes.last.t, 4);
      await _type(tester, _numField('time1', 'Duration'), '10');
      expect(find.byKey(const ValueKey('past-end-chip')), findsNothing);
      expect(find.text('Scale keyframes to fit'), findsNothing);
    });

    testWidgets('"Scale keyframes to fit" is one undoable command', (
      tester,
    ) async {
      final c = await _pump(tester);
      final before = c.doc;
      await _tapAndSettle(tester, _button('Scale keyframes to fit'));
      final s = _scene(c);
      // Factor 2 / 4: the last keyframe lands on the duration.
      expect(s.tracks[1].keyframes.map((k) => k.t), [0, 0.5, 1.5]);
      expect(s.tracks[2].keyframes.map((k) => k.t), [0, 2]);
      // The scroll clock's track is untouched.
      expect(s.tracks[0].keyframes.map((k) => k.t), [0, 1]);
      expect(_tl(c).duration, 2);
      expect(find.byKey(const ValueKey('past-end-chip')), findsNothing);
      _expectUndoRedo(c, before);
      expect(c.ctl.undo(), isTrue);
      await tester.pump();
      expect(
        _in('time1', find.text('2 keyframes past the end')),
        findsOneWidget,
      );
    });

    test('ScaleClockKeyframes is a no-op when nothing is to scale', () {
      final state = EditorState.initial(_doc());
      final r = const ScaleClockKeyframes('s1', 'point1', 5).apply(state);
      expect(r.changed, isFalse);
      expect(keyframesPastEnd(state.document.scenes.first, 'time1', 4), 0);
      expect(keyframesPastEnd(state.document.scenes.first, 'time1', 3), 1);
    });
  });
}
