// Text mapping (architecture §7). The test font draws every glyph as a
// 1 em square, so widths are exact: n glyphs at 10 px are 10n px wide.

import 'package:flutter/painting.dart' as painting;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

ir.ResolvedParagraph para(
  List<ir.ResolvedSpan> spans, {
  double spacing = 0,
  double indent = 0,
  ir.ListStyle list = ir.ListStyle.none,
  ir.TextAlignHorizontal align = ir.TextAlignHorizontal.left,
}) => ir.ResolvedParagraph(
  spans: spans,
  alignHorizontal: align,
  paragraphSpacing: spacing,
  paragraphIndent: indent,
  listStyle: list,
);

ir.ResolvedSpan span(
  String text, [
  ir.TextStyle style = const ir.TextStyle(fontSize: 10),
]) => ir.ResolvedSpan(text: text, style: style);

StageTextLayout layoutOf(
  List<ir.ResolvedParagraph> paragraphs, {
  StageTextSettings settings = const StageTextSettings(),
  double? width,
  double? boxHeight,
}) {
  final l = StageTextLayout(
    paragraphs: paragraphs,
    fonts: StageFontTable.none,
    settings: settings,
  )..layout(width: width, boxHeight: boxHeight);
  addTearDown(l.dispose);
  return l;
}

String plainText(StageTextLayout l) =>
    l.visiblePainters.map((p) => p.plainText).join('\n');

