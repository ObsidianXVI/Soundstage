import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _bps = [
  Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 1024,
    designSize: StageSize(width: 1000, height: 800),
    primary: true,
  ),
  Breakpoint(
    id: 'mobile',
    name: 'Mobile',
    minWidth: 0,
    designSize: StageSize(width: 400, height: 800),
    primary: true,
  ),
];

Keyframe _kf(
  String id,
  double t,
  double v, [
  Easing e = const Easing.linear(),
]) => Keyframe(id: id, t: t, value: IrValue.number(v), easing: e);

Track _opacity({
  String id = 'tr1',
  String target = 'f1',
  String clockId = 'scroll1',
  List<Keyframe>? keyframes,
  List<String>? breakpoints,
}) => Track(
  id: id,
  target: target,
  property: 'opacity',
  clockId: clockId,
  keyframes: keyframes ?? [_kf('k1', 0, 0), _kf('k2', 1, 1)],
  breakpoints: breakpoints,
);

/// s1: root1 [ f1, txt, f2, inst ] with clocks scroll1 (own scroll),
/// time1 (timeline), point1 (pointer over f2) and tracks tr1 (f1 opacity on
/// scroll1), tr2 (f1 x on time1). s2: root2 [ g1 ], clock scroll2.
StageDocument _doc() => StageDocument(
  id: 'doc',
  breakpoints: _bps,
  scenes: [
    Scene(
      id: 's1',
      kind: SceneKind.pinned,
      root: const FrameNode(
        common: NodeCommon(id: 'root1', width: 1000, height: 800),
        children: [
          FrameNode(common: NodeCommon(id: 'f1', width: 100, height: 100)),
          TextNode(common: NodeCommon(id: 'txt', width: 100, height: 20)),
          FrameNode(
            common: NodeCommon(id: 'f2', width: 100, height: 100),
            behavior: Behavior.textReveal(
              clockId: 'time1',
              range: ClockRange(start: 0, end: 1),
            ),
          ),
          InstanceNode(
            common: NodeCommon(id: 'inst'),
            source: InstanceSource.component('cmp'),
          ),
        ],
      ),
      clocks: const [
        Clock.sceneScroll(id: 'scroll1', sceneId: 's1'),
        Clock.timeline(id: 'time1', duration: 2),
        Clock.pointer(id: 'point1', frameId: 'f2'),
      ],
      tracks: [
        _opacity(),
        Track(
          id: 'tr2',
          target: 'f1',
          property: 'x',
          clockId: 'time1',
          keyframes: [_kf('a', 0, 0), _kf('b', 2, 200)],
        ),
      ],
    ),
    const Scene(
      id: 's2',
      root: FrameNode(
        common: NodeCommon(id: 'root2', width: 1000, height: 800),
        children: [FrameNode(common: NodeCommon(id: 'g1'))],
      ),
      clocks: [Clock.sceneScroll(id: 'scroll2', sceneId: 's2')],
    ),
  ],
);

Scene _s1(EditResult r) => r.document.scenes.first;
Track _track(EditResult r, String id) =>
    _s1(r).tracks.firstWhere((t) => t.id == id);

void _expectFailed(EditResult r, StageDocument doc, IrDiagnosticKind kind) {
  expect(r.ok, isFalse, reason: r.diagnostics.toString());
  expect(identical(r.document, doc), isTrue);
  expect(r.diagnostics.map((d) => d.kind), contains(kind));
}

/// The untouched parts of [doc] keep their identity in [r].
void _expectPathCopy(
  StageDocument doc,
  EditResult r, {
  Set<String> edited = const {},
}) {
  expect(identical(r.document.scenes[1], doc.scenes[1]), isTrue);
  expect(identical(_s1(r).root, doc.scenes.first.root), isTrue);
  for (final t in doc.scenes.first.tracks) {
    if (edited.contains(t.id)) continue;
    final same = _s1(r).tracks.where((x) => x.id == t.id);
    if (same.isNotEmpty) {
      expect(identical(same.single, t), isTrue, reason: t.id);
    }
  }
}

