// The Behaviour section: Lyrics and TextReveal setup on a text node
// (m2.md T2.5a).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/inspector.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../panels/panels_harness.dart';

/// panelsDoc (s1: A [A1, A2 [A21], T (text)], B, …) with the audio asset
/// Song, the story track au1 (with lyrics), and the timeline clock `tl`
/// (6 s) in s1.
ir.StageDocument _doc() {
  final base = panelsDoc();
  final s1 = base.scenes.first;
  return base.copyWith(
    assets: const {
      'a1': ir.Asset(
        id: 'a1',
        kind: ir.AssetKind.audio,
        uri: 'local://a1',
        name: 'Song.mp3',
        duration: 90,
      ),
      'a2': ir.Asset(
        id: 'a2',
        kind: ir.AssetKind.audio,
        uri: 'local://a2',
        name: 'Rain.wav',
      ),
    },
    audioTracks: const [
      ir.AudioTrack(
        id: 'au1',
        assetId: 'a1',
        lyrics: ir.LyricsDoc(lines: [ir.LyricLine(start: 1, text: 'la')]),
      ),
      ir.AudioTrack(id: 'au2', assetId: 'a2'),
    ],
    scenes: [
      s1.copyWith(
        clocks: [
          ...s1.clocks,
          const ir.Clock.timeline(id: 'tl', duration: 6, name: 'Intro'),
          const ir.Clock.audio(id: 'aclk', audioTrackId: 'au1'),
        ],
      ),
      base.scenes[1],
    ],
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  String select = 'T',
  ir.StageDocument? doc,
  double width = 288,
}) async {
  final c = await pumpPanel(
    tester,
    const Inspector(),
    doc: doc ?? _doc(),
    height: 4000,
    width: width,
  );
  c.ctl.select({select});
  await tester.pumpAndSettle();
  return c;
}

Finder _field(String label) => find.descendant(
  of: find.byWidgetPredicate(
    (w) => w is SsNumberField && w.semanticLabel == label,
  ),
  matching: find.byType(EditableText),
);

