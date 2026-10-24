// In-place text editing geometry (T1.8). The test font draws every glyph as
// a 1 em square, so at 10 px a glyph is 10 × 10 and positions are exact.

import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';
import 'text_test.dart' show layoutOf, para, span;

StageTextEditingGeometry geo(
  List<ir.ResolvedParagraph> paras, {
  double? width,
  double boxHeight = 0,
  StageTextSettings settings = const StageTextSettings(),
}) => StageTextEditingGeometry(
  layoutOf(paras, width: width, settings: settings),
  boxHeight,
);

void main() {
  group('hit testing (point → offset)', () {
    test('a plain line maps to the nearest caret position', () {
      final g = geo([
        para([span('Hello world')]),
      ]);
      expect(g.positionAt(const Offset(23, 5)), (0, 2));
      expect(g.positionAt(const Offset(27, 5)), (0, 3));
      expect(g.positionAt(const Offset(-50, 5)), (0, 0));
      expect(g.positionAt(const Offset(500, 5)), (0, 11));
      // Above and below the text clamp to its first/last line.
      expect(g.positionAt(const Offset(27, -40)), (0, 3));
      expect(g.positionAt(const Offset(27, 400)), (0, 3));
    });

    test('paragraphs: by y, the nearer one across the spacing gap', () {
      final g = geo([
        para([span('abc')], spacing: 20),
        para([span('defg')]),
      ]);
      // Paragraph 0: y 0–10; gap 10–30; paragraph 1: 30–40.
      expect(g.positionAt(const Offset(15, 5)), (0, 2));
      expect(g.positionAt(const Offset(15, 14)), (0, 2));
      expect(g.positionAt(const Offset(15, 26)), (1, 2));
      expect(g.positionAt(const Offset(35, 35)), (1, 4));
    });

    test('indent and list gutters shift the text', () {
      final indented = geo([
        para([span('abc')], indent: 20),
      ]);
      expect(indented.positionAt(const Offset(22, 5)), (0, 0));
      expect(indented.positionAt(const Offset(28, 5)), (0, 1));
      expect(indented.caretRect(0, 0, width: 0).left, 20);
      final list = geo([
        para([span('abc')], list: ir.ListStyle.unordered),
      ]);
      // Gutter: max(1.5 em, marker + 0.5 em) = 15.
      expect(list.caretRect(0, 0, width: 0).left, 15);
      expect(list.positionAt(const Offset(27, 5)), (0, 1));
    });

    test('justified text: positions follow the stretched spaces', () {
      final g = geo([
        para([span('aa b cc')], align: ir.TextAlignHorizontal.justified),
      ], width: 45);
      // Line 1 "aa b" stretches to 45: "b" sits at 35–45.
      expect(g.caretRect(0, 3, width: 0).left, closeTo(35, 0.01));
      expect(g.caretRect(0, 4, width: 0).left, closeTo(45, 0.01));
      expect(g.positionAt(const Offset(37, 5)), (0, 3));
      // Line 2.
      expect(g.positionAt(const Offset(12, 15)), (0, 6));
    });

    test('vertical alignment offsets the block', () {
      final g = geo(
        [
          para([span('abc')]),
        ],
        boxHeight: 100,
        settings: const StageTextSettings(
          autoResize: ir.TextAutoResize.fixed,
          alignVertical: ir.TextAlignVertical.middle,
        ),
        width: 100,
      );
      expect(g.caretRect(0, 0, width: 0).top, closeTo(45, 0.01));
      expect(g.positionAt(const Offset(15, 50)), (0, 2));
    });
  });

  group('caret and selection rects', () {
    test('the caret spans its line box, centred on the boundary', () {
      final g = geo([
        para([span('abc')], spacing: 5),
        para([span('de')]),
      ]);
      expect(g.caretRect(0, 2, width: 2), const Rect.fromLTWH(19, 0, 2, 10));
      expect(g.caretRect(1, 0, width: 2), const Rect.fromLTWH(-1, 15, 2, 10));
    });

    test('a soft line break: upstream is the end of the upper line', () {
      final g = geo([
        para([span('aa bb')]),
      ], width: 30);
      final down = g.caretRect(0, 3, width: 0);
      final up = g.caretRect(0, 3, width: 0, upstream: true);
      expect(down.top, 10);
      expect(up.top, 0);
      expect(g.lineBoundary(0, 1), (0, 3));
      expect(g.lineBoundary(0, 4), (3, 5));
    });

    test('a selection across paragraphs includes the break', () {
      final g = geo([
        para([span('abc')]),
        para([span('de')]),
      ]);
      final rects = g.selectionRects(0, 1, 1, 1);
      expect(rects, hasLength(3));
      expect(rects[0], const Rect.fromLTRB(10, 0, 30, 10));
      expect(rects[1].left, 30); // the paragraph-break sliver
      expect(rects[2], const Rect.fromLTRB(0, 10, 10, 20));
    });

    test('an empty paragraph has a caret and a break sliver', () {
      final g = geo([
        para([span('')]),
        para([span('x')]),
      ]);
      final c = g.caretRect(0, 0, width: 0);
      expect(c.height, greaterThan(0));
      expect(g.selectionRects(0, 0, 1, 0), hasLength(1));
    });
  });

  test('text case: offsets map through the transformed text', () {
    // The VM's case mapping keeps lengths; browsers may not (`ß` → `SS`),
    // and the mapping is then proportional within the span.
    const upper = ir.TextStyle(fontSize: 10, textCase: ir.TextCase.upper);
    final l = layoutOf([
      para([span('ab', upper), span('c')], indent: 10),
    ]);
    final b = l.paragraphBox(0);
    expect(b.leadingUnits, 1);
    for (var o = 0; o <= 3; o++) {
      expect(toPainterOffset(b, o), o + 1);
      expect(toSourceOffset(b, o + 1), o);
    }
    expect(toSourceOffset(b, 0), 0);
  });

  test('document offsets ↔ paragraph points', () {
    final paras = [
      para([span('abc')]),
      para([span('de')]),
    ];
    expect(paragraphPointOf(paras, 4), (1, 0));
    expect(paragraphPointOf(paras, 99), (1, 2));
    expect(documentOffsetOf(paras, 1, 2), 6);
  });

  group('RenderStageText', () {
    testWidgets('edit mode reveals truncated text and paints the decoration', (
      tester,
    ) async {
      final doc = docWithRoot(
        frame(
          'root',
          common('root', w: 400, h: 400),
          children: [
            textNode(
              't',
              content: const [
                ir.Paragraph(spans: [ir.Span(text: 'one')]),
                ir.Paragraph(spans: [ir.Span(text: 'two')]),
              ],
              autoResize: ir.TextAutoResize.truncate,
              maxLines: 1,
              nodeCommon: common('t', x: 10, y: 10, w: 200, h: 40),
            ),
          ],
        ),
      );
      await pumpScene(tester, doc, viewport: const Size(400, 400));
      final t = stageBox(tester, 't') as RenderStageText;
      expect(t.textLayout.paragraphBox(1).visible, isFalse);
      final l0 = RenderStageBox.debugLayoutCount;
      t.editing = const StageTextEditing(
        selectionColor: Color(0x330000FF),
        caretColor: Color(0xFF0000FF),
        selection: (1, 5),
        caret: 5,
      );
      await tester.pump();
      expect(t.textLayout.paragraphBox(1).visible, isTrue);
      expect(t.size, const Size(200, 40)); // the box stays fixed
      expect(RenderStageBox.debugLayoutCount - l0, lessThanOrEqualTo(2));
      expect(t.textOffsetAt(const Offset(22, 15)), 6);
      expect(t.caretRectAt(5, width: 0).topLeft, const Offset(10, 10));
      expect(t.selectionRectsFor(1, 5), hasLength(3));
      // Moving the caret only repaints.
      final l1 = RenderStageBox.debugLayoutCount;
      final p1 = RenderStageBox.debugPaintCount;
      t.editing = const StageTextEditing(
        selectionColor: Color(0x330000FF),
        caretColor: Color(0xFF0000FF),
        caret: 2,
      );
      await tester.pump();
      expect(RenderStageBox.debugLayoutCount, l1);
      expect(RenderStageBox.debugPaintCount, greaterThan(p1));
      t.editing = null;
      await tester.pump();
      expect(t.textLayout.paragraphBox(1).visible, isFalse);
    });
  });
}
