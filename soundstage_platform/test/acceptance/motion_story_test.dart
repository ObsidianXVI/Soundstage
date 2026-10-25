// M2 acceptance (T2.8): the M2 definition-of-done story built in the editor
// from a new story, through the editor's own surfaces:
//   - scroll-driven parallax on a frame (Motion section → Add preset…);
//   - a timeline clock (Scene settings → Clocks → Add clock) and a fade-in
//     on it (preset dialog, clock picker);
//   - a pointer clock and a hover rotation written with auto-key
//     (toolbar stopwatch, timeline clock picker, inspector field);
//   - an audio track (Scene settings → Audio → Add audio… → Upload file…)
//     with LRC lyrics (Audio view → Import LRC…);
//   - a Lyrics behaviour and a TextReveal (Behaviour section);
// then saved and reopened through the repository, round-tripped through
// `.stage.zip`, and played: the reopened story mounts in `StagePlayer`
// with no errors, and every track evaluates to the authored values.
//
// COMMAND-DISPATCH SHORTCUTS: one. The playhead is moved with
// `setPlayhead` (a scrub, not a document edit) before the auto-key write.
// Files come from the fake picker (a tiny WAV and an LRC file).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/persistence/story_package.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'acceptance_rig.dart';

const _lrc = '[00:01.00]First light\n[00:03.00]Second line\n';

/// A 0.5 s silent mono 8 kHz WAV.
Uint8List _wav() {
  const rate = 8000, n = 4000;
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24]);
  void u16(int v) => b.add([v & 255, v >> 8 & 255]);
  b.add(ascii.encode('RIFF'));
  u32(36 + n * 2);
  b.add(ascii.encode('WAVEfmt '));
  u32(16);
  u16(1);
  u16(1);
  u32(rate);
  u32(rate * 2);
  u16(2);
  u16(16);
  b.add(ascii.encode('data'));
  u32(n * 2);
  b.add(Uint8List(n * 2));
  return b.toBytes();
}

Finder _inDialog(Finder f) =>
    find.descendant(of: find.byType(SsDialog), matching: f);

Finder _button(String label) =>
    find.byWidgetPredicate((w) => w is SsButton && w.label == label);

extension on Rig {
  ir.Scene get scene => st.activeScene!;
  ir.Track trackOn(String target, String property) => scene.tracks.singleWhere(
    (t) => t.target == target && t.property == property,
  );

  /// Scrolls the inspector to the button labelled [label] and taps it.
  Future<void> press(String label) async {
    final f = _button(label);
    await reveal(f);
    await scrollInspectorTo(f);
    await tester.tap(f.first);
    await pump(3);
  }

  Future<void> deselect() async {
    await focusEditor();
    await this.escape();
    await this.escape();
    await pump();
  }

  Future<void> addPreset(String kind, {String? clock}) async {
    await tapKey('motion-add-preset');
    await settleAnimations();
    expect(find.byKey(const ValueKey('motion-preset-dialog')), findsOneWidget);
    await pick('preset-kind', kind);
    if (clock != null) await pick('preset-clock', clock);
    await tester.tap(find.byKey(const ValueKey('preset-apply')));
    await settleAnimations();
  }

  Future<void> addClock({required bool pointer, String name = ''}) async {
    await tapLabel('Add clock');
    await settleAnimations();
    if (pointer) {
      await tester.tap(_inDialog(find.text('Pointer')).first);
      await pump();
    }
    if (!pointer) {
      await tester.enterText(
        _inDialog(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is SsTextField && w.semanticLabel == 'Clock name',
            ),
            matching: find.byType(EditableText),
          ),
        ),
        name,
      );
    }
    await pump();
    if (!pointer) {
      await tester.tap(_inDialog(find.text('Autoplay')));
      await pump();
    }
    await tester.tap(_inDialog(_button('Add clock')));
    await settleAnimations();
  }
}

