import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/inspector_providers.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

const _half = IrValue.number(0.5);

Keyframe _kf(String id, double t, double v) =>
    Keyframe(id: id, t: t, value: IrValue.number(v));

/// [fixtureDoc] with a timeline clock `tl` on s1 and an opacity track on
/// `a1` (all breakpoints, scroll clock: 0 → 0.2, 1 → 1).
StageDocument _animated({List<Track> extra = const []}) {
  final doc = fixtureDoc();
  final s1 = doc.scenes.first;
  return doc.copyWith(
    scenes: [
      s1.copyWith(
        clocks: [
          ...s1.clocks,
          const Clock.timeline(id: 'tl', duration: 4),
        ],
        tracks: [
          Track(
            id: 'op',
            target: 'a1',
            property: 'opacity',
            clockId: 'clk1',
            keyframes: [_kf('o0', 0, 0.2), _kf('o1', 1, 1)],
          ),
          ...extra,
        ],
      ),
      doc.scenes[1],
    ],
  );
}

List<Track> _tracks(EditorState s) => s.document.scenes.first.tracks;
Track _trackOf(EditorState s, String target, String property) =>
    _tracks(s).singleWhere((t) => t.target == target && t.property == property);

void main() {
  group('playheads', () {
    test('per scene per clock; the active clock defaults to scene scroll', () {
      final c = editorContainer(_animated());
      expect(c.st.activeClockId, 'clk1');
      expect(c.st.playhead, 0);
      c.ctl.setPlayhead('s1', 'tl', 2);
      c.ctl.setActivePlayhead(0.5);
      expect(c.st.playheadOf('s1', 'clk1'), 0.5);
      expect(c.st.playheadOf('s1', 'tl'), 2);
      expect(c.st.clockValuesOf('s1'), {'tl': 2.0, 'clk1': 0.5});
      c.ctl.setActiveClock('s1', 'tl');
      expect(c.st.playhead, 2);
      // A clock the scene no longer has falls back to its scroll clock.
      c.ctl.execute(const RemoveClock('s1', 'tl'));
      expect(c.st.activeClockId, 'clk1');
    });

    test('playhead changes are not undoable and keep the document', () {
      final c = editorContainer(_animated());
      final doc = c.doc;
      c.ctl.setActivePlayhead(0.7);
      expect(identical(c.doc, doc), isTrue);
      expect(c.st.history.canUndo, isFalse);
      c.ctl.execute(SetProperty(['b1'], 'x', const IrValue.number(9)));
      c.ctl.undo();
      expect(c.st.playhead, 0.7);
    });
  });

  group('SetProperty routing for animated values', () {
    test('an existing track gets a keyframe at the playhead, auto-key off', () {
      final c = editorContainer(_animated());
      c.ctl.setActivePlayhead(0.5);
      expectRoundTrip(c, SetProperty(['a1'], 'opacity', _half));
      final t = _trackOf(c.st, 'a1', 'opacity');
      expect(t.keyframes.map((k) => (k.t, k.value)), [
        (0.0, const IrValue.number(0.2)),
        (0.5, _half),
        (1.0, const IrValue.number(1)),
      ]);
      // The static value is untouched.
      expect(c.node('a1').common.opacity, 1);
      // At a keyframe's time, the keyframe is replaced.
      c.ctl.setActivePlayhead(1);
      c.ctl.execute(SetProperty(['a1'], 'opacity', const IrValue.number(0.9)));
      final t2 = _trackOf(c.st, 'a1', 'opacity');
      expect(t2.keyframes, hasLength(3));
      expect(t2.keyframes.last.id, 'o1');
      expect(t2.keyframes.last.value, const IrValue.number(0.9));
    });

    test('the keyframe goes on the playhead of the track\'s own clock', () {
      final c = editorContainer(
        _animated(
          extra: [
            Track(
              id: 'tx',
              target: 'b1',
              property: 'x',
              clockId: 'tl',
              keyframes: [_kf('x0', 0, 0)],
            ),
          ],
        ),
      );
      c.ctl
        ..setActivePlayhead(0.3)
        ..setPlayhead('s1', 'tl', 3);
      c.ctl.execute(SetProperty(['b1'], 'x', const IrValue.number(50)));
      expect(_trackOf(c.st, 'b1', 'x').keyframes.map((k) => k.t), [0.0, 3.0]);
    });

    test('auto-key off and no track: M1 routing', () {
      final c = editorContainer(_animated());
      c.ctl.setActivePlayhead(0.5);
      c.ctl.execute(SetProperty(['b1'], 'opacity', _half));
      expect(c.node('b1').common.opacity, 0.5);
      expect(_tracks(c.st), hasLength(1));
    });

    test('auto-key creates a track with a start keyframe holding the old '
        'value', () {
      final c = editorContainer(_animated());
      c.ctl
        ..setAutoKey(true)
        ..setActivePlayhead(0.5);
      expectRoundTrip(c, SetProperty(['b1'], 'opacity', _half));
      final t = _trackOf(c.st, 'b1', 'opacity');
      expect(t.clockId, 'clk1');
      expect(t.breakpoints, isNull);
      expect(t.keyframes.map((k) => (k.t, k.value)), [
        (0.0, const IrValue.number(1)),
        (0.5, _half),
      ]);
      expect(c.node('b1').common.opacity, 1, reason: 'static value kept');
      expect(c.st.history.undoLabel, 'Change opacity');
    });

    test('auto-key at the clock start writes one keyframe', () {
      final c = editorContainer(_animated());
      c.ctl.setAutoKey(true);
      c.ctl.execute(SetProperty(['b1'], 'x', const IrValue.number(7)));
      final t = _trackOf(c.st, 'b1', 'x');
      expect(t.keyframes.map((k) => (k.t, k.value)), [
        (0.0, const IrValue.number(7)),
      ]);
    });

    test('auto-key follows the edit scope and the active clock', () {
      final c = editorContainer(_animated());
      c.ctl
        ..setAutoKey(true)
        ..setEditScope(EditScope.thisBreakpoint)
        ..setEditingBreakpoint('mobile')
        ..setActiveClock('s1', 'tl')
        ..setPlayhead('s1', 'tl', 2);
      c.ctl.execute(SetProperty(['a1'], 'x', const IrValue.number(80)));
      final t = _trackOf(c.st, 'a1', 'x');
      expect(t.breakpoints, ['mobile']);
      expect(t.clockId, 'tl');
      // The start keyframe holds the mobile value (patched to 30).
      expect(t.keyframes.map((k) => (k.t, k.value)), [
        (0.0, const IrValue.number(30)),
        (2.0, const IrValue.number(80)),
      ]);
      // Desktop still writes statically (the track is mobile-only)…
      c.ctl
        ..setAutoKey(false)
        ..setEditScope(EditScope.both)
        ..setEditingBreakpoint('desktop');
      c.ctl.execute(SetProperty(['a1'], 'x', const IrValue.number(11)));
      expect(_trackOf(c.st, 'a1', 'x').keyframes, hasLength(2));
      // …and on mobile the mobile track takes the write.
      c.ctl.setEditingBreakpoint('mobile');
      c.ctl.execute(SetProperty(['a1'], 'x', const IrValue.number(90)));
      expect(
        _trackOf(c.st, 'a1', 'x').keyframes.last.value,
        const IrValue.number(90),
      );
    });

    test('a breakpoint-specific track wins over an all-breakpoints one', () {
      final c = editorContainer(
        _animated(
          extra: [
            Track(
              id: 'opMob',
              target: 'a1',
              property: 'opacity',
              clockId: 'clk1',
              breakpoints: const ['mobile'],
              keyframes: [_kf('m0', 0, 0.1)],
            ),
          ],
        ),
      );
      c.ctl
        ..setEditingBreakpoint('mobile')
        ..setActivePlayhead(0);
      c.ctl.execute(SetProperty(['a1'], 'opacity', const IrValue.number(0.3)));
      final mob = _tracks(c.st).singleWhere((t) => t.id == 'opMob');
      final all = _tracks(c.st).singleWhere((t) => t.id == 'op');
      expect(mob.keyframes.single.value, const IrValue.number(0.3));
      expect(all.keyframes.first.value, const IrValue.number(0.2));
    });

    test('non-animatable properties route as in M1 with auto-key on', () {
      final c = editorContainer(_animated());
      c.ctl
        ..setAutoKey(true)
        ..setActivePlayhead(0.5);
      c.ctl.execute(const RenameNode('b1', 'Renamed'));
      c.ctl.execute(const SetLocked(['b1'], true));
      expect(c.node('b1').common.locked, isTrue);
      expect(_tracks(c.st), hasLength(1));
    });

    test('an auto-key drag is one undo step and creates one track', () {
      final c = editorContainer(_animated());
      c.ctl
        ..setAutoKey(true)
        ..setActivePlayhead(0.5);
      final before = c.doc;
      c.ctl.beginGesture();
      for (var i = 1; i <= 5; i++) {
        c.ctl.execute(
          SetProperty.values({
            'b1': {'x': IrValue.number(i * 10.0)},
          }),
        );
      }
      c.ctl.endGesture();
      final t = _trackOf(c.st, 'b1', 'x');
      expect(t.keyframes.map((k) => (k.t, k.value)), [
        (0.0, const IrValue.number(1)),
        (0.5, const IrValue.number(50)),
      ]);
      expect(c.ctl.history.undoDepth, 1);
      c.ctl.undo();
      expect(identical(c.doc, before), isTrue);
    });
  });

  group('motion commands', () {
    test('every command round-trips through undo and redo', () {
      final c = editorContainer(_animated());
      expectRoundTrip(
        c,
        AddTrack(
          's1',
          Track(
            id: 'n',
            target: 'b1',
            property: 'y',
            clockId: 'tl',
            keyframes: [_kf('n0', 0, 0), _kf('n1', 4, 100)],
          ),
        ),
      );
      expectRoundTrip(
        c,
        AddKeyframes('s1', {
          'op': [_kf('o2', 0.5, 0.6)],
        }),
      );
      expectRoundTrip(
        c,
        const MoveKeyframes('s1', {
          'op': {'o2': 0.75},
        }),
      );
      expectRoundTrip(
        c,
        UpdateKeyframes('s1', {
          'op': {'o2': (k) => k.copyWith(value: const IrValue.number(0.4))},
        }),
      );
      expectRoundTrip(
        c,
        const SetSegmentEasing('s1', {
          'op': {'o0'},
        }, Easing.preset(EasingPreset.easeInOut)),
      );
      expectRoundTrip(c, const WriteKeyframe('s1', 'op', _half, t: 0.25));
      expectRoundTrip(
        c,
        UpdateTrack(
          's1',
          'op',
          (t) => t.copyWith(breakpoints: const ['desktop']),
        ),
      );
      expectRoundTrip(c, const MoveTracksToClock('s1', ['n'], 'clk1'));
      expectRoundTrip(
        c,
        const RemoveKeyframes('s1', {
          'op': {'o2'},
        }),
      );
      expectRoundTrip(
        c,
        const AddClock('s1', Clock.pointer(id: 'px', frameId: 'a')),
      );
      expectRoundTrip(
        c,
        UpdateClock(
          's1',
          'px',
          (k) => (k as PointerClock).copyWith(axis: PointerAxis.y),
        ),
      );
      expectRoundTrip(c, const RemoveClock('s1', 'px'));
      expectRoundTrip(
        c,
        const RemoveClock(
          's1',
          'tl',
          tracks: ClockRemoval.moveTracksTo('clk1'),
        ),
      );
      expectRoundTrip(c, const RemoveTracks('s1', ['n']));
    });

    test('a keyframe drag coalesces into one undo step', () {
      final c = editorContainer(_animated());
      final before = c.doc;
      c.ctl.beginGesture();
      for (var i = 1; i <= 10; i++) {
        c.ctl.execute(
          MoveKeyframes('s1', {
            'op': {'o1': 1 - i * 0.05},
          }),
        );
      }
      c.ctl.endGesture();
      expect(c.ctl.history.undoDepth, 1);
      expect(c.st.history.undoLabel, 'Move keyframe');
      expect(_trackOf(c.st, 'a1', 'opacity').keyframes.last.t, 0.5);
      c.ctl.undo();
      expect(identical(c.doc, before), isTrue);
    });

    test('removing the last keyframe deletes the track', () {
      final c = editorContainer(_animated());
      final r = c.ctl.execute(
        const RemoveKeyframes('s1', {
          'op': {'o0', 'o1'},
        }),
      );
      expect(r.cascade.removedTrackIds, ['op']);
      expect(_tracks(c.st), isEmpty);
    });

    test('a failed motion command records nothing', () {
      final c = editorContainer(_animated());
      final r = c.ctl.execute(const RemoveClock('s1', 'clk1'));
      expect(r.ok, isFalse);
      expect(c.st.history.canUndo, isFalse);
    });
  });

  group('inspector hook', () {
    test('the inspector reads the value at the playhead, badged Animated', () {
      final c = editorContainer(_animated());
      c.ctl.select({'a1'});
      final sub = c.listen(selectedNodesProvider, (_, _) {});
      addTearDown(sub.close);
      expect(sub.read().read('opacity').value, const IrValue.number(0.2));
      c.ctl.setActivePlayhead(0.25);
      final nodes = c.read(selectedNodesProvider);
      expect(nodes.read('opacity').value, const IrValue.number(0.4));
      expect(nodes.read('x').value, const IrValue.number(10));
      final source = valueSourceOf(nodes, 'opacity');
      expect(source.kind, ValueSourceKind.animated);
      expect(source.resettable, isFalse);
      expect(valueSourceOf(nodes, 'x').kind, ValueSourceKind.own);
      final p = c.ctl.provenanceFor('a1', 'opacity');
      expect(p.entries.last.source, const ProvenanceSource.animated('op'));
      expect(p.finalValue, const IrValue.number(0.4));
    });

    test('a static selection does not follow the playhead', () {
      final c = editorContainer(_animated());
      c.ctl.select({'b1'});
      var notified = 0;
      final sub = c.listen(selectedNodesProvider, (_, _) => notified++);
      addTearDown(sub.close);
      final first = sub.read();
      c.ctl.setActivePlayhead(0.5);
      c.ctl.setActivePlayhead(0.8);
      expect(identical(sub.read(), first) || sub.read() == first, isTrue);
      expect(notified, 0);
    });
  });
}
