// Reads the demo with dart:io (the web test runner never completes a
// rootBundle load, see test/runtime/demo_document_test.dart).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'audio_test.dart' show FakeAudioBackend;

ir.StageDocument loadSoundDemo() => ir.StageDocument.fromJsonMigrating(
  jsonDecode(File('assets/demo/sound.stage.json').readAsStringSync())
      as Map<String, Object?>,
);

void main() {
  test('the sound demo validates and resolves without diagnostics', () {
    final doc = loadSoundDemo();
    expect(ir.validateDocument(doc), isEmpty);
    for (final w in [390.0, 1440.0]) {
      final r = ir.resolveDocument(doc, ir.ResolveContext(viewportWidth: w));
      expect(r.diagnostics, isEmpty, reason: 'at $w');
      final title = r.scenes.firstWhere((s) => s.id == 'title');
      expect(
        title.tracks.map((t) => t.property).toSet(),
        containsAll([
          'style.fills.ink.color',
          'style.letterSpacing',
          'style.fontWeight',
        ]),
      );
    }
    final lyrics = doc.audioTracks.single.lyrics!;
    expect(lyrics.lines.length, 4);
    expect(lyrics.lines.every((l) => l.words.isNotEmpty), isTrue);
  });

  for (final size in [const Size(1440, 900), const Size(390, 844)]) {
    testWidgets('the sound demo plays through at $size', (tester) async {
      final doc = loadSoundDemo();
      final backend = FakeAudioBackend();
      final audio = StageAudioService.forDocument(
        doc,
        createBackend: () => backend,
        autoTick: false,
      );
      final controller = StagePlayerController();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StagePlayer(
            document: doc,
            viewportOverride: size,
            controller: controller,
            audio: audio,
            environment: const StageEnvironment(),
          ),
        ),
      );
      await tester.runAsync(audio.unlock);
      final scroll = controller.scrollController!;
      final max = scroll.position.maxScrollExtent;
      var heard = false;
      for (var y = 0.0; y <= max; y += size.height / 4) {
        scroll.jumpTo(y);
        backend.run(0.1);
        backend.report();
        await tester.pump(const Duration(milliseconds: 100));
        heard |= backend.isPlaying;
      }
      expect(heard, isTrue, reason: 'the lyric scene plays its track');
      expect(tester.takeException(), isNull);
      final lyricsBox = tester
          .renderObjectList<RenderStageLyrics>(
            find.byType(StageLyricsWidget, skipOffstage: false),
          )
          .toList();
      expect(lyricsBox, isNotEmpty);
    });
  }
}
