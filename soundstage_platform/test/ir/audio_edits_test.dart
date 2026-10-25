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
];

FrameNode _frame(
  String id, {
  Behavior? behavior,
  List<Interaction> interactions = const [],
  List<Node> children = const [],
}) => FrameNode(
  common: NodeCommon(
    id: id,
    width: 100,
    height: 100,
    interactions: interactions,
  ),
  behavior: behavior,
  children: children,
);

Keyframe _kf(String id, double t, double v) =>
    Keyframe(id: id, t: t, value: IrValue.number(v));

/// Assets: a1, a2 (audio), v1 (video). Audio tracks: au1 (a1, story, with an
/// audio clock in s1), au2 (a2, scene s2).
///
/// s1: f_lyrics (Lyrics on au1), f_reveal (TextReveal on aclk1), f_cue
/// (interaction i1: audioCue au1 → [playAudio au1, openUrl]; i2: tap →
/// [seekAudio au1]; i3: tap → [pauseAudio au2]), f_ctl (AudioControls au1),
/// clocks scroll1, aclk1 (audio au1); track mt1 (f_cue opacity on aclk1) and
/// mt2 (on scroll1).
/// s2: root2 and scroll2.
StageDocument _doc() => StageDocument(
  id: 'doc',
  breakpoints: _bps,
  assets: const {
    'a1': Asset(id: 'a1', kind: AssetKind.audio, uri: 'local://a1'),
    'a2': Asset(id: 'a2', kind: AssetKind.audio, uri: 'local://a2'),
    'v1': Asset(id: 'v1', kind: AssetKind.video, uri: 'local://v1'),
  },
  audioTracks: const [
    AudioTrack(id: 'au1', assetId: 'a1'),
    AudioTrack(id: 'au2', assetId: 'a2', scope: AudioScope.scene('s2')),
  ],
  scenes: [
    Scene(
      id: 's1',
      root: _frame(
        'root1',
        children: [
          _frame(
            'f_lyrics',
            behavior: const Behavior.lyrics(audioTrackId: 'au1'),
          ),
          _frame(
            'f_reveal',
            behavior: const Behavior.textReveal(clockId: 'aclk1'),
          ),
          _frame(
            'f_cue',
            interactions: const [
              Interaction(
                id: 'i1',
                trigger: InteractionTrigger.audioCue(
                  audioTrackId: 'au1',
                  time: 3,
                ),
                actions: [
                  Action.playAudio(audioTrackId: 'au1'),
                  Action.openUrl(url: 'https://example.com'),
                ],
              ),
              Interaction(
                id: 'i2',
                trigger: InteractionTrigger.tap(),
                actions: [Action.seekAudio(audioTrackId: 'au1', time: 1)],
              ),
              Interaction(
                id: 'i3',
                trigger: InteractionTrigger.tap(),
                actions: [Action.pauseAudio(audioTrackId: 'au2')],
              ),
            ],
          ),
          _frame(
            'f_ctl',
            behavior: const Behavior.audioControls(audioTrackId: 'au1'),
          ),
        ],
      ),
      clocks: const [
        Clock.sceneScroll(id: 'scroll1', sceneId: 's1'),
        Clock.audio(id: 'aclk1', audioTrackId: 'au1'),
      ],
      tracks: [
        Track(
          id: 'mt1',
          target: 'f_cue',
          property: 'opacity',
          clockId: 'aclk1',
          keyframes: [_kf('a', 0, 0), _kf('b', 2, 1)],
        ),
        Track(
          id: 'mt2',
          target: 'f_cue',
          property: 'opacity',
          clockId: 'scroll1',
          keyframes: [_kf('a', 0, 0), _kf('b', 1, 1)],
        ),
      ],
    ),
    Scene(
      id: 's2',
      root: _frame('root2'),
      clocks: const [Clock.sceneScroll(id: 'scroll2', sceneId: 's2')],
    ),
  ],
);

Node _node(StageDocument d, String id) => DocumentIndex.of(d).node(id)!;

