import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/text/rich_text_model.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _bold = TextStyleOverride(fontWeight: 700);
const _italic = TextStyleOverride(italic: true);

Paragraph _p(List<Span> spans, [ParagraphStyle? style]) =>
    Paragraph(spans: spans, style: style);

/// "Hello bold" / "world"
List<Paragraph> _doc() => [
  _p(const [Span(text: 'Hello '), Span(text: 'bold', style: _bold)]),
  _p(const [Span(text: 'world')], const ParagraphStyle(paragraphIndent: 8)),
];

/// The content as a compact string: `[text|fw]` spans, `/` between
/// paragraphs.
String _dump(List<Paragraph> c) => c
    .map(
      (p) => p.spans
          .map(
            (s) =>
                '[${s.text}${s.style.fontWeight != null ? '|${s.style.fontWeight}' : ''}'
                '${s.style.italic == true ? '|i' : ''}${s.link != null ? '|L' : ''}]',
          )
          .join(),
    )
    .join('/');

void _checkNormal(List<Paragraph> c) {
  expect(c, isNotEmpty);
  for (final p in c) {
    expect(p.spans, isNotEmpty, reason: 'every paragraph keeps a span');
    if (p.spans.length > 1) {
      for (final s in p.spans) {
        expect(s.text, isNotEmpty, reason: 'no empty spans beside text');
      }
    }
    for (var i = 1; i < p.spans.length; i++) {
      final a = p.spans[i - 1], b = p.spans[i];
      expect(
        a.style == b.style && a.link == b.link,
        isFalse,
        reason: 'adjacent equal spans are merged: ${_dump(c)}',
      );
    }
  }
}

