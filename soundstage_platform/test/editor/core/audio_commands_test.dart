import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

/// [fixtureDoc] with audio assets a1/a2 and the track au1 (a1, story) with
/// two lyric lines.
StageDocument _doc() => fixtureDoc().copyWith(
  assets: const {
    'a1': Asset(id: 'a1', kind: AssetKind.audio, uri: 'local://a1'),
    'a2': Asset(id: 'a2', kind: AssetKind.audio, uri: 'local://a2'),
  },
  audioTracks: const [
    AudioTrack(
      id: 'au1',
      assetId: 'a1',
      lyrics: LyricsDoc(
        lines: [
          LyricLine(start: 1, text: 'hello world', end: 2),
          LyricLine(
            start: 3,
            text: 'good bye',
            words: [
              LyricWord(start: 3, text: 'good'),
              LyricWord(start: 3.5, text: 'bye'),
            ],
          ),
        ],
      ),
    ),
  ],
);

List<LyricLine> _lines(ProviderContainer c) =>
    c.doc.audioTracks.first.lyrics!.lines;

void main() {
  group('AddAudioTrack', () {
    test(
      'adds a scene-scoped track with the scene audio clock and selects it',
      () {
        final c = editorContainer(_doc());
        c.ctl.select({'a'});
        final before = c.doc;
        final r = c.ctl.execute(
          const AddAudioTrack(
            'a2',
            sceneId: 's1',
            clockSceneId: 's1',
            autoplay: true,
          ),
        );
        expect(r.ok, isTrue);
        final t = c.doc.audioTracks.last;
        expect(t.assetId, 'a2');
        expect(t.scope, const AudioScope.scene('s1'));
        expect(t.autoplay, isTrue);
        expect(c.st.selectedAudioTrackId, t.id);
        expect(c.st.selection, isEmpty);
        final clocks = c.doc.scenes[0].clocks.whereType<AudioClock>();
        expect(clocks.single.audioTrackId, t.id);
        expect(
          validateDocument(c.doc).where((d) => d.severity == IrSeverity.error),
          isEmpty,
        );
        // One undo step takes the track and its clock away.
        expect(c.ctl.undo(), isTrue);
        expect(identical(c.doc, before), isTrue);
        expect(c.st.selectedAudioTrackId, isNull);
      },
    );

    test('a story track with no clock request makes no clock', () {
      final c = editorContainer(_doc());
      final before = c.doc.scenes[0].clocks.length;
      c.ctl.execute(const AddAudioTrack('a2'));
      expect(c.doc.audioTracks.last.scope, const AudioScope.story());
      expect(c.doc.scenes[0].clocks, hasLength(before));
    });

    test('a bad asset fails and changes nothing', () {
      final c = editorContainer(_doc());
      final doc = c.doc;
      final r = c.ctl.execute(const AddAudioTrack('nope'));
      expect(r.ok, isFalse);
      expect(identical(c.doc, doc), isTrue);
      expect(c.st.history.canUndo, isFalse);
    });
  });

  group('UpdateAudioTrack', () {
    test('changes settings; a volume scrub coalesces into one undo step', () {
      final c = editorContainer(_doc());
      c.ctl.beginGesture();
      for (final v in [0.9, 0.7, 0.5]) {
        c.ctl.execute(
          UpdateAudioTrack(
            'au1',
            (t) => t.copyWith(volume: v),
            label: 'Change volume',
            coalesceKey: 'audio:au1:volume',
          ),
        );
      }
      c.ctl.endGesture();
      expect(c.doc.audioTracks.first.volume, 0.5);
      expect(c.ctl.undo(), isTrue);
      expect(c.doc.audioTracks.first.volume, 1);
      expect(c.st.history.canUndo, isFalse);
    });

    test('rejects a bad value', () {
      final c = editorContainer(_doc());
      final r = c.ctl.execute(
        UpdateAudioTrack('au1', (t) => t.copyWith(volume: 2)),
      );
      expect(r.ok, isFalse);
      expect(c.doc.audioTracks.first.volume, 1);
    });
  });

  group('RemoveAudioTrack', () {
    test(
      'removes the track and clears the audio selection; undo restores both document and track',
      () {
        final c = editorContainer(_doc());
        c.ctl.selectAudioTrack('au1');
        expect(c.st.selectedAudioTrackId, 'au1');
        c.ctl.execute(const RemoveAudioTrack('au1'));
        expect(c.doc.audioTracks, isEmpty);
        expect(c.st.selectedAudioTrackId, isNull);
        expect(c.ctl.undo(), isTrue);
        expect(c.doc.audioTracks, hasLength(1));
      },
    );
  });

  group('audio selection', () {
    test('is separate from the node selection', () {
      final c = editorContainer(_doc());
      c.ctl.select({'a'});
      c.ctl.selectAudioTrack('au1');
      expect(c.st.selection, isEmpty);
      expect(c.st.selectedAudioTrackId, 'au1');
      c.ctl.select({'b'});
      expect(c.st.selectedAudioTrackId, isNull);
      c.ctl.selectAudioTrack('au1');
      c.ctl.setActiveScene('s2');
      expect(c.st.selectedAudioTrackId, isNull);
      c.ctl.selectAudioTrack('au1');
      c.ctl.clearSelection();
      expect(c.st.selectedAudioTrackId, 'au1');
      c.ctl.selectAudioTrack('missing');
      expect(c.st.selectedAudioTrackId, isNull);
    });
  });

  group('lyrics commands', () {
    test('SetLyrics imports and ClearLyrics clears, both undoable', () {
      final c = editorContainer(_doc());
      final parsed = parseLrc('[00:01.00]a\n[00:02.00]b').doc;
      expectRoundTrip(c, SetLyrics('au1', parsed));
      expect(_lines(c).map((l) => l.text), ['a', 'b']);
      expectRoundTrip(c, const ClearLyrics('au1'));
      expect(c.doc.audioTracks.first.lyrics, isNull);
    });

    test('UpdateLyricLine edits text, start and end', () {
      final c = editorContainer(_doc());
      expectRoundTrip(
        c,
        UpdateLyricLine(
          'au1',
          0,
          (l) => l.copyWith(text: 'hi there', start: 1.5, end: 2.5),
        ),
      );
      expect(_lines(c)[0].text, 'hi there');
      expect(_lines(c)[0].start, 1.5);
      expect(_lines(c)[0].end, 2.5);
    });

    test('an edge drag is one undo step', () {
      final c = editorContainer(_doc());
      c.ctl.beginGesture();
      for (final e in [2.2, 2.6, 2.9]) {
        c.ctl.execute(
          UpdateLyricLine('au1', 0, (l) => l.copyWith(end: e), coalesce: true),
        );
      }
      c.ctl.endGesture();
      expect(_lines(c)[0].end, 2.9);
      c.ctl.undo();
      expect(_lines(c)[0].end, 2);
      expect(c.st.history.canUndo, isFalse);
    });

    test('MoveLyricLine drags a block with its words', () {
      final c = editorContainer(_doc());
      c.ctl.execute(const MoveLyricLine('au1', 1, 4));
      expect(_lines(c)[1].start, 4);
      expect(_lines(c)[1].words.map((w) => w.start), [4, 4.5]);
    });

    test('UpdateLyricWord changes a word timing', () {
      final c = editorContainer(_doc());
      expectRoundTrip(
        c,
        UpdateLyricWord('au1', 1, 1, (w) => w.copyWith(start: 3.7, end: 4)),
      );
      expect(_lines(c)[1].words[1].start, 3.7);
    });

    test('InsertLyricLine and RemoveLyricLine', () {
      final c = editorContainer(_doc());
      expectRoundTrip(
        c,
        const InsertLyricLine('au1', LyricLine(start: 2.5, text: 'between')),
      );
      expect(_lines(c).map((l) => l.text), [
        'hello world',
        'between',
        'good bye',
      ]);
      expectRoundTrip(c, const RemoveLyricLine('au1', 1));
      expect(_lines(c), hasLength(2));
    });

    test('an out-of-order start fails without recording history', () {
      final c = editorContainer(_doc());
      final r = c.ctl.execute(
        UpdateLyricLine('au1', 0, (l) => l.copyWith(start: 5)),
      );
      expect(r.ok, isFalse);
      expect(c.st.history.canUndo, isFalse);
    });
  });

  group('behaviours', () {
    test('SetBehavior sets and removes a frame behaviour', () {
      final c = editorContainer(_doc());
      expectRoundTrip(
        c,
        const SetBehavior('b', Behavior.lyrics(audioTrackId: 'au1')),
      );
      expect(
        (c.node('b') as FrameNode).behavior,
        const Behavior.lyrics(audioTrackId: 'au1'),
      );
      expectRoundTrip(c, const SetBehavior('b', null));
      expect((c.node('b') as FrameNode).behavior, isNull);
    });

    test('SetBehavior needs a frame', () {
      final c = editorContainer(_doc());
      expect(c.ctl.execute(const SetBehavior('t1', null)).ok, isFalse);
    });

    test('WrapTextInBehavior wraps the text in a frame with the behaviour', () {
      final c = editorContainer(_doc());
      c.ctl.select({'t1'});
      c.ctl.execute(
        const WrapTextInBehavior('t1', Behavior.textReveal(clockId: 'clk1')),
      );
      final loc = DocumentIndex.of(c.doc).locate('t1')!;
      expect(loc.parentId, isNot('a'));
      final wrapper = c.node(loc.parentId!) as FrameNode;
      expect(wrapper.behavior, const Behavior.textReveal(clockId: 'clk1'));
      expect(wrapper.children.single.id, 't1');
      expect((c.node('a') as FrameNode).children.contains(wrapper), isTrue);
      expect(c.st.selection, {'t1'});
      c.ctl.undo();
      expect(DocumentIndex.of(c.doc).locate('t1')!.parentId, 'a');
    });
  });
}