void main() {
  group('addAudioTrack', () {
    test('adds a track and, on request, the scene audio clock', () {
      final d = _doc();
      const t = AudioTrack(
        id: 'au3',
        assetId: 'a2',
        scope: AudioScope.scene('s1'),
        autoplay: true,
      );
      final r = addAudioTrack(
        d,
        t,
        clock: const AudioClock(id: 'aclk3', audioTrackId: 'au3'),
        clockSceneId: 's1',
      );
      expect(r.ok, isTrue);
      expect(r.createdIds, ['au3']);
      expect(r.document.audioTracks.last, t);
      expect(r.document.scenes[0].clocks.map((c) => c.id), contains('aclk3'));
      expect(
        validateDocument(
          r.document,
        ).where((x) => x.severity == IrSeverity.error),
        isEmpty,
      );
      // Without a clock request no clock is made.
      final r2 = addAudioTrack(d, t);
      expect(r2.document.scenes[0].clocks, hasLength(2));
    });

    test(
      'rejects duplicate ids, missing or non-audio assets and bad scopes',
      () {
        final d = _doc();
        expect(
          addAudioTrack(d, const AudioTrack(id: 'au1', assetId: 'a1')).ok,
          isFalse,
        );
        final missing = addAudioTrack(
          d,
          const AudioTrack(id: 'x', assetId: 'nope'),
        );
        expect(missing.diagnostics.single.kind, IrDiagnosticKind.missingAsset);
        final video = addAudioTrack(
          d,
          const AudioTrack(id: 'x', assetId: 'v1'),
        );
        expect(video.diagnostics.single.kind, IrDiagnosticKind.wrongAssetKind);
        final scope = addAudioTrack(
          d,
          const AudioTrack(
            id: 'x',
            assetId: 'a1',
            scope: AudioScope.scene('zz'),
          ),
        );
        expect(scope.diagnostics.single.kind, IrDiagnosticKind.missingScene);
        expect(scope.document, same(d));
      },
    );

    test('a clock that clashes fails the whole edit', () {
      final d = _doc();
      final r = addAudioTrack(
        d,
        const AudioTrack(id: 'au3', assetId: 'a1'),
        clock: const AudioClock(id: 'aclk1', audioTrackId: 'au3'),
        clockSceneId: 's1',
      );
      expect(r.ok, isFalse);
      expect(r.document, same(d));
    });
  });

  group('updateAudioTrack', () {
    test('changes the settings and keeps the rest', () {
      final d = _doc();
      final r = updateAudioTrack(
        d,
        'au1',
        (t) => t.copyWith(
          autoplay: true,
          loop: true,
          volume: 0.4,
          fadeIn: 1,
          fadeOut: 2,
          scope: const AudioScope.scene('s2'),
          assetId: 'a2',
        ),
      );
      expect(r.ok, isTrue);
      final t = r.document.audioTracks.first;
      expect(
        (t.autoplay, t.loop, t.volume, t.fadeIn, t.fadeOut, t.assetId),
        (true, true, 0.4, 1.0, 2.0, 'a2'),
      );
      expect(t.scope, const AudioScope.scene('s2'));
      expect(identical(r.document.audioTracks[1], d.audioTracks[1]), isTrue);
    });

    test('is a no-op without a change and fails on bad values', () {
      final d = _doc();
      expect(updateAudioTrack(d, 'au1', (t) => t).changed, isFalse);
      expect(updateAudioTrack(d, 'zz', (t) => t).ok, isFalse);
      expect(
        updateAudioTrack(d, 'au1', (t) => t.copyWith(volume: 1.5)).ok,
        isFalse,
      );
      expect(
        updateAudioTrack(d, 'au1', (t) => t.copyWith(volume: -0.1)).ok,
        isFalse,
      );
      expect(
        updateAudioTrack(d, 'au1', (t) => t.copyWith(fadeIn: -1)).ok,
        isFalse,
      );
      expect(
        updateAudioTrack(d, 'au1', (t) => t.copyWith(assetId: 'v1')).ok,
        isFalse,
      );
      expect(
        updateAudioTrack(
          d,
          'au1',
          (t) => t.copyWith(scope: const AudioScope.scene('q')),
        ).ok,
        isFalse,
      );
      expect(
        updateAudioTrack(d, 'au1', (t) => t.copyWith(id: 'other')).ok,
        isFalse,
      );
    });
  });

  group('removeAudioTrack', () {
    test('removes the track, its clocks and everything that used them', () {
      final d = _doc();
      final r = removeAudioTrack(d, 'au1');
      expect(r.ok, isTrue);
      final out = r.document;
      expect(out.audioTracks.map((t) => t.id), ['au2']);
      expect(out.scenes[0].clocks.map((c) => c.id), ['scroll1']);
      // Only the motion track on the removed audio clock goes.
      expect(out.scenes[0].tracks.map((t) => t.id), ['mt2']);
      expect(r.cascade.removedClockIds, ['aclk1']);
      expect(r.cascade.removedTrackIds, ['mt1']);
      // Behaviours that used the track or its clock are cleared.
      expect((_node(out, 'f_lyrics') as FrameNode).behavior, isNull);
      expect((_node(out, 'f_reveal') as FrameNode).behavior, isNull);
      expect((_node(out, 'f_ctl') as FrameNode).behavior, isNull);
      expect(
        r.diagnostics.where((x) => x.severity == IrSeverity.warning),
        hasLength(3),
      );
      // Interactions: i1 (cue trigger) and i2 (its only action) go; i3
      // names another track and stays.
      final ix = _node(out, 'f_cue').common.interactions;
      expect(ix.map((i) => i.id), ['i3']);
      expect(r.cascade.removedInteractions.map((c) => c.interaction.id), [
        'i1',
        'i2',
      ]);
      expect(
        validateDocument(out).where((x) => x.severity == IrSeverity.error),
        isEmpty,
      );
      // Untouched scenes keep their identity.
      expect(identical(out.scenes[1], d.scenes[1]), isTrue);
    });

    test('keeps part of an interaction that has other actions', () {
      final d = _doc();
      final fixed = updateNode(
        d,
        'f_cue',
        (n) => n.copyWith(
          common: n.common.copyWith(
            interactions: [
              const Interaction(
                id: 'i9',
                trigger: InteractionTrigger.tap(),
                actions: [
                  Action.playAudio(audioTrackId: 'au1'),
                  Action.openUrl(url: 'https://example.com'),
                ],
              ),
            ],
          ),
        ),
      ).document;
      final r = removeAudioTrack(fixed, 'au1');
      final ix = _node(r.document, 'f_cue').common.interactions;
      expect(ix.single.actions, [
        const Action.openUrl(url: 'https://example.com'),
      ]);
      expect(
        r.cascade.removedActions.single.action,
        const Action.playAudio(audioTrackId: 'au1'),
      );
    });

    test('a missing track is an error', () {
      final d = _doc();
      final r = removeAudioTrack(d, 'nope');
      expect(r.ok, isFalse);
      expect(r.document, same(d));
    });

    test('a track nothing else uses leaves the rest identical', () {
      final d = addAudioTrack(
        _doc(),
        const AudioTrack(id: 'au9', assetId: 'a1'),
      ).document;
      final r = removeAudioTrack(d, 'au9');
      expect(identical(r.document.scenes[0], d.scenes[0]), isTrue);
      expect(identical(r.document.scenes[1], d.scenes[1]), isTrue);
      expect(r.cascade.isEmpty, isTrue);
    });
  });

  test('audioClockOf finds the clock of a track in a scene', () {
    final d = _doc();
    expect(audioClockOf(d, 's1', 'au1')?.id, 'aclk1');
    expect(audioClockOf(d, 's2', 'au1'), isNull);
    expect(audioClockIdFree(d, 'aclk1'), isFalse);
    expect(audioClockIdFree(d, 'zz'), isTrue);
  });
}