void main() {
  testWidgets('the M2 story is built in the editor, saved, reopened and '
      'played', (tester) async {
    final r = await pumpNewStory(tester, title: 'Motion');
    await r.zoomToFit();
    final desk = r.doc.breakpoints
        .reduce((a, b) => a.designSize.width >= b.designSize.width ? a : b)
        .id;

    // Layers: a hero frame and a title.
    final hero = await r.draw(
      'Frame',
      desk,
      const Offset(200, 200),
      const Offset(600, 500),
    );
    final title = await r.draw(
      'Text',
      desk,
      const Offset(700, 200),
      const Offset(1100, 260),
    );
    await r.typeText('The hour between');
    await r.escape();
    await r.tapLabel('Toggle timeline');

    // 1. Scroll parallax on the hero.
    await r.selectLayer(hero);
    await r.addPreset('Parallax');
    final scroll = r.scene.clocks.whereType<ir.SceneScrollClock>().single;
    final parallax = r.trackOn(hero, 'motion.translateY');
    expect(parallax.clockId, scroll.id);
    expect(parallax.keyframes, hasLength(2));

    // 2. A timeline clock and a fade-in of the title on it.
    await r.deselect();
    await r.addClock(pointer: false, name: 'Intro');
    final intro = r.scene.clocks.whereType<ir.TimelineClock>().single;
    expect(intro.name, 'Intro');
    expect(intro.trigger, ir.TimelineTrigger.autoplay);
    await r.selectLayer(title);
    await r.addPreset('Fade', clock: 'Intro');
    final fade = r.trackOn(title, 'opacity');
    expect(fade.clockId, intro.id);
    expect(fade.keyframes.first.value, const ir.IrValue.number(0));
    expect(fade.keyframes.last.value, const ir.IrValue.number(1));

    // 3. A pointer clock and a hover rotation with auto-key.
    await r.deselect();
    await r.addClock(pointer: true);
    final hover = r.scene.clocks.whereType<ir.PointerClock>().single;
    await r.selectLayer(hero);
    await r.pick('timeline-clock', 'Pointer');
    r.ctl.setPlayhead(r.scene.id, hover.id, 1);
    await r.pump();
    await r.tapLabel('Auto-key');
    await r.type('rotation', '12');
    await r.tapLabel('Auto-key on');
    final tilt = r.trackOn(hero, 'rotation');
    expect(tilt.clockId, hover.id);
    expect([for (final k in tilt.keyframes) k.t], [0, 1]);
    expect(tilt.keyframes.last.value, const ir.IrValue.number(12));

    // 4. An audio track with lyrics.
    await r.deselect();
    r.nextPick = [(name: 'song.wav', bytes: _wav(), mime: 'audio/wav')];
    await r.tapLabel('Add audio');
    await r.settleAnimations();
    await r.tester.tap(_inDialog(_button('Upload file…')));
    await r.settleAsync();
    await r.settleAnimations();
    final track = r.doc.audioTracks.single;
    // Adding opens the track's Audio view; otherwise pick it in the list.
    if (find.byKey(const ValueKey('audio-inspector')).evaluate().isEmpty) {
      await r.tapKey('audio-${track.id}');
    }
    expect(find.byKey(const ValueKey('audio-inspector')), findsOneWidget);
    r.nextPick = [
      (
        name: 'song.lrc',
        bytes: Uint8List.fromList(utf8.encode(_lrc)),
        mime: 'text/plain',
      ),
    ];
    await r.press('Import LRC…');
    await r.settleAsync();
    await r.pump();
    final lyrics = r.doc.audioTracks.single.lyrics!;
    expect(
      [for (final l in lyrics.lines) l.text],
      ['First light', 'Second line'],
    );

    // 5. Lyrics on a new text, TextReveal on the title.
    final words = await r.draw(
      'Text',
      desk,
      const Offset(200, 600),
      const Offset(800, 660),
    );
    await r.typeText('Lyrics');
    await r.escape();
    await r.selectLayer(words);
    await r.press('Lyrics');
    await r.selectLayer(title);
    await r.press('Text reveal');
    final behaviors = <ir.Behavior>[];
    void collect(ir.Node n) {
      if (n case ir.FrameNode(:final behavior?)) behaviors.add(behavior);
      if (n case ir.FrameNode(:final children)) children.forEach(collect);
    }

    collect(r.scene.root);
    expect(
      behaviors.whereType<ir.LyricsBehavior>().single.audioTrackId,
      track.id,
    );
    expect(behaviors.whereType<ir.TextRevealBehavior>(), hasLength(1));

    final built = r.doc;
    expect(
      ir
          .validateDocument(built)
          .where((d) => d.severity == ir.IrSeverity.error),
      isEmpty,
    );

    // Save and reopen; .stage.zip round trip.
    final id = r.storyId!;
    final reopened = (await tester.runAsync(() async {
      await r.repository.save(id, built);
      return r.repository.open(id);
    }))!;
    expect(reopened.diagnostics, isEmpty);
    expect(reopened.document!.toJson(), built.toJson());
    final story = (await tester.runAsync(() async {
      final zip = await exportStageZip(built, r.repository.assetBytes);
      return importStoryFile(zip, r.store);
    }))!;
    expect(story.document!.toJson(), built.toJson());

    // Every track evaluates to the authored values.
    final sc = reopened.document!.scenes.first;
    double eval(ir.Track t, double at) =>
        (ir.evaluateTrack(t, at) as ir.NumberValue).value;
    final p = sc.tracks.firstWhere((t) => t.id == parallax.id);
    expect(eval(p, 0), isNot(closeTo(eval(p, 1), 1)));
    final f = sc.tracks.firstWhere((t) => t.id == fade.id);
    expect(eval(f, 0), 0);
    expect(eval(f, intro.duration), 1);
    final h = sc.tracks.firstWhere((t) => t.id == tilt.id);
    expect(eval(h, 1), 12);
    expect(eval(h, 0), 0);

    // It plays: the reopened story mounts in the player without errors.
    await tester.pumpWidget(
      MaterialApp(
        home: StagePlayer(
          document: reopened.document!,
          audio: StageAudioService(tracks: const []),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
