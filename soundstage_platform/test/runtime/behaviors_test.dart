import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

const Size _viewport = Size(800, 600);

const ir.Breakpoint _bp = ir.Breakpoint(
  id: 'only',
  name: 'Only',
  minWidth: 0,
  designSize: ir.StageSize(width: 800, height: 600),
);

ir.TextNode _text(String id, String text, {double y = 0, double size = 20}) =>
    ir.TextNode(
      common: ir.NodeCommon(id: id, y: y, width: 600),
      autoResize: ir.TextAutoResize.height,
      style: ir.TextStyleOverride(fontSize: size),
      content: [
        for (final p in text.split('\n'))
          ir.Paragraph(spans: [ir.Span(text: p)]),
      ],
    );

ir.StageDocument _doc(
  ir.FrameNode frame, {
  List<ir.Clock> clocks = const [ir.Clock.timeline(id: 'tl', duration: 1)],
  List<ir.AudioTrack> audio = const [],
}) => ir.StageDocument(
  id: 'doc',
  breakpoints: const [_bp],
  baseBreakpointId: 'only',
  audioTracks: audio,
  scenes: [
    ir.Scene(
      id: 's',
      kind: ir.SceneKind.pinned,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 800, height: 600),
        children: [frame],
      ),
      clocks: clocks,
    ),
  ],
);

final Map<ir.StageDocument, StageEnvironment> _envs = Map.identity();

Future<void> _pump(
  WidgetTester tester,
  ir.StageDocument doc,
  Map<String, double> clocks,
) => tester.pumpWidget(
  Directionality(
    textDirection: TextDirection.ltr,
    child: StagePlayer(
      document: doc,
      mode: StageRenderMode.edit,
      viewportOverride: _viewport,
      clockOverrides: clocks,
      environment: _envs.putIfAbsent(
        doc,
        () => StageEnvironment.forDocument(doc),
      ),
    ),
  ),
);

/// Records which reveal units a member reports at what progress.
List<double> _progresses(RenderStageText t) {
  final r = t.reveal!..beginPaint();
  return [
    for (var i = 0; i < t.revealUnitCount(r.unit); i++) r.unitProgress(i),
  ];
}

