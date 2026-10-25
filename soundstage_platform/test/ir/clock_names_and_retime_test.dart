// T2.4 follow-ups: optional clock names on every variant, and linear
// keyframe-time remapping when tracks move to a clock of another kind.
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _bps = [
  Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 0,
    designSize: StageSize(width: 1000, height: 800),
    primary: true,
  ),
];

Keyframe _kf(String id, double t) =>
    Keyframe(id: id, t: t, value: IrValue.number(t));

Track _tr(String id, String clock, List<double> times) => Track(
  id: id,
  target: 'f1',
  property: 'opacity',
  clockId: clock,
  keyframes: [for (var i = 0; i < times.length; i++) _kf('k$i', times[i])],
);

StageDocument _doc() => StageDocument(
  id: 'doc',
  breakpoints: _bps,
  assets: const {
    'a1': Asset(
      id: 'a1',
      kind: AssetKind.audio,
      uri: 'local://a1',
      duration: 20,
    ),
  },
  audioTracks: const [AudioTrack(id: 'au1', assetId: 'a1')],
  scenes: [
    Scene(
      id: 's1',
      kind: SceneKind.pinned,
      root: const FrameNode(
        common: NodeCommon(id: 'root', width: 1000, height: 800),
        children: [FrameNode(common: NodeCommon(id: 'f1'))],
      ),
      clocks: const [
        Clock.sceneScroll(id: 'scroll', sceneId: 's1'),
        Clock.timeline(id: 'time', duration: 10),
        Clock.timeline(id: 'time2', duration: 4),
        Clock.pointer(id: 'ptr', frameId: 'f1'),
        Clock.audio(id: 'aud', audioTrackId: 'au1'),
      ],
      tracks: [
        _tr('s', 'scroll', [0, 0.5, 1]),
        _tr('t', 'time', [0, 5, 10]),
        _tr('u', 'time2', [0, 2]),
      ],
    ),
  ],
);

List<double> _times(EditResult r, String id) => [
  for (final k
      in r.document.scenes.first.tracks.firstWhere((t) => t.id == id).keyframes)
    k.t,
];

void main() {
  group('clock names', () {
    test('every variant round-trips an optional name', () {
      const clocks = <Clock>[
        Clock.sceneScroll(id: 'a', sceneId: 's', name: 'Main scroll'),
        Clock.timeline(id: 'b', duration: 2, name: 'Intro'),
        Clock.audio(id: 'c', audioTrackId: 't', name: 'Song'),
        Clock.pointer(id: 'd', frameId: 'f', name: 'Hover'),
        Clock.behavior(id: 'e', nodeId: 'n', name: 'index'),
      ];
      for (final c in clocks) {
        expect(Clock.fromJson(c.toJson()), c);
      }
      expect((clocks[0] as SceneScrollClock).name, 'Main scroll');
      expect((clocks[2] as AudioClock).name, 'Song');
      expect((clocks[3] as PointerClock).name, 'Hover');
    });

    test('a clock without a name in JSON loads unnamed', () {
      final c = Clock.fromJson({'type': 'pointer', 'id': 'p', 'frameId': 'f'});
      expect((c as PointerClock).name, '');
      final s = Clock.fromJson({
        'type': 'sceneScroll',
        'id': 'x',
        'sceneId': 's',
      });
      expect((s as SceneScrollClock).name, '');
    });

    test('updateClock can rename the scroll clock', () {
      final r = updateClock(
        _doc(),
        's1',
        'scroll',
        (c) => c.copyWith(name: 'Main'),
      );
      expect(r.ok, isTrue);
      expect(
        (r.document.scenes.first.clocks.first as SceneScrollClock).name,
        'Main',
      );
    });
  });

  group('moving tracks to another kind of clock remaps times', () {
    test('scroll to timeline: 0-1 to 0-duration', () {
      final r = moveTracksToClock(_doc(), 's1', ['s'], 'time');
      expect(_times(r, 's'), [0, 5, 10]);
    });

    test('timeline to scroll', () {
      final r = moveTracksToClock(_doc(), 's1', ['t'], 'scroll');
      expect(_times(r, 't'), [0, 0.5, 1]);
    });

    test('timeline to pointer: 0-duration to -1..1', () {
      final r = moveTracksToClock(_doc(), 's1', ['t'], 'ptr');
      expect(_times(r, 't'), [-1, 0, 1]);
    });

    test('pointer to audio: -1..1 to 0-track length', () {
      final doc = moveTracksToClock(_doc(), 's1', ['t'], 'ptr').document;
      final r = moveTracksToClock(doc, 's1', ['t'], 'aud');
      expect(_times(r, 't'), [0, 10, 20]);
    });

    test('the same kind keeps the times', () {
      final r = moveTracksToClock(_doc(), 's1', ['t'], 'time2');
      expect(_times(r, 't'), [0, 5, 10]);
    });

    test('removeClock moving tracks remaps in the same edit', () {
      final r = removeClock(
        _doc(),
        's1',
        'time',
        tracks: const ClockRemoval.moveTracksTo('scroll'),
      );
      expect(r.ok, isTrue);
      expect(_times(r, 't'), [0, 0.5, 1]);
      // Tracks of other clocks are untouched.
      expect(_times(r, 'u'), [0, 2]);
    });

    test('a clock without a range keeps the times', () {
      final doc = _doc();
      final noLen = doc.copyWith(
        assets: {'a1': doc.assets['a1']!.copyWith(duration: null)},
      );
      final r = moveTracksToClock(noLen, 's1', ['t'], 'aud');
      expect(_times(r, 't'), [0, 5, 10]);
    });
  });
}
