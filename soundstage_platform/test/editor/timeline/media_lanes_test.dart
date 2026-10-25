import 'package:flutter/material.dart' hide Easing;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/audio/waveform_peaks.dart';
import 'package:soundstage_platform/editor/timeline/timeline_audio.dart';
import 'package:soundstage_platform/ir/ir.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

import '../../runtime/audio_test.dart' show FakeAudioBackend;
import '../insert/fakes.dart';
import 'timeline_harness.dart';

const _lyrics = LyricsDoc(
  lines: [
    LyricLine(start: 1, end: 3, text: 'One'),
    LyricLine(
      start: 4,
      end: 7,
      text: 'Two words',
      words: [
        LyricWord(start: 4, text: 'Two'),
        LyricWord(start: 5, text: 'words'),
      ],
    ),
    LyricLine(start: 8, end: 9, text: 'Three'),
  ],
);

/// [timelineDoc] plus audio track `at` (asset `snd`, 10 s) with lyrics and
/// its audio clock `ac` on scene s1.
StageDocument _audioDoc() {
  final doc = timelineDoc();
  final s1 = doc.scenes.first;
  return doc.copyWith(
    assets: {
      ...doc.assets,
      'snd': const Asset(
        id: 'snd',
        kind: AssetKind.audio,
        uri: 'local://snd',
        mime: 'audio/mpeg',
      ),
    },
    audioTracks: [
      const AudioTrack(id: 'at', assetId: 'snd', lyrics: _lyrics),
    ],
    scenes: [
      s1.copyWith(
        clocks: [
          ...s1.clocks,
          const Clock.audio(id: 'ac', audioTrackId: 'at'),
        ],
      ),
      ...doc.scenes.skip(1),
    ],
  );
}

Future<TimelineRig> _pump(
  WidgetTester tester, {
  List<FakeAudioBackend>? backends,
}) async {
  final assets = FakeAssetService()
    ..peaksById['snd'] = WaveformPeaks(
      Uint8List.fromList(List.filled(1000, 128)),
      10,
    );
  final r = await pumpTimeline(
    tester,
    doc: _audioDoc(),
    assetService: assets,
    overrides: [
      if (backends != null)
        timelineAudioServiceFactoryProvider.overrideWithValue(
          (doc) => StageAudioService.forDocument(
            doc,
            autoTick: false,
            createBackend: () {
              final b = FakeAudioBackend();
              backends.add(b);
              return b;
            },
          ),
        ),
    ],
  );
  r.ctl.setActiveClock(r.st.activeSceneId!, 'ac');
  await tester.pumpAndSettle();
  return r;
}

extension on TimelineRig {
  List<LyricLine> get lines => st.document.audioTracks.single.lyrics!.lines;

  /// The global position of time [t] in the lyrics lane.
  Offset lyric(double t) {
    final f = find.byKey(const ValueKey<String>('timeline-lyrics'));
    final tl = tester.getTopLeft(f);
    final h = tester.getSize(f).height;
    return Offset(tl.dx + view.xOf(t), tl.dy + h / 2);
  }
}

void main() {
  testWidgets('an audio clock shows the waveform and lyrics lanes', (
    tester,
  ) async {
    final r = await _pump(tester);
    expect(find.byKey(const ValueKey('timeline-waveform')), findsOneWidget);
    expect(find.byKey(const ValueKey('timeline-lyrics')), findsOneWidget);
    expect(find.text('Tap to sync'), findsOneWidget);
    // Other clocks have no media lanes.
    r.ctl.setActiveClock(r.st.activeSceneId!, 'clk1');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('timeline-media-lanes')), findsNothing);
  });

  testWidgets('dragging a lyric block moves the line as one undo step, '
      'clamped by its neighbours', (tester) async {
    final r = await _pump(tester);
    await r.drag(r.lyric(5.5), r.lyric(6.5));
    expect(r.lines[1].start, closeTo(5, 0.02));
    expect(r.lines[1].end, closeTo(8, 0.02));
    expect(r.lines[1].words.last.start, closeTo(6, 0.02));
    r.ctl.undo();
    expect(r.lines[1].start, 4);
    expect(r.st.history.canUndo, isFalse);
    // Not past the next line's start.
    await r.drag(r.lyric(5.5), r.lyric(9.5));
    expect(r.lines[1].start, lessThanOrEqualTo(8));
  });

  testWidgets('dragging a block edge trims the line', (tester) async {
    final r = await _pump(tester);
    await r.drag(r.lyric(3), r.lyric(3.5));
    expect(r.lines[0].end, closeTo(3.5, 0.02));
    await r.drag(r.lyric(1), r.lyric(1.5));
    expect(r.lines[0].start, closeTo(1.5, 0.02));
  });

  testWidgets('dragging a word tick moves that word only', (tester) async {
    final r = await _pump(tester);
    await r.drag(r.lyric(5), r.lyric(5.5));
    expect(r.lines[1].words[1].start, closeTo(5.5, 0.02));
    expect(r.lines[1].start, 4);
  });

  testWidgets('double-click edits a line; Delete removes the selected line', (
    tester,
  ) async {
    final r = await _pump(tester);
    await tester.tapAt(r.lyric(8.5));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(r.lyric(8.5));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('lyric-edit')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('lyric-edit')), 'Tres');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(r.lines[2].text, 'Tres');
    await tester.tapAt(r.lyric(2));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(r.lines.map((l) => l.text), ['Two words', 'Tres']);
  });

  testWidgets('double-click on an empty spot adds a line there', (
    tester,
  ) async {
    final r = await _pump(tester);
    await tester.tapAt(r.lyric(9.6));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(r.lyric(9.6));
    await tester.pumpAndSettle();
    expect(r.lines, hasLength(4));
    expect(r.lines.last.start, closeTo(9.6, 0.02));
  });

  testWidgets('tap to sync times each line at the playhead, keeping order', (
    tester,
  ) async {
    final r = await _pump(tester);
    await tester.tap(find.text('Tap to sync'));
    await tester.pump();
    r.ctl.setPlayhead(r.st.activeSceneId!, 'ac', 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    expect(r.lines[0].start, 2);
    expect(r.lines[0].end, 4);
    // Later lines shift by the same amount.
    expect(r.lines[1].start, 5);
    r.ctl.setPlayhead(r.st.activeSceneId!, 'ac', 5.5);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pump();
    expect(r.lines[1].start, 5.5);
    expect(r.lines[1].words.last.start, 6.5);
    expect(r.lines[2].start, 9.5);
  });

  testWidgets('playing an audio clock plays its track from the playhead and '
      'the playhead follows the sound', (tester) async {
    final backends = <FakeAudioBackend>[];
    final r = await _pump(tester, backends: backends);
    r.ctl.setPlayhead(r.st.activeSceneId!, 'ac', 3);
    await tester.tap(find.bySemanticsLabel('Play'));
    await tester.pump();
    await tester.pump();
    expect(backends, isNotEmpty);
    final b = backends.single;
    expect(b.isPlaying, isTrue);
    expect(b.truePosition, 3);
    b
      ..run(1.5)
      ..report();
    await tester.pump(const Duration(milliseconds: 16));
    expect(r.st.playhead, closeTo(4.5, 1e-9));
    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.pump();
    expect(b.isPlaying, isFalse);
  });
}
