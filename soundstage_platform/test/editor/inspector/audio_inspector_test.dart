// The Scene settings' Audio list, the Audio view for a selected track and
// LRC import (m2.md T2.5a).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/audio/waveform_peaks.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/insert/file_drop.dart';
import 'package:soundstage_platform/editor/inspector/inspector.dart';
import 'package:soundstage_platform/editor/inspector/sections/audio_inspector.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../insert/fakes.dart';
import '../panels/panels_harness.dart';

const _lrc = '[00:01.00]hello world\n[00:05.50]second line';

EditorFile _text(String name, String body) =>
    (name: name, bytes: Uint8List.fromList(utf8.encode(body)), mime: '');

/// panelsDoc plus audio assets Song (a1, 185 s) and Rain (a2), the story
/// track au1 (Song) and au2 (Rain, scene s2).
ir.StageDocument _doc() => threeScenesDoc().copyWith(
  assets: const {
    'a1': ir.Asset(
      id: 'a1',
      kind: ir.AssetKind.audio,
      uri: 'local://a1',
      name: 'Song.mp3',
      duration: 185,
    ),
    'a2': ir.Asset(
      id: 'a2',
      kind: ir.AssetKind.audio,
      uri: 'local://a2',
      name: 'Rain.wav',
    ),
  },
  audioTracks: const [
    ir.AudioTrack(id: 'au1', assetId: 'a1'),
    ir.AudioTrack(id: 'au2', assetId: 'a2', scope: ir.AudioScope.scene('s2')),
  ],
);

class _Rig {
  _Rig(this.c, this.service);

  final ProviderContainer c;
  final FakeAssetService service;
}

Future<_Rig> _pump(
  WidgetTester tester, {
  List<EditorFile> picks = const [],
  double height = 1100,
}) async {
  final service = FakeAssetService();
  service.peaksById['a1'] = WaveformPeaks(
    Uint8List.fromList([10, 80, 200, 120, 30]),
    0.05,
  );
  final c = await pumpPanel(
    tester,
    const Inspector(),
    doc: _doc(),
    height: height,
    overrides: [
      editorAssetServiceProvider.overrideWithValue(service),
      editorFilePickerProvider.overrideWithValue(
        ({String accept = '', bool multiple = false}) async => picks,
      ),
    ],
  );
  return _Rig(c, service);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Finder _field(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is SsNumberField && w.semanticLabel == label,
  ),
  matching: find.byType(EditableText),
);