void main() {
  group('TextReveal units and timing', () {
    test('char and word units skip whitespace and placeholders', () {
      String cut(String s, ir.TextRevealUnit u) => revealTextUnits(
        s,
        u,
      ).map((r) => s.substring(r.start, r.end)).join('|');
      expect(cut('  Hi there,\tyou ', ir.TextRevealUnit.word), 'Hi|there,|you');
      expect(cut('￼Ab c', ir.TextRevealUnit.word), 'Ab|c');
      expect(cut('a b', ir.TextRevealUnit.char), 'a|b');
      // Grapheme clusters stay whole.
      expect(cut('éx', ir.TextRevealUnit.char), 'é|x');
      expect(cut('👍🏽!', ir.TextRevealUnit.char), '👍🏽|!');
      expect(revealTextUnits('a b', ir.TextRevealUnit.line), isEmpty);
    });

    test('progress over the clock range', () {
      const r = ir.ClockRange(start: 0.2, end: 0.6);
      expect(revealProgress(r, 0), 0);
      expect(revealProgress(r, 0.4), closeTo(0.5, 1e-12));
      expect(revealProgress(r, 1), 1);
      const point = ir.ClockRange(start: 0.5, end: 0.5);
      expect(revealProgress(point, 0.49), 0);
      expect(revealProgress(point, 0.5), 1);
    });

    test('stagger timing fits the range', () {
      // 5 units, stagger 0.1: each lasts 0.6, the last starts at 0.4.
      final t = RevealTiming(5, 0.1);
      expect(t.duration, closeTo(0.6, 1e-12));
      expect(t.total, closeTo(1, 1e-12));
      expect(t.unit(0, 0), 0);
      expect(t.unit(0, 0.3), closeTo(0.5, 1e-12));
      expect(t.unit(1, 0.1), 0);
      expect(t.unit(4, 0.4), 0);
      expect(t.unit(4, 0.7), closeTo(0.5, 1e-12));
      expect(t.unit(4, 1), 1);
      expect(t.unit(0, 0.6), 1);
      // Stagger 0: everything together.
      final all = RevealTiming(4, 0);
      expect(
        [for (var i = 0; i < 4; i++) all.unit(i, 0.25)],
        [0.25, 0.25, 0.25, 0.25],
      );
      // A stagger too large for the range compresses time: units reveal one
      // after another and the last finishes at the range's end.
      final big = RevealTiming(10, 0.2);
      expect(big.duration, 0.2);
      expect(big.total, closeTo(2, 1e-12));
      expect(big.unit(9, 1), 1);
      expect(big.unit(9, 0.95), closeTo(0.5, 1e-9));
      expect(big.unit(0, 0.1), closeTo(1, 1e-9));
      // One unit spans the range.
      expect(RevealTiming(1, 0.3).unit(0, 0.5), 0.5);
    });

    test('the default look eases out', () {
      expect(revealEase(0), 0);
      expect(revealEase(1), 1);
      expect(revealEase(0.5), 0.875);
    });
  });

  group('TextReveal on stage', () {
    ir.FrameNode reveal(ir.TextRevealUnit unit, {double stagger = 0.1}) =>
        ir.FrameNode(
          common: const ir.NodeCommon(id: 'reveal', width: 800, height: 600),
          behavior: ir.Behavior.textReveal(
            clockId: 'tl',
            unit: unit,
            stagger: stagger,
          ),
          children: [
            _text('a', 'One two three'),
            _text('b', 'four five', y: 100),
          ],
        );

    testWidgets('units run across the frame’s texts in order', (tester) async {
      final doc = _doc(reveal(ir.TextRevealUnit.word));
      await _pump(tester, doc, {'tl': 0.5});
      final a = stageBox(tester, 'a') as RenderStageText;
      final b = stageBox(tester, 'b') as RenderStageText;
      expect(a.isRepaintBoundary, isTrue);
      final pa = _progresses(a), pb = _progresses(b);
      expect(pa.length, 3);
      expect(pb.length, 2);
      // 5 units, stagger 0.1, duration 0.6: unit i at (0.5 − 0.1 i) / 0.6.
      final all = [...pa, ...pb];
      for (var i = 0; i < 5; i++) {
        expect(all[i], closeTo((0.5 - 0.1 * i) / 0.6, 1e-9));
      }
    });

    testWidgets('changing the clock only repaints', (tester) async {
      final doc = _doc(reveal(ir.TextRevealUnit.line, stagger: 0));
      await _pump(tester, doc, {'tl': 0});
      RenderStageBox.debugLayoutCount = 0;
      RenderStageBox.debugPaintCount = 0;
      await _pump(tester, doc, {'tl': 0.5});
      expect(RenderStageBox.debugLayoutCount, 0);
      expect(RenderStageBox.debugPaintCount, greaterThan(0));
      final a = stageBox(tester, 'a') as RenderStageText;
      expect(_progresses(a), [0.5]);
    });
  });

  group('Lyrics', () {
    final lyrics = ir
        .parseLrc(
          '[00:01.00]<00:01.00>first <00:01.50>line<00:02.00>\n'
          '[00:03.00]second line\n[00:05.00]third line',
        )
        .doc;

    ir.FrameNode frame(ir.LyricsScrollMode mode) => ir.FrameNode(
      common: const ir.NodeCommon(id: 'lyrics', width: 800, height: 300),
      clipContent: true,
      behavior: ir.Behavior.lyrics(
        audioTrackId: 'song',
        scrollMode: mode,
        activeStyle: const ir.TextStyleOverride(
          fills: [ir.Paint.solid(id: 'i', color: ir.StageColor.white)],
        ),
        inactiveStyle: const ir.TextStyleOverride(
          fills: [
            ir.Paint.solid(id: 'i', color: ir.StageColor(r: .5, g: .5, b: .5)),
          ],
        ),
      ),
      children: [_text('template', 'x', y: 20, size: 30)],
    );

    ir.StageDocument doc(ir.LyricsScrollMode mode) => _doc(
      frame(mode),
      clocks: const [],
      audio: [ir.AudioTrack(id: 'song', assetId: 'clip', lyrics: lyrics)],
    );

    test('line mix fades in at the start and out after the end', () {
      expect(lyricLineMix(0.99, 1, 3), 0);
      expect(lyricLineMix(1, 1, 3), 0);
      expect(lyricLineMix(1 + kLyricsFade / 2, 1, 3), closeTo(0.5, 1e-9));
      expect(lyricLineMix(2.9, 1, 3), 1);
      expect(lyricLineMix(3 + kLyricsFade / 2, 1, 3), closeTo(0.5, 1e-9));
      expect(lyricLineMix(3 + kLyricsFade, 1, 3), 0);
      expect(lyricLineMix(100, 1, double.infinity), 1);
    });

    test('scroll eases between line targets', () {
      const targets = [0.0, 100.0, 300.0];
      expect(lyricsScrollOffset(lyrics, targets, 0), 0);
      expect(lyricsScrollOffset(lyrics, targets, 2.5), 0);
      expect(lyricsScrollOffset(lyrics, targets, 3), 0);
      expect(
        lyricsScrollOffset(lyrics, targets, 3 + kLyricsScroll / 2),
        closeTo(50, 1e-9),
      );
      expect(lyricsScrollOffset(lyrics, targets, 3 + kLyricsScroll), 100);
      expect(lyricsScrollOffset(lyrics, targets, 6), 300);
    });

    testWidgets('the template becomes a line stack driven by audio time', (
      tester,
    ) async {
      final d = doc(ir.LyricsScrollMode.center);
      await _pump(tester, d, {'__lyrics/lyrics': 0});
      final box = stageBox(tester, 'template') as RenderStageLyrics;
      expect(box.isRepaintBoundary, isTrue);
      expect(box.size.width, 600);
      expect(box.lineTop(1), greaterThan(box.lineTop(0)));
      // Before the first line: the first line is centred in the frame.
      final targets = box.scrollTargets();
      expect(targets.length, 3);
      expect(box.scrollOffset, targets[0]);
      // Line 1 centred once its scroll finishes.
      RenderStageBox.debugLayoutCount = 0;
      await _pump(tester, d, {'__lyrics/lyrics': 3 + kLyricsScroll});
      expect(box.time, 3 + kLyricsScroll);
      expect(box.scrollOffset, closeTo(targets[1], 1e-9));
      expect(RenderStageBox.debugLayoutCount, 0, reason: 'paint only');
      // Line 1's centre sits at the frame's centre (300 / 2).
      final l1 = box.lineTop(1);
      final l2 = box.lineTop(2);
      final centre = 20 + l1 + (l2 - l1) / 2 - box.scrollOffset;
      expect(centre, closeTo(150, 20));
    });

    testWidgets('cross-fades and word sweeps paint without errors', (
      tester,
    ) async {
      final d = doc(ir.LyricsScrollMode.center);
      for (final t in [0.0, 1.1, 1.25, 1.75, 2.1, 3.1, 4.0, 9.0]) {
        await _pump(tester, d, {'__lyrics/lyrics': t});
        expect(tester.takeException(), isNull, reason: 't = $t');
      }
    });

    test('lerpLyricStyle interpolates weight, size, spacing and colour', () {
      const a = ir.TextStyle(
        fontWeight: 300,
        fontSize: 20,
        letterSpacing: ir.LetterSpacing.px(0),
        fills: [ir.Paint.solid(id: 'i', color: ir.StageColor.black)],
      );
      const b = ir.TextStyle(
        fontWeight: 700,
        fontSize: 30,
        letterSpacing: ir.LetterSpacing.px(2),
        fills: [ir.Paint.solid(id: 'i', color: ir.StageColor.white)],
      );
      expect(lerpLyricStyle(a, b, 0).fontWeight, 300);
      expect(lerpLyricStyle(a, b, 1).fontWeight, 700);
      final m = lerpLyricStyle(a, b, 0.5);
      expect(m.fontWeight, 500);
      expect(m.fontSize, 25);
      expect(letterSpacingPx(m.letterSpacing, m.fontSize), closeTo(1, 1e-9));
      final fill = m.fills.single as ir.SolidPaint;
      expect(fill.color.r, inInclusiveRange(0.3, 0.7));
    });

    testWidgets('a line in transition paints once, in the mixed style', (
      tester,
    ) async {
      final d = doc(ir.LyricsScrollMode.center);
      // 3.125 s: line 0 is fading out and line 1 fading in (mix 0.5 each).
      await _pump(tester, d, {'__lyrics/lyrics': 3 + kLyricsFade / 2});
      final box = stageBox(tester, 'template') as RenderStageLyrics;
      // Three lines, plus the clipped sung overlay of the word-timed line 0.
      expect(box, paintsExactlyCountTimes(#drawParagraph, 4));
      // Steady state paints the same number: no second rendering anywhere.
      await _pump(tester, d, {'__lyrics/lyrics': 4});
      expect(box, paintsExactlyCountTimes(#drawParagraph, 3));
    });

    testWidgets('the viewport edges fade through a dstIn mask', (tester) async {
      final d = doc(ir.LyricsScrollMode.center);
      await _pump(tester, d, {'__lyrics/lyrics': 4});
      final box = stageBox(tester, 'template') as RenderStageLyrics;
      expect(box, paintsExactlyCountTimes(#drawRect, 1));
    });

    testWidgets('paints at its laid-out width after a dry layout elsewhere', (
      tester,
    ) async {
      await _pump(tester, doc(ir.LyricsScrollMode.top), {'__lyrics/lyrics': 0});
      final box = stageBox(tester, 'template') as RenderStageLyrics;
      final top1 = box.lineTop(1);
      // Measuring at another width must not leak into painting.
      box.getDryLayout(const BoxConstraints(maxWidth: 60));
      expect(box.lineTop(1), top1);
    });

    testWidgets('a missing lyrics doc renders nothing', (tester) async {
      final d = _doc(frame(ir.LyricsScrollMode.center), clocks: const []);
      await _pump(tester, d, {});
      final box = stageBox(tester, 'template') as RenderStageLyrics;
      expect(box.size.height, 0);
    });

    testWidgets('top and none scroll modes', (tester) async {
      await _pump(tester, doc(ir.LyricsScrollMode.top), {'__lyrics/lyrics': 6});
      var box = stageBox(tester, 'template') as RenderStageLyrics;
      expect(box.scrollOffset, box.lineTop(2));
      await _pump(tester, doc(ir.LyricsScrollMode.none), {
        '__lyrics/lyrics': 6,
      });
      box = stageBox(tester, 'template') as RenderStageLyrics;
      expect(box.scrollOffset, 0);
    });
  });
}

RenderStageBox stageBox(WidgetTester tester, String id) {
  RenderStageBox? found;
  void visit(RenderObject o) {
    if (found != null) return;
    if (o is RenderStageBox && o.nodeId == id) {
      found = o;
      return;
    }
    o.visitChildren(visit);
  }

  tester.binding.renderViews.forEach(visit);
  return found!;
}