void main() {
  group('style mapping', () {
    test('line height: auto → null, percent → v/100, px → v/fontSize', () {
      expect(lineHeightMultiplier(const ir.LineHeight.auto(), 16), isNull);
      expect(lineHeightMultiplier(const ir.LineHeight.percent(150), 16), 1.5);
      expect(lineHeightMultiplier(const ir.LineHeight.px(24), 16), 1.5);
      expect(lineHeightMultiplier(const ir.LineHeight.px(24), 0), isNull);
    });

    test('letter spacing: percent of the font size, px as is', () {
      expect(letterSpacingPx(const ir.LetterSpacing.percent(10), 20), 2);
      expect(letterSpacingPx(const ir.LetterSpacing.px(3), 20), 3);
    });

    test('text case is applied before layout', () {
      expect(applyTextCase('Hello world', ir.TextCase.upper), 'HELLO WORLD');
      expect(applyTextCase('Hello World', ir.TextCase.lower), 'hello world');
      expect(applyTextCase('the old  sea', ir.TextCase.title), 'The Old  Sea');
      expect(
        applyTextCase('ld war', ir.TextCase.title, startsWord: false),
        'ld War',
      );
      expect(applyTextCase('Hi', ir.TextCase.smallCaps), 'Hi');
    });

    test('a style maps every field', () {
      final s = stageTextStyle(
        const ir.TextStyle(
          fontFamilyId: 'serif',
          fontWeight: 450,
          italic: true,
          fontSize: 20,
          lineHeight: ir.LineHeight.percent(120),
          letterSpacing: ir.LetterSpacing.percent(-2),
          textCase: ir.TextCase.smallCaps,
          openType: {'tnum': 1, 'ss01': 1, 'bad': 1},
          fontVariations: {'wght': 450, 'opsz': 20},
          baselineShift: ir.BaselineShift.superscript,
          decoration: ir.TextDecoration(
            kind: ir.TextDecorationKind.underline,
            style: ir.TextDecorationStyle.wavy,
            thickness: 2.5,
            color: ir.StageColor(r: 1, g: 0, b: 0),
          ),
          fills: [
            ir.Paint.solid(id: 'h', color: ir.StageColor.white, visible: false),
            ir.Paint.solid(
              id: 'v',
              color: ir.StageColor(r: 0, g: 0, b: 1),
              opacity: 0.5,
            ),
          ],
        ),
        StageFontTable(const {
          'serif': ir.FontFamily(
            id: 'serif',
            name: 'Fraunces',
            fallback: ir.FontFallback.serif,
          ),
        }),
      );
      // Not loaded (no faces): the generic fallback (fonts_test covers
      // loaded families).
      expect(s.fontFamily, 'serif');
      expect(s.fontWeight, const FontWeight(450));
      expect(s.fontStyle, FontStyle.italic);
      expect(s.fontSize, 20);
      expect(s.height, 1.2);
      expect(s.letterSpacing, closeTo(-0.4, 1e-12));
      expect(s.leadingDistribution, painting.TextLeadingDistribution.even);
      expect(s.fontFeatures, [
        const FontFeature('tnum'),
        const FontFeature('ss01'),
        const FontFeature.enable('smcp'),
        const FontFeature.superscripts(),
      ]);
      expect(s.fontVariations, [
        const FontVariation('wght', 450),
        const FontVariation('opsz', 20),
      ]);
      expect(s.decoration, painting.TextDecoration.underline);
      expect(s.decorationStyle, painting.TextDecorationStyle.wavy);
      expect(s.decorationColor, const Color(0xFFFF0000));
      // 2.5 px over an assumed 20/16 px font thickness.
      expect(s.decorationThickness, 2);
      expect(s.color, const Color.from(alpha: 0.5, red: 0, green: 0, blue: 1));
    });

    test('fonts fall back to the default family when unknown', () {
      final fonts = StageFontTable();
      expect(fonts.familyName('missing'), isNull);
      expect(fonts.fallback('missing'), ir.FontFallback.sans);
      expect(
        stageTextStyle(
          const ir.TextStyle(fontFamilyId: 'missing'),
          fonts,
        ).fontFamily,
        isNull,
      );
    });
  });

  group('layout', () {
    test('widthAndHeight hugs both axes without wrapping', () {
      final l = layoutOf([
        para([span('abc def')]),
      ]);
      expect(l.size, const Size(70, 10));
    });

    test('a given width wraps', () {
      final l = layoutOf([
        para([span('abc def')]),
      ], width: 40);
      expect(l.size, const Size(40, 20));
    });

    test('letter spacing percent widens the run', () {
      const style = ir.TextStyle(
        fontSize: 10,
        letterSpacing: ir.LetterSpacing.percent(50),
      );
      final l = layoutOf([
        para([span('ab', style)]),
      ]);
      expect(l.size.width, 30);
    });

    test('line height px sets each line', () {
      const style = ir.TextStyle(
        fontSize: 10,
        lineHeight: ir.LineHeight.px(24),
      );
      final l = layoutOf([
        para([span('abc def', style)]),
      ], width: 40);
      expect(l.size.height, 48);
    });

    test('line height percent sets each line', () {
      const style = ir.TextStyle(
        fontSize: 10,
        lineHeight: ir.LineHeight.percent(200),
      );
      expect(
        layoutOf([
          para([span('a', style)]),
        ]).size.height,
        20,
      );
    });

    test('even leading centres the glyphs: the baseline moves by half', () {
      const tall = ir.TextStyle(fontSize: 10, lineHeight: ir.LineHeight.px(30));
      final natural = layoutOf([
        para([span('a')]),
      ]);
      final spaced = layoutOf([
        para([span('a', tall)]),
      ]);
      final delta = (30 - natural.size.height) / 2;
      expect(
        spaced.firstBaseline(30)!,
        closeTo(natural.firstBaseline(natural.size.height)! + delta, 1e-6),
      );
    });

    test('paragraph spacing stacks paragraphs', () {
      final l = layoutOf([
        para([span('a')], spacing: 8),
        para([span('b')], spacing: 99),
      ]);
      expect(l.size.height, 28); // 10 + 8 + 10; no spacing after the last
    });

    test('paragraph indent indents the first line only', () {
      final l = layoutOf([
        para([span('abc')], indent: 20),
      ]);
      expect(l.size.width, 50);
      final wrapped = layoutOf([
        para([span('ab cd')], indent: 20),
      ], width: 40);
      expect(wrapped.size.height, 20); // "ab" after the indent, then "cd"
    });

    test('text case reaches the painter', () {
      const upper = ir.TextStyle(fontSize: 10, textCase: ir.TextCase.upper);
      const title = ir.TextStyle(fontSize: 10, textCase: ir.TextCase.title);
      final l = layoutOf([
        para([span('big ', upper), span('little words', title)]),
      ]);
      expect(plainText(l), 'BIG Little Words');
    });

    test('list markers hang in a gutter; ordered lists count', () {
      final l = layoutOf([
        para([span('one')], list: ir.ListStyle.ordered),
        para([span('two')], list: ir.ListStyle.ordered),
        para([span('dot')], list: ir.ListStyle.unordered),
      ]);
      // Gutter = max(1.5 em, marker + 0.5 em) = max(15, 20 + 5) for "1.".
      expect(l.size.width, 25 + 30);
    });

    test('truncate: lines past maxLines become an ellipsis', () {
      final l = layoutOf(
        [
          para([span('aaa bbb ccc ddd')]),
          para([span('dropped')]),
        ],
        width: 40,
        settings: const StageTextSettings(
          autoResize: ir.TextAutoResize.height,
          truncation: ir.TextTruncation.ending,
          maxLines: 2,
        ),
      );
      expect(l.size.height, 20);
      expect(l.visiblePainters.length, 1);
      expect(l.visiblePainters.single.didExceedMaxLines, isTrue);
    });

    test('truncate: the box height limits lines', () {
      final l = layoutOf(
        [
          para([span('aaa bbb ccc ddd')]),
        ],
        width: 40,
        boxHeight: 25,
        settings: const StageTextSettings(
          autoResize: ir.TextAutoResize.truncate,
        ),
      );
      expect(l.size.height, 20);
    });

    test('without truncation every line shows', () {
      final l = layoutOf(
        [
          para([span('aaa bbb ccc ddd')]),
        ],
        width: 40,
        boxHeight: 25,
        settings: const StageTextSettings(
          autoResize: ir.TextAutoResize.fixed,
          maxLines: 1,
        ),
      );
      expect(l.size.height, 40);
    });

    test('alignVertical offsets the block in its box', () {
      for (final (align, offset) in [
        (ir.TextAlignVertical.top, 0.0),
        (ir.TextAlignVertical.middle, 20.0),
        (ir.TextAlignVertical.bottom, 40.0),
      ]) {
        final l = layoutOf([
          para([span('a')]),
        ], settings: StageTextSettings(alignVertical: align));
        expect(l.alignOffset(50), offset);
      }
    });
  });

  group('auto-resize on the render object', () {
    Future<RenderStageText> pumpText(
      WidgetTester tester,
      ir.TextNode node,
    ) async {
      final root = frame(
        'root',
        common('root', w: 1440, h: 900),
        children: [node],
      );
      await pumpScene(
        tester,
        docWithRoot(root),
        viewport: const Size(1440, 900),
      );
      return stageBox(tester, node.id) as RenderStageText;
    }

    ir.NodeCommon box(String id) => common(id, w: 40, h: 30);

    testWidgets('widthAndHeight hugs', (tester) async {
      final t = await pumpText(
        tester,
        textNode('t', text: 'abc def', nodeCommon: box('t')),
      );
      expect(t.size, const Size(70, 10));
    });

    testWidgets('height wraps at the stored width and hugs height', (
      tester,
    ) async {
      final t = await pumpText(
        tester,
        textNode(
          't',
          text: 'abc def ghi',
          autoResize: ir.TextAutoResize.height,
          nodeCommon: box('t'),
        ),
      );
      expect(t.size, const Size(40, 30));
    });

    testWidgets('fixed keeps the stored box and overflows', (tester) async {
      final t = await pumpText(
        tester,
        textNode(
          't',
          text: 'abc def ghi jkl',
          autoResize: ir.TextAutoResize.fixed,
          nodeCommon: box('t'),
        ),
      );
      expect(t.size, const Size(40, 30));
      expect(t.textLayout.size.height, 40);
    });

    testWidgets('truncate keeps the box and cuts at its height', (
      tester,
    ) async {
      final t = await pumpText(
        tester,
        textNode(
          't',
          text: 'abc def ghi jkl',
          autoResize: ir.TextAutoResize.truncate,
          nodeCommon: box('t'),
        ),
      );
      expect(t.size, const Size(40, 30));
      expect(t.textLayout.size.height, 30);
      expect(t.textLayout.visiblePainters.single.didExceedMaxLines, isTrue);
    });

    testWidgets('truncate with maxLines', (tester) async {
      final t = await pumpText(
        tester,
        textNode(
          't',
          text: 'abc def ghi jkl',
          autoResize: ir.TextAutoResize.truncate,
          maxLines: 1,
          nodeCommon: box('t'),
        ),
      );
      expect(t.textLayout.size.height, 10);
    });

    testWidgets('first baseline is exposed', (tester) async {
      final t = await pumpText(tester, textNode('t', text: 'a', fontSize: 20));
      final p = t.textLayout.visiblePainters.first;
      expect(
        t.firstBaseline,
        p.computeDistanceToActualBaseline(TextBaseline.alphabetic),
      );
      expect(
        t.getDryBaseline(BoxConstraints.tight(t.size), TextBaseline.alphabetic),
        t.firstBaseline,
      );
    });
  });
}