void main() {
  group('offsets', () {
    test('document offset ↔ point, separators count one', () {
      final c = _doc();
      expect(documentLength(c), 10 + 1 + 5);
      expect(plainTextOf(c), 'Hello bold\nworld');
      expect(pointOf(c, 0), const TextPoint(0, 0));
      expect(pointOf(c, 10), const TextPoint(0, 10));
      expect(pointOf(c, 11), const TextPoint(1, 0));
      expect(pointOf(c, 16), const TextPoint(1, 5));
      expect(pointOf(c, 99), const TextPoint(1, 5));
      for (var o = 0; o <= 16; o++) {
        expect(offsetOf(c, pointOf(c, o)), o);
      }
      expect(paragraphStart(c, 1), 11);
    });

    test('locate: before/after at a span boundary', () {
      final c = _doc();
      final before = locate(c, 6)!;
      expect((before.span, before.offsetInSpan), (0, 6));
      final after = locate(c, 6, before: false)!;
      expect((after.span, after.offsetInSpan), (1, 0));
      expect(locate(c, 8)!.span, 1);
      expect(locate(c, 10)!.span, 1);
      expect(locate(c, 11)!.paragraph, 1);
    });

    test('typing style: the character before, after at a paragraph start', () {
      final c = _doc();
      expect(typingSpanAt(c, 6)!.span, 0); // after "Hello "
      expect(typingSpanAt(c, 7)!.span, 1); // inside "bold"
      expect(typingSpanAt(c, 10)!.span, 1); // end of "bold"
      final start = [
        _p(const [Span(text: 'B', style: _bold), Span(text: 'x')]),
      ];
      expect(typingSpanAt(start, 0)!.span, 0);
    });

    test('spansInRange clips to spans; an empty paragraph yields its span', () {
      final c = _doc();
      final r = spansInRange(c, 4, 13);
      expect(
        [for (final (ref, a, b) in r) '${ref.paragraph}.${ref.span}:$a-$b'],
        ['0.0:4-6', '0.1:0-4', '1.0:0-2'],
      );
      final empty = [
        _p(const [Span(text: '', style: _bold)]),
      ];
      expect(spansInRange(empty, 0, 0).single.$1, const SpanRef(0, 0));
      expect(paragraphsInRange(c, 3, 12), [0, 1]);
    });
  });

  group('replaceText', () {
    test('typing inherits the span before the caret', () {
      final e = replaceText(_doc(), 10, 10, '!');
      expect(_dump(e.content), '[Hello ][bold!|700]/[world]');
      final e2 = replaceText(_doc(), 6, 6, 'x');
      expect(_dump(e2.content), '[Hello x][bold|700]/[world]');
    });

    test('a replaced range takes the style of its first character', () {
      final e = replaceText(_doc(), 6, 10, 'BIG');
      expect(_dump(e.content), '[Hello ][BIG|700]/[world]');
    });

    test('Enter splits a paragraph; the paragraph style carries over', () {
      final c = _doc();
      final e = replaceText(c, 13, 13, '\n');
      expect(_dump(e.content), '[Hello ][bold|700]/[wo]/[rld]');
      expect(e.content[1].style, c[1].style);
      expect(e.content[2].style, c[1].style);
      expect(e.paragraphOrigins, [0, 1, 1]);
    });

    test(
      'Enter at the end leaves an empty paragraph with the typing style',
      () {
        final e = replaceText(_doc(), 10, 10, '\n');
        expect(_dump(e.content), '[Hello ][bold|700]/[|700]/[world]');
        // Typing there is bold.
        final t = replaceText(e.content, 11, 11, 'x');
        expect(_dump(t.content), '[Hello ][bold|700]/[x|700]/[world]');
      },
    );

    test('Backspace at a paragraph start merges into the previous one', () {
      final c = _doc();
      final e = replaceText(c, 10, 11, '');
      expect(_dump(e.content), '[Hello ][bold|700][world]');
      expect(e.content.single.style, c[0].style);
    });

    test('deleting a whole paragraph keeps one empty styled span', () {
      final c = [
        _p(const [Span(text: 'abc', style: _bold)]),
      ];
      final e = replaceText(c, 0, 3, '');
      expect(_dump(e.content), '[|700]');
    });

    test('multi-line paste', () {
      final e = replaceText(_doc(), 6, 6, 'a\nb\nc');
      expect(_dump(e.content), '[Hello a]/[b]/[c][bold|700]/[world]');
    });

    test('typing inside a link extends it; at its end it does not', () {
      final c = [
        _p(const [
          Span(text: 'go '),
          Span(text: 'here', link: SpanLink.url('https://x.y')),
        ]),
      ];
      expect(_dump(replaceText(c, 5, 5, 'X').content), '[go ][heXre|L]');
      expect(_dump(replaceText(c, 7, 7, 'X').content), '[go ][here|L][X]');
    });

    test('origins: split halves and typed text keep the span origin', () {
      final e = replaceText(_doc(), 2, 2, '\n');
      expect(e.spanOrigins, [
        [const SpanRef(0, 0)],
        [const SpanRef(0, 0), const SpanRef(0, 1)],
        [const SpanRef(1, 0)],
      ]);
    });

    test('spans with different signatures do not merge', () {
      final c = [
        _p(const [Span(text: 'ab'), Span(text: 'cd', style: _bold)]),
      ];
      // Un-bolding "cd" makes the base styles equal; a mobile patch on span 1
      // keeps it apart.
      Object? sig(SpanRef? o) => o == const SpanRef(0, 1) ? 'patched' : null;
      final e = mapSpans(
        c,
        2,
        4,
        (s) => s.copyWith(style: const TextStyleOverride()),
        signature: sig,
      );
      expect(e.content.single.spans, hasLength(2));
      final merged = mapSpans(
        c,
        2,
        4,
        (s) => s.copyWith(style: const TextStyleOverride()),
      );
      expect(_dump(merged.content), '[abcd]');
    });
  });

  group('mapSpans / setLink', () {
    test('styling part of a span splits it minimally', () {
      final c = [
        _p(const [Span(text: 'abcdef')]),
      ];
      final e = mapSpans(c, 2, 4, (s) => s.copyWith(style: _bold));
      expect(_dump(e.content), '[ab][cd|700][ef]');
      expect(e.spanOrigins.single, [
        const SpanRef(0, 0),
        const SpanRef(0, 0),
        const SpanRef(0, 0),
      ]);
    });

    test('restyling to equal neighbours merges back', () {
      final c = [
        _p(const [
          Span(text: 'ab'),
          Span(text: 'cd', style: _bold),
          Span(text: 'ef'),
        ]),
      ];
      final e = mapSpans(
        c,
        2,
        4,
        (s) => s.copyWith(style: const TextStyleOverride()),
      );
      expect(_dump(e.content), '[abcdef]');
    });

    test('a range across paragraphs', () {
      final e = mapSpans(_doc(), 8, 13, (s) => s.copyWith(style: _italic));
      expect(_dump(e.content), '[Hello ][bo|700][ld|i]/[wo|i][rld]');
    });

    test('links', () {
      final e = setLink(_doc(), 0, 5, const SpanLink.url('https://a.b'));
      expect(_dump(e.content), '[Hello|L][ ][bold|700]/[world]');
      final off = setLink(e.content, 0, 5, null);
      expect(_dump(off.content), '[Hello ][bold|700]/[world]');
    });

    test('splitSpansAt is structural and identity when not needed', () {
      final c = _doc();
      expect(splitSpansAt(c, [0, 6, 10]).changed, isFalse);
      final s = splitSpansAt(c, [2]);
      expect(_dump(s.content), '[He][llo ][bold|700]/[world]');
      expect(normalise(s.content).content.first.spans, hasLength(2));
    });
  });

  group('words', () {
    test('wordAt, word boundaries', () {
      const t = 'Hello, wide world';
      expect(wordAt(t, 2), (0, 5));
      expect(wordAt(t, 5), (0, 5)); // end of a word: that word
      expect(wordAt(t, 9), (7, 11));
      expect(nextWordBoundary(t, 0), 5);
      expect(nextWordBoundary(t, 5), 11);
      expect(previousWordBoundary(t, 17), 12);
      expect(previousWordBoundary(t, 7), 0);
      expect(endsWord('abc', ' '), isTrue);
      expect(endsWord('abc', 'd'), isFalse);
      expect(endsWord('abc ', ' '), isFalse);
    });

    test('surrogate pairs move as one', () {
      const t = 'a😀b';
      expect(nextCharBoundary(t, 1), 3);
      expect(previousCharBoundary(t, 3), 1);
    });
  });

  test('property: random edit sequences keep the content normal and its '
      'text consistent', () {
    final rnd = Random(7);
    const styles = [
      TextStyleOverride(),
      _bold,
      _italic,
      TextStyleOverride(fontWeight: 700, italic: true),
    ];
    const alphabet = 'ab c\nd';
    for (var run = 0; run < 300; run++) {
      var content = _doc();
      var plain = plainTextOf(content);
      for (var step = 0; step < 40; step++) {
        final len = documentLength(content);
        expect(plain.length, len);
        final a = rnd.nextInt(len + 1);
        final b = (a + rnd.nextInt(4)).clamp(0, len);
        switch (rnd.nextInt(4)) {
          case 0 || 1:
            final n = rnd.nextInt(4);
            final text = String.fromCharCodes([
              for (var i = 0; i < n; i++)
                alphabet.codeUnitAt(rnd.nextInt(alphabet.length)),
            ]);
            final e = replaceText(content, a, b, text);
            content = e.content;
            plain = plain.replaceRange(a, b, text);
            expect(e.spanOrigins.length, content.length);
          case 2:
            final st = styles[rnd.nextInt(styles.length)];
            content = mapSpans(
              content,
              a,
              b,
              (s) => s.copyWith(style: st),
            ).content;
          default:
            content = setLink(
              content,
              a,
              b,
              rnd.nextBool() ? const SpanLink.url('https://l.k') : null,
            ).content;
        }
        expect(plainTextOf(content), plain, reason: 'run $run step $step');
        _checkNormal(content);
        // Round-trips through JSON.
        final json = [for (final p in content) p.toJson()];
        expect([for (final j in json) Paragraph.fromJson(j)], content);
      }
    }
  });
}