Finder _toggle(String label) =>
    find.byWidgetPredicate((w) => w is SsToggle && w.semanticLabel == label);

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.tap(_field(label));
  await tester.pump();
  await tester.enterText(_field(label), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

final Finder _warnings = find.byWidgetPredicate(
  (w) => w.key.toString().contains('lyrics-warning-'),
);

Finder _row(String id) => find.byKey(ValueKey('audio-$id'));

ir.AudioTrack _track(ProviderContainer c, String id) =>
    c.doc.audioTracks.firstWhere((t) => t.id == id);

void main() {
  group('Audio list in Scene settings', () {
    testWidgets('lists the story track and this scene\'s own, not others', (
      tester,
    ) async {
      final r = await _pump(tester);
      expect(find.text('Audio'), findsOneWidget);
      expect(_row('au1'), findsOneWidget);
      expect(find.text('Song.mp3'), findsOneWidget);
      expect(find.textContaining('Story · 3:05'), findsOneWidget);
      expect(_row('au2'), findsNothing);
      r.c.ctl.setActiveScene('s2');
      await tester.pump();
      expect(_row('au1'), findsOneWidget);
      expect(_row('au2'), findsOneWidget);
      expect(find.textContaining('This scene'), findsOneWidget);
    });

    testWidgets('a scene without audio says so', (tester) async {
      final r = await _pump(tester);
      r.c.ctl.execute(const RemoveAudioTrack('au1'));
      await tester.pump();
      expect(find.text('No audio in this scene.'), findsOneWidget);
    });

    testWidgets('selecting a row opens the Audio view; again closes it', (
      tester,
    ) async {
      final r = await _pump(tester);
      expect(find.byKey(const ValueKey('audio-inspector')), findsNothing);
      await tester.tap(_row('au1'));
      await tester.pump();
      expect(r.c.st.selectedAudioTrackId, 'au1');
      expect(find.byKey(const ValueKey('audio-inspector')), findsOneWidget);
      expect(find.text('Scene settings'), findsNothing);
      // Close with the X.
      await tester.tap(find.bySemanticsLabel('Close audio settings'));
      await tester.pump();
      expect(r.c.st.selectedAudioTrackId, isNull);
      expect(find.text('Scene settings'), findsOneWidget);
      // Selecting a layer replaces the Audio view.
      r.c.ctl.selectAudioTrack('au1');
      await tester.pump();
      r.c.ctl.select({'A'});
      await tester.pump();
      expect(find.byKey(const ValueKey('audio-inspector')), findsNothing);
    });

    testWidgets(
      'Add audio adds an existing asset to this scene, with a clock',
      (tester) async {
        final r = await _pump(tester);
        await tester.tap(find.bySemanticsLabel('Add audio'));
        await tester.pumpAndSettle();
        expect(find.text('Add audio'), findsWidgets);
        // Add is disabled until a file is chosen.
        expect(
          tester
              .widget<SsButton>(find.widgetWithText(SsButton, 'Add audio'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('audio-choice-a2')));
        await tester.pump();
        await tester.tap(find.widgetWithText(SsButton, 'Add audio'));
        await tester.pumpAndSettle();
        final added = r.c.doc.audioTracks.last;
        expect(added.assetId, 'a2');
        expect(added.scope, const ir.AudioScope.scene('s1'));
        expect(r.c.st.selectedAudioTrackId, added.id);
        expect(
          r.c.doc.scenes[0].clocks
              .whereType<ir.AudioClock>()
              .single
              .audioTrackId,
          added.id,
        );
        // The Audio view is up.
        expect(find.byKey(const ValueKey('audio-inspector')), findsOneWidget);
      },
    );

    testWidgets('Add audio for the whole story, uploading a new file', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        picks: [(name: 'Theme.ogg', bytes: Uint8List(8), mime: 'audio/ogg')],
      );
      await tester.tap(find.bySemanticsLabel('Add audio'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Whole story'));
      await tester.pump();
      await tester.tap(find.widgetWithText(SsButton, 'Upload file…'));
      await _settle(tester);
      await tester.pumpAndSettle();
      expect(r.service.addCount, 1);
      final added = r.c.doc.audioTracks.last;
      expect(r.c.doc.assets[added.assetId]!.name, 'Theme.ogg');
      expect(added.scope, const ir.AudioScope.story());
      expect(r.c.st.selectedAudioTrackId, added.id);
    });

    testWidgets('a cancelled upload leaves the dialog open', (tester) async {
      final r = await _pump(tester);
      await tester.tap(find.bySemanticsLabel('Add audio'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SsButton, 'Upload file…'));
      await _settle(tester);
      expect(find.widgetWithText(SsButton, 'Upload file…'), findsOneWidget);
      expect(r.c.doc.audioTracks, hasLength(2));
    });
  });

  group('Audio view', () {
    Future<_Rig> open(WidgetTester tester) async {
      final r = await _pump(tester);
      r.c.ctl.selectAudioTrack('au1');
      await tester.pump();
      return r;
    }

    testWidgets('shows the track and its waveform', (tester) async {
      await open(tester);
      expect(find.text('Song.mp3'), findsWidgets);
      await _settle(tester);
      final paint = find.descendant(
        of: find.byKey(const ValueKey('waveform-preview')),
        matching: find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is WaveformPainter,
        ),
      );
      expect(paint, findsOneWidget);
    });

    testWidgets('autoplay and loop toggle', (tester) async {
      final r = await open(tester);
      await tester.tap(_toggle('Autoplay'));
      await tester.pump();
      expect(_track(r.c, 'au1').autoplay, isTrue);
      await tester.tap(_toggle('Loop'));
      await tester.pump();
      expect(_track(r.c, 'au1').loop, isTrue);
      expect(r.c.ctl.undo(), isTrue);
      expect(_track(r.c, 'au1').loop, isFalse);
    });

    testWidgets('volume and fades take typed values', (tester) async {
      final r = await open(tester);
      await _type(tester, 'Volume', '40');
      expect(_track(r.c, 'au1').volume, closeTo(0.4, 1e-9));
      await _type(tester, 'Fade in', '1.5');
      await _type(tester, 'Fade out', '2');
      expect(_track(r.c, 'au1').fadeIn, 1.5);
      expect(_track(r.c, 'au1').fadeOut, 2);
      // Out-of-range values clamp.
      await _type(tester, 'Volume', '250');
      expect(_track(r.c, 'au1').volume, 1);
    });

    testWidgets('scope switches between story and a scene', (tester) async {
      final r = await open(tester);
      expect(_track(r.c, 'au1').scope, const ir.AudioScope.story());
      await tester.tap(
        find.descendant(
          of: find.byType(SsSegmented<bool>),
          matching: find.text('Scene'),
        ),
      );
      await tester.pump();
      // The active scene (s1).
      expect(_track(r.c, 'au1').scope, const ir.AudioScope.scene('s1'));
      expect(find.text('One'), findsWidgets);
      await tester.tap(
        find.descendant(
          of: find.byType(SsSegmented<bool>),
          matching: find.text('Story'),
        ),
      );
      await tester.pump();
      expect(_track(r.c, 'au1').scope, const ir.AudioScope.story());
    });

    testWidgets('the sound can be swapped for another audio asset', (
      tester,
    ) async {
      final r = await open(tester);
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is SsDropdown<String> && w.semanticLabel == 'Sound',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rain.wav').last);
      await tester.pumpAndSettle();
      expect(_track(r.c, 'au1').assetId, 'a2');
    });

    testWidgets('Remove audio removes the track and returns to the scene', (
      tester,
    ) async {
      final r = await open(tester);
      await tester.tap(find.widgetWithText(SsButton, 'Remove audio'));
      await tester.pump();
      expect(r.c.doc.audioTracks.map((t) => t.id), ['au2']);
      expect(r.c.st.selectedAudioTrackId, isNull);
      expect(find.text('Scene settings'), findsOneWidget);
      expect(r.c.ctl.undo(), isTrue);
      expect(r.c.doc.audioTracks, hasLength(2));
    });
  });

  group('LRC import', () {
    Future<_Rig> open(
      WidgetTester tester, {
      List<EditorFile> picks = const [],
    }) async {
      final r = await _pump(tester, picks: picks);
      r.c.ctl.selectAudioTrack('au1');
      await tester.pump();
      return r;
    }

    testWidgets('a valid file by picker sets the lyrics', (tester) async {
      final r = await open(tester, picks: [_text('song.lrc', _lrc)]);
      expect(find.text('No lyrics yet.'), findsOneWidget);
      await tester.tap(find.widgetWithText(SsButton, 'Import LRC…'));
      await _settle(tester);
      final lines = _track(r.c, 'au1').lyrics!.lines;
      expect(lines.map((l) => l.text), ['hello world', 'second line']);
      expect(lines[1].start, 5.5);
      expect(
        find.textContaining('Imported 2 lines from song.lrc'),
        findsOneWidget,
      );
      expect(_warnings, findsNothing);
      expect(find.text('hello world'), findsOneWidget);
      expect(find.text('0:05.5'), findsOneWidget);
      // One undo step.
      expect(r.c.ctl.undo(), isTrue);
      expect(_track(r.c, 'au1').lyrics, isNull);
    });

    testWidgets('invalid lines are skipped with inline warnings', (
      tester,
    ) async {
      final r = await open(
        tester,
        picks: [
          _text(
            'x.lrc',
            '[00:01.00]good\nplain text\n[00:99.00]bad time\n[00:03.00]fine',
          ),
        ],
      );
      await tester.tap(find.widgetWithText(SsButton, 'Import LRC…'));
      await _settle(tester);
      expect(_track(r.c, 'au1').lyrics!.lines.map((l) => l.text), [
        'good',
        'fine',
      ]);
      expect(_warnings, findsNWidgets(2));
      expect(find.textContaining('LRC line 2'), findsOneWidget);
      expect(find.textContaining('LRC line 3'), findsOneWidget);
    });

    testWidgets('a file with no usable lines changes nothing and says why', (
      tester,
    ) async {
      final r = await open(
        tester,
        picks: [_text('bad.txt', 'just some words\nno timestamps')],
      );
      final doc = r.c.doc;
      await tester.tap(find.widgetWithText(SsButton, 'Import LRC…'));
      await _settle(tester);
      expect(identical(r.c.doc, doc), isTrue);
      expect(find.text('No lyrics found in bad.txt.'), findsOneWidget);
      expect(_warnings, findsNWidgets(2));
    });

    testWidgets('a cancelled picker does nothing', (tester) async {
      final r = await open(tester);
      final doc = r.c.doc;
      await tester.tap(find.widgetWithText(SsButton, 'Import LRC…'));
      await _settle(tester);
      expect(identical(r.c.doc, doc), isTrue);
      expect(find.byKey(const ValueKey('lyrics-report')), findsNothing);
    });

    testWidgets('a drop on the Audio view imports; media is refused', (
      tester,
    ) async {
      final r = await open(tester);
      final at = tester.getCenter(find.byKey(const ValueKey('lyrics-import')));
      final hub = r.c.read(fileDropHubProvider);
      hub.dispatch([_text('dropped.lrc', _lrc)], at);
      await tester.pump();
      expect(_track(r.c, 'au1').lyrics!.lines, hasLength(2));
      final before = r.c.doc;
      hub.dispatch([
        (name: 'pic.png', bytes: Uint8List(4), mime: 'image/png'),
      ], at);
      await tester.pump();
      expect(identical(r.c.doc, before), isTrue);
      expect(find.textContaining('not a lyrics file'), findsOneWidget);
    });

    testWidgets('enhanced LRC keeps word times and a second import replaces', (
      tester,
    ) async {
      final r = await open(
        tester,
        picks: [_text('e.lrc', '[00:01.00]<00:01.00>one <00:01.50>two')],
      );
      await tester.tap(find.widgetWithText(SsButton, 'Import LRC…'));
      await _settle(tester);
      expect(_track(r.c, 'au1').lyrics!.lines.single.words, hasLength(2));
      expect(find.textContaining('2 timed words'), findsOneWidget);
      expect(find.widgetWithText(SsButton, 'Replace LRC…'), findsOneWidget);
    });

    testWidgets('Clear lyrics removes them', (tester) async {
      final r = await open(tester, picks: [_text('s.lrc', _lrc)]);
      await tester.tap(find.widgetWithText(SsButton, 'Import LRC…'));
      await _settle(tester);
      await tester.tap(find.widgetWithText(SsButton, 'Clear lyrics'));
      await tester.pump();
      expect(_track(r.c, 'au1').lyrics, isNull);
      expect(find.text('No lyrics yet.'), findsOneWidget);
    });
  });

  testWidgets('the Audio view fits a narrow inspector without overflow', (
    tester,
  ) async {
    final r = await _pump(tester, height: 700);
    r.c.ctl.selectAudioTrack('au1');
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.drag(
      find.byType(SingleChildScrollView).first,
      const Offset(0, -600),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