Future<void> _type(WidgetTester tester, String label, String text) async {
  await tester.tap(_field(label));
  await tester.pumpAndSettle();
  await tester.enterText(_field(label), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

Finder _dropdown(String label) => find.byWidgetPredicate(
  (w) => w is SsDropdown<String> && w.semanticLabel == label,
);

Future<void> _choose(WidgetTester tester, String label, String item) async {
  await tester.tap(_dropdown(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item).last);
  await tester.pumpAndSettle();
}

Finder _button(String label) => find.widgetWithText(SsButton, label);

ir.FrameNode _parentOf(ProviderContainer c, String id) {
  final loc = ir.DocumentIndex.of(c.doc).locate(id)!;
  return ir.DocumentIndex.of(c.doc).node(loc.parentId!)! as ir.FrameNode;
}

ir.Behavior? _behaviorOf(ProviderContainer c, String frameId) =>
    (ir.DocumentIndex.of(c.doc).node(frameId)! as ir.FrameNode).behavior;

void main() {
  group('setup on a text node', () {
    testWidgets('offers Lyrics and Text reveal', (tester) async {
      await _pump(tester);
      expect(find.text('Behaviour'), findsOneWidget);
      expect(_button('Lyrics'), findsOneWidget);
      expect(_button('Text reveal'), findsOneWidget);
      expect(tester.widget<SsButton>(_button('Lyrics')).onPressed, isNotNull);
    });

    testWidgets('Lyrics wraps the text in a frame using the first track', (
      tester,
    ) async {
      final c = await _pump(tester);
      await tester.tap(_button('Lyrics'));
      await tester.pumpAndSettle();
      final wrapper = _parentOf(c, 'T');
      expect(wrapper.id, isNot('A'));
      expect(
        wrapper.behavior,
        isA<ir.LyricsBehavior>().having((b) => b.audioTrackId, 'track', 'au1'),
      );
      // The text stays selected and the section now shows the fields.
      expect(c.st.selection, {'T'});
      expect(_dropdown('Lyrics audio track'), findsOneWidget);
      expect(find.textContaining('Set on the frame'), findsOneWidget);
      // One undo step takes the wrapper away.
      expect(c.ctl.undo(), isTrue);
      expect(_parentOf(c, 'T').id, 'A');
    });

    testWidgets('Lyrics is disabled without audio, with a hint', (
      tester,
    ) async {
      final c = await _pump(tester);
      c.ctl.execute(const RemoveAudioTrack('au1'));
      c.ctl.execute(const RemoveAudioTrack('au2'));
      await tester.pumpAndSettle();
      expect(tester.widget<SsButton>(_button('Lyrics')).onPressed, isNull);
      expect(find.textContaining('Lyrics needs audio'), findsOneWidget);
      expect(
        tester.widget<SsButton>(_button('Text reveal')).onPressed,
        isNotNull,
      );
    });

    testWidgets('Text reveal wraps the text and starts on the timeline', (
      tester,
    ) async {
      final c = await _pump(tester);
      await tester.tap(_button('Text reveal'));
      await tester.pumpAndSettle();
      final b = _parentOf(c, 'T').behavior! as ir.TextRevealBehavior;
      expect(b.clockId, 'tl');
      expect(b.unit, ir.TextRevealUnit.word);
      // The range spans the whole timeline.
      expect((b.range.start, b.range.end), (0.0, 6.0));
      expect(_dropdown('Reveal clock'), findsOneWidget);
    });

    testWidgets('Text reveal falls back to the scene scroll clock', (
      tester,
    ) async {
      final base = _doc();
      final s1 = base.scenes.first;
      final doc = base.copyWith(
        scenes: [
          s1.copyWith(
            clocks: [
              for (final k in s1.clocks)
                if (k is ir.SceneScrollClock) k,
            ],
          ),
          base.scenes[1],
        ],
      );
      final c = await _pump(tester, doc: doc);
      await tester.tap(_button('Text reveal'));
      await tester.pumpAndSettle();
      final b = _parentOf(c, 'T').behavior! as ir.TextRevealBehavior;
      expect(b.clockId, 'clk1');
      expect((b.range.start, b.range.end), (0.0, 1.0));
    });
  });

  group('Lyrics fields', () {
    Future<ProviderContainer> open(WidgetTester tester) async {
      final c = await _pump(tester);
      await tester.tap(_button('Lyrics'));
      await tester.pumpAndSettle();
      return c;
    }

    testWidgets('pick the audio track', (tester) async {
      final c = await open(tester);
      final frame = _parentOf(c, 'T').id;
      await _choose(tester, 'Lyrics audio track', 'Rain.wav');
      expect((_behaviorOf(c, frame)! as ir.LyricsBehavior).audioTrackId, 'au2');
      // au2 has no lyrics: the section says so.
      expect(find.textContaining('has no lyrics yet'), findsOneWidget);
    });

    testWidgets('scroll mode', (tester) async {
      final c = await open(tester);
      final frame = _parentOf(c, 'T').id;
      await tester.tap(
        find.descendant(
          of: find.byType(SsSegmented<ir.LyricsScrollMode>),
          matching: find.text('Top'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        (_behaviorOf(c, frame)! as ir.LyricsBehavior).scrollMode,
        ir.LyricsScrollMode.top,
      );
    });

    testWidgets('active and inactive styles take weight and size, and can '
        'inherit again', (tester) async {
      final c = await open(tester);
      final frame = _parentOf(c, 'T').id;
      await _type(tester, 'Active weight', '700');
      await _type(tester, 'Active size', '32');
      await _type(tester, 'Inactive size', '20');
      var b = _behaviorOf(c, frame)! as ir.LyricsBehavior;
      expect(b.activeStyle.fontWeight, 700);
      expect(b.activeStyle.fontSize, 32);
      expect(b.inactiveStyle.fontSize, 20);
      expect(b.inactiveStyle.fontWeight, isNull);
      await tester.tap(find.bySemanticsLabel('Inherit Active weight'));
      await tester.pumpAndSettle();
      b = _behaviorOf(c, frame)! as ir.LyricsBehavior;
      expect(b.activeStyle.fontWeight, isNull);
      expect(b.activeStyle.fontSize, 32);
    });

    testWidgets('the colour field sets a solid fill', (tester) async {
      final c = await open(tester);
      final frame = _parentOf(c, 'T').id;
      final field = find.byWidgetPredicate(
        (w) => w is SsColorField && w.semanticLabel == 'Active colour',
      );
      await tester.tap(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(of: field, matching: find.byType(EditableText)),
        'FF0000',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final fills =
          (_behaviorOf(c, frame)! as ir.LyricsBehavior).activeStyle.fills!;
      expect(fills.single, isA<ir.SolidPaint>());
      expect((fills.single as ir.SolidPaint).color.r, closeTo(1, 1e-6));
    });

    testWidgets('Remove behaviour clears it, keeping the wrapper', (
      tester,
    ) async {
      final c = await open(tester);
      final frame = _parentOf(c, 'T').id;
      await tester.tap(find.bySemanticsLabel('Remove behaviour'));
      await tester.pumpAndSettle();
      expect(_behaviorOf(c, frame), isNull);
      expect(_parentOf(c, 'T').id, frame);
      // The setup buttons are back.
      expect(_button('Lyrics'), findsOneWidget);
    });
  });

  group('Text reveal fields', () {
    Future<ProviderContainer> open(WidgetTester tester) async {
      final c = await _pump(tester);
      await tester.tap(_button('Text reveal'));
      await tester.pumpAndSettle();
      return c;
    }

    ir.TextRevealBehavior reveal(ProviderContainer c) =>
        _parentOf(c, 'T').behavior! as ir.TextRevealBehavior;

    testWidgets('unit and stagger', (tester) async {
      final c = await open(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(SsSegmented<ir.TextRevealUnit>),
          matching: find.text('Letter'),
        ),
      );
      await tester.pumpAndSettle();
      expect(reveal(c).unit, ir.TextRevealUnit.char);
      await _type(tester, 'Reveal stagger', '0.2');
      expect(reveal(c).stagger, closeTo(0.2, 1e-9));
    });

    testWidgets('range From and To follow the clock', (tester) async {
      final c = await open(tester);
      await _type(tester, 'Reveal from', '1.5');
      await _type(tester, 'Reveal to', '4');
      expect((reveal(c).range.start, reveal(c).range.end), (1.5, 4.0));
      // Values clamp into the clock's span (the timeline is 6 s).
      await _type(tester, 'Reveal to', '99');
      expect(reveal(c).range.end, 6);
    });

    testWidgets('another clock of another kind restarts the range', (
      tester,
    ) async {
      final c = await open(tester);
      await _type(tester, 'Reveal to', '3');
      await _choose(tester, 'Reveal clock', 'Scene scroll');
      expect(reveal(c).clockId, 'clk1');
      expect((reveal(c).range.start, reveal(c).range.end), (0.0, 1.0));
      // The audio clock spans its track (90 s).
      await _choose(tester, 'Reveal clock', 'Audio');
      expect(reveal(c).clockId, 'aclk');
      expect((reveal(c).range.start, reveal(c).range.end), (0.0, 90.0));
    });

    testWidgets('the same kind of clock keeps the range', (tester) async {
      final base = _doc();
      final s1 = base.scenes.first;
      final doc = base.copyWith(
        scenes: [
          s1.copyWith(
            clocks: [
              ...s1.clocks,
              const ir.Clock.timeline(id: 'tl2', duration: 10, name: 'Outro'),
            ],
          ),
          base.scenes[1],
        ],
      );
      final c = await _pump(tester, doc: doc);
      await tester.tap(_button('Text reveal'));
      await tester.pumpAndSettle();
      await _type(tester, 'Reveal from', '2');
      await _choose(tester, 'Reveal clock', 'Outro');
      expect(reveal(c).clockId, 'tl2');
      expect(reveal(c).range.start, 2);
    });

    testWidgets('a change is one undo step; remove undoes too', (tester) async {
      final c = await open(tester);
      final before = c.doc;
      await _type(tester, 'Reveal stagger', '0.3');
      expect(c.ctl.undo(), isTrue);
      expect(reveal(c).stagger, 0.05);
      expect(c.ctl.redo(), isTrue);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Remove behaviour'));
      await tester.pumpAndSettle();
      expect(_parentOf(c, 'T').behavior, isNull);
      expect(identical(before, c.doc), isFalse);
    });
  });

  group('other selections', () {
    testWidgets('a text inside a TextReveal frame shows that frame\'s '
        'behaviour', (tester) async {
      final c = await _pump(tester, select: 'A');
      // Select the frame A and give it a reveal; T is inside.
      await tester.tap(_button('Text reveal'));
      await tester.pumpAndSettle();
      expect(_behaviorOf(c, 'A'), isA<ir.TextRevealBehavior>());
      expect(_parentOf(c, 'T').id, 'A', reason: 'a frame is set up directly');
      c.ctl.select({'T'});
      await tester.pumpAndSettle();
      expect(find.textContaining('Set on the frame'), findsOneWidget);
      expect(_dropdown('Reveal clock'), findsOneWidget);
      // Removing from the text removes it from the frame.
      await tester.tap(find.bySemanticsLabel('Remove behaviour'));
      await tester.pumpAndSettle();
      expect(_behaviorOf(c, 'A'), isNull);
    });

    testWidgets('a frame with Lyrics drives only its direct text', (
      tester,
    ) async {
      final c = await _pump(tester, select: 'A');
      await tester.tap(_button('Lyrics'));
      await tester.pumpAndSettle();
      expect(_behaviorOf(c, 'A'), isA<ir.LyricsBehavior>());
      c.ctl.select({'T'});
      await tester.pumpAndSettle();
      expect(find.textContaining('Set on the frame'), findsOneWidget);
      // A21 is a shape in a deeper frame; a text there is not driven.
      expect(drivingFrameId(c, 'T'), 'A');
    });

    testWidgets('a frame with another behaviour shows it and can remove it', (
      tester,
    ) async {
      final c = await _pump(tester, select: 'B');
      c.ctl.execute(const SetBehavior('B', ir.Behavior.carousel()));
      await tester.pumpAndSettle();
      expect(find.text('Carousel'), findsOneWidget);
      expect(_button('Lyrics'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Remove behaviour'));
      await tester.pumpAndSettle();
      expect(_behaviorOf(c, 'B'), isNull);
    });

    testWidgets('shapes, several layers and scene roots have no section', (
      tester,
    ) async {
      final c = await _pump(tester, select: 'A1');
      expect(find.text('Behaviour'), findsNothing);
      c.ctl.select({'T', 'B'});
      await tester.pumpAndSettle();
      expect(find.text('Behaviour'), findsNothing);
      c.ctl.select({'root'});
      await tester.pumpAndSettle();
      expect(find.text('Behaviour'), findsNothing);
    });
  });

  testWidgets('the section lays out at the narrowest inspector width (240)', (
    tester,
  ) async {
    // A frame, so the Text section (which needs more room) is not there.
    final c = await _pump(tester, select: 'B', width: 240);
    await tester.tap(_button('Lyrics'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_dropdown('Lyrics audio track'), findsOneWidget);
    c.ctl.undo();
    await tester.pumpAndSettle();
    await tester.tap(_button('Text reveal'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_dropdown('Reveal clock'), findsOneWidget);
  });
}

String? drivingFrameId(ProviderContainer c, String textId) {
  final doc = c.doc;
  final index = ir.DocumentIndex.of(doc);
  final loc = index.locate(textId)!;
  for (final id in loc.ancestorIds.reversed) {
    final n = index.node(id);
    if (n is ir.FrameNode &&
        (n.behavior is ir.TextRevealBehavior ||
            (n.behavior is ir.LyricsBehavior && id == loc.parentId))) {
      return id;
    }
  }
  return null;
}