void main() {
  group('tracks', () {
    test('addTrack appends a sorted track; the rest keeps its identity', () {
      final doc = _doc();
      final r = addTrack(
        doc,
        's1',
        _opacity(
          id: 'tr3',
          target: 'txt',
          clockId: 'time1',
          keyframes: [_kf('z', 2, 1), _kf('y', 0, 0)],
        ),
      );
      expect(r.ok, isTrue, reason: r.diagnostics.toString());
      expect(r.changed, isTrue);
      expect(_track(r, 'tr3').keyframes.map((k) => k.id), ['y', 'z']);
      _expectPathCopy(doc, r);
    });

    test('addTrack checks integrity', () {
      final doc = _doc();
      _expectFailed(
        addTrack(doc, 's1', _opacity()),
        doc,
        IrDiagnosticKind.duplicateId,
      );
      _expectFailed(
        addTrack(doc, 's1', _opacity(id: 'n', clockId: 'scroll2')),
        doc,
        IrDiagnosticKind.missingClock,
      );
      _expectFailed(
        addTrack(doc, 's1', _opacity(id: 'n', target: 'g1')),
        doc,
        IrDiagnosticKind.missingTrackTarget,
      );
      _expectFailed(
        addTrack(doc, 's1', _opacity(id: 'n', target: 'f1/x')),
        doc,
        IrDiagnosticKind.missingTrackTarget,
      );
      _expectFailed(
        addTrack(doc, 's1', _opacity(id: 'n', keyframes: const [])),
        doc,
        IrDiagnosticKind.invalidEdit,
      );
      _expectFailed(
        addTrack(doc, 's1', _opacity(id: 'n', breakpoints: ['tablet'])),
        doc,
        IrDiagnosticKind.missingBreakpoint,
      );
      _expectFailed(
        addTrack(doc, 's1', _opacity(id: 'n').copyWith(property: 'nope.nope')),
        doc,
        IrDiagnosticKind.unknownPath,
      );
      // Not animatable: names.
      _expectFailed(
        addTrack(
          doc,
          's1',
          _opacity(id: 'n').copyWith(
            property: 'name',
            keyframes: [
              const Keyframe(id: 'q', t: 0, value: IrValue.string('a')),
            ],
          ),
        ),
        doc,
        IrDiagnosticKind.invalidEdit,
      );
      // A frame-only property on text.
      _expectFailed(
        addTrack(
          doc,
          's1',
          _opacity(id: 'n', target: 'txt').copyWith(
            property: 'clipContent',
            keyframes: [
              const Keyframe(id: 'q', t: 0, value: IrValue.boolean(true)),
            ],
          ),
        ),
        doc,
        IrDiagnosticKind.inapplicablePath,
      );
      // A colour value for opacity.
      _expectFailed(
        addTrack(
          doc,
          's1',
          _opacity(id: 'n').copyWith(
            keyframes: [
              const Keyframe(
                id: 'q',
                t: 0,
                value: IrValue.color(StageColor.white),
              ),
            ],
          ),
        ),
        doc,
        IrDiagnosticKind.inapplicablePath,
      );
      _expectFailed(
        addTrack(
          doc,
          's1',
          _opacity(id: 'n', keyframes: [_kf('a', 0, 0), _kf('a', 1, 1)]),
        ),
        doc,
        IrDiagnosticKind.duplicateId,
      );
      _expectFailed(
        addTrack(doc, 'nope', _opacity(id: 'n')),
        doc,
        IrDiagnosticKind.missingScene,
      );
    });

    test('tracks may target a path under an instance of the scene', () {
      final r = addTrack(_doc(), 's1', _opacity(id: 'n', target: 'inst/inner'));
      expect(r.ok, isTrue, reason: r.diagnostics.toString());
    });

    test(
      'updateTrack replaces one track and re-sorts; same track is a no-op',
      () {
        final doc = _doc();
        final r = updateTrack(
          doc,
          's1',
          'tr1',
          (t) => t.copyWith(
            breakpoints: ['mobile'],
            keyframes: [_kf('k2', 1, 1), _kf('k1', 0.5, 0)],
          ),
        );
        expect(r.ok, isTrue, reason: r.diagnostics.toString());
        expect(_track(r, 'tr1').breakpoints, ['mobile']);
        expect(_track(r, 'tr1').keyframes.map((k) => k.id), ['k1', 'k2']);
        _expectPathCopy(doc, r, edited: {'tr1'});
        final same = updateTrack(doc, 's1', 'tr1', (t) => t);
        expect(same.changed, isFalse);
        expect(identical(same.document, doc), isTrue);
        _expectFailed(
          updateTrack(doc, 's1', 'tr1', (t) => t.copyWith(id: 'tr2')),
          doc,
          IrDiagnosticKind.duplicateId,
        );
        _expectFailed(
          updateTrack(doc, 's1', 'zz', (t) => t),
          doc,
          IrDiagnosticKind.missingTrack,
        );
      },
    );

    test('updateTrack to no keyframes removes the track', () {
      final r = updateTrack(
        _doc(),
        's1',
        'tr1',
        (t) => t.copyWith(keyframes: const []),
      );
      expect(r.ok, isTrue);
      expect(_s1(r).tracks.map((t) => t.id), ['tr2']);
      expect(r.cascade.removedTrackIds, ['tr1']);
    });

    test('removeTracks', () {
      final doc = _doc();
      final r = removeTracks(doc, 's1', ['tr2']);
      expect(_s1(r).tracks.map((t) => t.id), ['tr1']);
      expect(r.cascade.removedTrackIds, ['tr2']);
      _expectPathCopy(doc, r);
      _expectFailed(
        removeTrack(doc, 's1', 'zz'),
        doc,
        IrDiagnosticKind.missingTrack,
      );
    });

    test('moveTracksToClock rebinds tracks to a clock of the scene', () {
      final doc = _doc();
      final r = moveTracksToClock(doc, 's1', ['tr1'], 'time1');
      expect(_track(r, 'tr1').clockId, 'time1');
      _expectPathCopy(doc, r, edited: {'tr1'});
      _expectFailed(
        moveTracksToClock(doc, 's1', ['tr1'], 'scroll2'),
        doc,
        IrDiagnosticKind.missingClock,
      );
      expect(moveTracksToClock(doc, 's1', ['tr2'], 'time1').changed, isFalse);
    });
  });

  group('keyframes', () {
    test('addKeyframes (batch) keeps ids, sorts, checks values', () {
      final doc = _doc();
      final r = addKeyframes(doc, 's1', {
        'tr1': [_kf('k3', 0.5, 0.25)],
        'tr2': [_kf('c', 1, 50)],
      });
      expect(r.ok, isTrue, reason: r.diagnostics.toString());
      expect(_track(r, 'tr1').keyframes.map((k) => k.id), ['k1', 'k3', 'k2']);
      expect(_track(r, 'tr2').keyframes.map((k) => k.id), ['a', 'c', 'b']);
      // Untouched keyframes keep their identity.
      expect(
        identical(
          _track(r, 'tr1').keyframes.first,
          doc.scenes[0].tracks[0].keyframes.first,
        ),
        isTrue,
      );
      _expectFailed(
        addKeyframe(doc, 's1', 'tr1', _kf('k1', 0.3, 0)),
        doc,
        IrDiagnosticKind.duplicateId,
      );
      _expectFailed(
        addKeyframe(
          doc,
          's1',
          'tr1',
          const Keyframe(id: 'q', t: 0.3, value: IrValue.string('x')),
        ),
        doc,
        IrDiagnosticKind.inapplicablePath,
      );
      _expectFailed(
        addKeyframe(doc, 's1', 'zz', _kf('q', 0, 0)),
        doc,
        IrDiagnosticKind.missingTrack,
      );
    });

    test('writeKeyframeAt replaces at the same time, else adds', () {
      final doc = _doc();
      final replace = writeKeyframeAt(
        doc,
        's1',
        'tr1',
        t: 1,
        value: const IrValue.number(0.5),
        newId: 'new',
      );
      final kfs = _track(replace, 'tr1').keyframes;
      expect(kfs.map((k) => k.id), ['k1', 'k2']);
      expect(kfs.last.value, const IrValue.number(0.5));
      final add = writeKeyframeAt(
        doc,
        's1',
        'tr1',
        t: 0.4,
        value: const IrValue.number(0.5),
        newId: 'new',
      );
      expect(_track(add, 'tr1').keyframes.map((k) => k.id), [
        'k1',
        'new',
        'k2',
      ]);
      final same = writeKeyframeAt(
        doc,
        's1',
        'tr1',
        t: 0,
        value: const IrValue.number(0),
        newId: 'new',
      );
      expect(same.changed, isFalse);
    });

    test('moveKeyframes moves in time, keeps ids and re-sorts', () {
      final doc = _doc();
      final r = moveKeyframes(doc, 's1', {
        'tr1': {'k1': 2},
      });
      expect(_track(r, 'tr1').keyframes.map((k) => (k.id, k.t)), [
        ('k2', 1.0),
        ('k1', 2.0),
      ]);
      _expectPathCopy(doc, r, edited: {'tr1'});
      _expectFailed(
        moveKeyframes(doc, 's1', {
          'tr1': {'zz': 1},
        }),
        doc,
        IrDiagnosticKind.missingKeyframe,
      );
      expect(
        moveKeyframes(doc, 's1', {
          'tr1': {'k1': 0},
        }).changed,
        isFalse,
      );
    });

    test('updateKeyframes changes values and easing but not ids', () {
      final doc = _doc();
      final r = updateKeyframe(
        doc,
        's1',
        'tr1',
        'k1',
        (k) => k.copyWith(value: const IrValue.number(0.3)),
      );
      expect(_track(r, 'tr1').keyframes.first.value, const IrValue.number(0.3));
      _expectFailed(
        updateKeyframe(doc, 's1', 'tr1', 'k1', (k) => k.copyWith(id: 'x')),
        doc,
        IrDiagnosticKind.invalidEdit,
      );
    });

    test('removeKeyframes; a track deletes itself with its last keyframe', () {
      final doc = _doc();
      final one = removeKeyframe(doc, 's1', 'tr1', 'k1');
      expect(_track(one, 'tr1').keyframes.map((k) => k.id), ['k2']);
      expect(one.cascade.removedTrackIds, isEmpty);
      final both = removeKeyframes(doc, 's1', {
        'tr1': {'k1', 'k2'},
        'tr2': {'a'},
      });
      expect(both.ok, isTrue);
      expect(_s1(both).tracks.map((t) => t.id), ['tr2']);
      expect(both.cascade.removedTrackIds, ['tr1']);
      _expectPathCopy(doc, both, edited: {'tr1', 'tr2'});
    });

    test('setSegmentEasing sets the easing of segments it names', () {
      final doc = _doc();
      const e = Easing.cubicBezier(0.4, 0, 0.2, 1);
      final r = setSegmentEasing(doc, 's1', {
        'tr1': {'k1'},
        'tr2': {'a', 'b'},
      }, e);
      expect(r.ok, isTrue);
      expect(_track(r, 'tr1').keyframes.first.easing, e);
      expect(_track(r, 'tr2').keyframes.first.easing, e);
      expect(_track(r, 'tr2').keyframes.last.easing, const Easing.linear());
      // The last keyframe starts no segment: a warning.
      expect(
        r.diagnostics.where((d) => d.severity == IrSeverity.warning),
        hasLength(1),
      );
    });

    test('resolution evaluates the edited keyframes', () {
      final r = moveKeyframes(_doc(), 's1', {
        'tr1': {'k2': 0.5},
      });
      final track = _track(r, 'tr1');
      expect(evaluateTrack(track, 0.25), const IrValue.number(0.5));
    });
  });

  group('clocks', () {
    test('addClock with document-unique ids and checked bindings', () {
      final doc = _doc();
      final r = addClock(
        doc,
        's1',
        const Clock.timeline(id: 'time2', duration: 3, name: 'Intro'),
      );
      expect(r.ok, isTrue);
      expect(_s1(r).clocks.map((c) => c.id), contains('time2'));
      _expectPathCopy(doc, r);
      _expectFailed(
        addClock(doc, 's1', const Clock.timeline(id: 'scroll2', duration: 1)),
        doc,
        IrDiagnosticKind.duplicateId,
      );
      _expectFailed(
        addClock(doc, 's1', const Clock.timeline(id: 'x', duration: 0)),
        doc,
        IrDiagnosticKind.invalidValue,
      );
      _expectFailed(
        addClock(doc, 's1', const Clock.pointer(id: 'x', frameId: 'txt')),
        doc,
        IrDiagnosticKind.missingNode,
      );
      _expectFailed(
        addClock(doc, 's1', const Clock.audio(id: 'x', audioTrackId: 'a')),
        doc,
        IrDiagnosticKind.missingAudioTrack,
      );
      _expectFailed(
        addClock(
          doc,
          's1',
          const Clock.timeline(id: 'x', duration: 1, smoothing: -1),
        ),
        doc,
        IrDiagnosticKind.invalidValue,
      );
    });

    test('updateClock; a new id rebinds tracks and text reveals', () {
      final doc = _doc();
      final r = updateClock(
        doc,
        's1',
        'time1',
        (c) =>
            (c as TimelineClock).copyWith(id: 'time9', loop: TimelineLoop.loop),
      );
      expect(r.ok, isTrue, reason: r.diagnostics.toString());
      expect(_track(r, 'tr2').clockId, 'time9');
      final f2 = _s1(r).root.children[2] as FrameNode;
      expect((f2.behavior! as TextRevealBehavior).clockId, 'time9');
      _expectFailed(
        updateClock(
          doc,
          's1',
          'scroll1',
          (_) => const Clock.timeline(id: 'scroll1', duration: 1),
        ),
        doc,
        IrDiagnosticKind.invalidEdit,
      );
      expect(updateClock(doc, 's1', 'time1', (c) => c).changed, isFalse);
    });

    test('removeClock deletes the clock and its tracks', () {
      final doc = _doc();
      final r = removeClock(doc, 's1', 'time1');
      expect(r.ok, isTrue);
      expect(_s1(r).clocks.map((c) => c.id), ['scroll1', 'point1']);
      expect(_s1(r).tracks.map((t) => t.id), ['tr1']);
      expect(r.cascade.removedTrackIds, ['tr2']);
      expect(r.cascade.removedClockIds, ['time1']);
      // The text reveal still names it: a warning.
      expect(
        r.diagnostics.map((d) => d.kind),
        contains(IrDiagnosticKind.missingClock),
      );
      expect(identical(_s1(r).tracks.single, doc.scenes[0].tracks[0]), isTrue);
    });

    test('removeClock can move its tracks to another clock', () {
      final doc = _doc();
      final r = removeClock(
        doc,
        's1',
        'time1',
        tracks: const ClockRemoval.moveTracksTo('scroll1'),
      );
      expect(r.ok, isTrue);
      expect(_s1(r).tracks.map((t) => (t.id, t.clockId)), [
        ('tr1', 'scroll1'),
        ('tr2', 'scroll1'),
      ]);
      expect(r.cascade.removedTrackIds, isEmpty);
      expect(r.diagnostics, isEmpty); // the text reveal moved too
      _expectFailed(
        removeClock(
          doc,
          's1',
          'time1',
          tracks: const ClockRemoval.moveTracksTo('time1'),
        ),
        doc,
        IrDiagnosticKind.missingClock,
      );
    });

    test('the scene keeps its scroll clock', () {
      final doc = _doc();
      _expectFailed(
        removeClock(doc, 's1', 'scroll1'),
        doc,
        IrDiagnosticKind.invalidEdit,
      );
      _expectFailed(
        removeClock(doc, 's1', 'nope'),
        doc,
        IrDiagnosticKind.missingClock,
      );
    });

    test('edits keep the document valid', () {
      var doc = _doc();
      // Give the instance a component so validation is about motion only.
      doc = doc.copyWith(
        components: {
          'cmp': const ComponentDef(
            id: 'cmp',
            name: 'C',
            root: FrameNode(
              common: NodeCommon(id: 'cr'),
              children: [FrameNode(common: NodeCommon(id: 'inner'))],
            ),
          ),
        },
      );
      final before = validateDocument(
        doc,
      ).where((d) => d.severity == IrSeverity.error);
      expect(before, isEmpty, reason: before.toString());
      for (final r in [
        addTrack(doc, 's1', _opacity(id: 'n', target: 'inst/inner')),
        removeClock(doc, 's1', 'point1'),
        removeClock(
          doc,
          's1',
          'time1',
          tracks: const ClockRemoval.moveTracksTo('scroll1'),
        ),
        removeKeyframes(doc, 's1', {
          'tr2': {'a', 'b'},
        }),
      ]) {
        expect(r.ok, isTrue, reason: r.diagnostics.toString());
        final errs = validateDocument(
          r.document,
        ).where((d) => d.severity == IrSeverity.error);
        expect(errs, isEmpty, reason: errs.toString());
      }
    });
  });
}
