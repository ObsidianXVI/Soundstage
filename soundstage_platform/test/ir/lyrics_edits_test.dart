import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _bps = [
  Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 1024,
    designSize: StageSize(width: 1000, height: 800),
    primary: true,
  ),
];

const _lines = [
  LyricLine(start: 1, text: 'one two', end: 3),
  LyricLine(
    start: 4,
    text: 'three four five',
    words: [
      LyricWord(start: 4, text: 'three', end: 5),
      LyricWord(start: 5, text: 'four'),
      LyricWord(start: 6, text: 'five', end: 7),
    ],
  ),
  LyricLine(start: 8, text: 'six'),
];

StageDocument _doc({LyricsDoc? lyrics = const LyricsDoc(lines: _lines)}) =>
    StageDocument(
      id: 'doc',
      breakpoints: _bps,
      assets: const {
        'a1': Asset(id: 'a1', kind: AssetKind.audio, uri: 'local://a1'),
      },
      audioTracks: [AudioTrack(id: 'au1', assetId: 'a1', lyrics: lyrics)],
    );

List<LyricLine> _of(EditResult r) => r.document.audioTracks.first.lyrics!.lines;

void main() {
  group('setLyrics / clearLyrics', () {
    test('imports a parsed document, sorted by start', () {
      final parsed = parseLrc('[00:05.00]b\n[00:01.00]a').doc;
      final r = setLyrics(_doc(lyrics: null), 'au1', parsed);
      expect(r.ok, isTrue);
      expect(_of(r).map((l) => l.text), ['a', 'b']);
    });

    test('replaces existing lyrics', () {
      final r = setLyrics(
        _doc(),
        'au1',
        const LyricsDoc(lines: [LyricLine(start: 0, text: 'new')]),
      );
      expect(_of(r).single.text, 'new');
    });

    test('rejects lines with bad times or no text, leaving the doc alone', () {
      final d = _doc();
      for (final bad in const [
        LyricLine(start: -1, text: 'x'),
        LyricLine(start: 2, text: 'x', end: 1),
        LyricLine(start: 1, text: '  '),
        LyricLine(
          start: 1,
          text: 'a b',
          words: [
            LyricWord(start: 2, text: 'a'),
            LyricWord(start: 1.5, text: 'b'),
          ],
        ),
      ]) {
        final r = setLyrics(d, 'au1', LyricsDoc(lines: [bad]));
        expect(r.ok, isFalse, reason: '$bad');
        expect(r.document, same(d));
      }
    });

    test('null, empty and clearLyrics clear', () {
      expect(
        setLyrics(_doc(), 'au1', null).document.audioTracks.first.lyrics,
        isNull,
      );
      expect(
        setLyrics(
          _doc(),
          'au1',
          const LyricsDoc(),
        ).document.audioTracks.first.lyrics,
        isNull,
      );
      final c = clearLyrics(_doc(), 'au1');
      expect(c.changed, isTrue);
      expect(clearLyrics(_doc(lyrics: null), 'au1').changed, isFalse);
    });

    test('an unknown track is an error', () {
      expect(setLyrics(_doc(), 'zz', null).ok, isFalse);
    });
  });

  group('updateLyricLine', () {
    test('edits the text of a line without words', () {
      final r = updateLyricLine(
        _doc(),
        'au1',
        0,
        (l) => l.copyWith(text: 'uno dos'),
      );
      expect(_of(r)[0].text, 'uno dos');
      expect(_of(r)[1], _lines[1]);
    });

    test('edits start and end, including clearing the end', () {
      var r = updateLyricLine(
        _doc(),
        'au1',
        0,
        (l) => l.copyWith(start: 2, end: 3.5),
      );
      expect((_of(r)[0].start, _of(r)[0].end), (2.0, 3.5));
      r = updateLyricLine(r.document, 'au1', 0, (l) => l.copyWith(end: null));
      expect(_of(r)[0].end, isNull);
    });

    test('keeps the word timings when the word count is unchanged', () {
      final r = updateLyricLine(
        _doc(),
        'au1',
        1,
        (l) => l.copyWith(text: 'THREE four  FIVE'),
      );
      expect(r.diagnostics, isEmpty);
      expect(_of(r)[1].words.map((w) => w.text), ['THREE', 'four', 'FIVE']);
      expect(_of(r)[1].words.map((w) => w.start), [4, 5, 6]);
    });

    test('drops word timings, with a warning, when the word count changes', () {
      final r = updateLyricLine(
        _doc(),
        'au1',
        1,
        (l) => l.copyWith(text: 'just two'),
      );
      expect(r.ok, isTrue);
      expect(_of(r)[1].words, isEmpty);
      expect(r.diagnostics.single.severity, IrSeverity.warning);
    });

    test('a start cannot pass a neighbour', () {
      final d = _doc();
      expect(
        updateLyricLine(d, 'au1', 0, (l) => l.copyWith(start: 4.5)).ok,
        isFalse,
      );
      expect(
        updateLyricLine(d, 'au1', 2, (l) => l.copyWith(start: 3)).ok,
        isFalse,
      );
      // Up to the neighbour is fine (equal starts keep their order).
      expect(
        updateLyricLine(d, 'au1', 0, (l) => l.copyWith(start: 4, end: 4.5)).ok,
        isTrue,
      );
      expect(
        updateLyricLine(d, 'au1', 2, (l) => l.copyWith(start: 100)).ok,
        isTrue,
      );
    });

    test('rejects bad indexes, end before start and no change', () {
      final d = _doc();
      expect(updateLyricLine(d, 'au1', 3, (l) => l).ok, isFalse);
      expect(updateLyricLine(d, 'au1', -1, (l) => l).ok, isFalse);
      expect(
        updateLyricLine(d, 'au1', 0, (l) => l.copyWith(end: 0.5)).ok,
        isFalse,
      );
      expect(
        updateLyricLine(d, 'au1', 0, (l) => l.copyWith(text: '')).ok,
        isFalse,
      );
      final noop = updateLyricLine(d, 'au1', 0, (l) => l);
      expect(noop.ok && !noop.changed, isTrue);
      expect(noop.document, same(d));
    });
  });

  group('moveLyricLine', () {
    test('shifts the end and every word with the start', () {
      final r = moveLyricLine(_doc(), 'au1', 1, 4.5);
      final l = _of(r)[1];
      expect(l.start, 4.5);
      expect(l.words.map((w) => w.start), [4.5, 5.5, 6.5]);
      expect(l.words.map((w) => w.end), [5.5, null, 7.5]);
      final m = moveLyricLine(_doc(), 'au1', 0, 0.5);
      expect((_of(m)[0].start, _of(m)[0].end), (0.5, 2.5));
    });

    test('clamps between the neighbours with a warning', () {
      final r = moveLyricLine(_doc(), 'au1', 1, 20);
      expect(_of(r)[1].start, 8);
      expect(r.diagnostics.single.severity, IrSeverity.warning);
      expect(_of(moveLyricLine(_doc(), 'au1', 1, -5))[1].start, 1);
    });

    test('is a no-op at the same start', () {
      expect(moveLyricLine(_doc(), 'au1', 1, 4).changed, isFalse);
    });
  });

  group('insert and remove', () {
    test('insertLyricLine keeps the order and reports the index', () {
      final r = insertLyricLine(
        _doc(),
        'au1',
        const LyricLine(start: 3.5, text: 'mid'),
      );
      expect(_of(r).map((l) => l.text), [
        'one two',
        'mid',
        'three four five',
        'six',
      ]);
      expect(r.createdIds, ['1']);
      final first = insertLyricLine(
        _doc(lyrics: null),
        'au1',
        const LyricLine(start: 2, text: 'only'),
      );
      expect(_of(first).single.text, 'only');
      expect(
        insertLyricLine(_doc(), 'au1', const LyricLine(start: 1, text: '')).ok,
        isFalse,
      );
    });

    test('removeLyricLine, and removing the last line clears the lyrics', () {
      final r = removeLyricLine(_doc(), 'au1', 1);
      expect(_of(r).map((l) => l.text), ['one two', 'six']);
      expect(removeLyricLine(_doc(), 'au1', 9).ok, isFalse);
      final one = _doc(
        lyrics: const LyricsDoc(lines: [LyricLine(start: 0, text: 'a')]),
      );
      expect(
        removeLyricLine(one, 'au1', 0).document.audioTracks.first.lyrics,
        isNull,
      );
    });
  });

  group('updateLyricWord', () {
    test('changes a word start and end', () {
      final r = updateLyricWord(
        _doc(),
        'au1',
        1,
        1,
        (w) => w.copyWith(start: 5.5, end: 5.9),
      );
      expect(r.ok, isTrue);
      expect(_of(r)[1].words[1].start, 5.5);
      expect(_of(r)[1].words[1].end, 5.9);
    });

    test('a word keeps its order and stays inside the line start', () {
      final d = _doc();
      expect(
        updateLyricWord(d, 'au1', 1, 1, (w) => w.copyWith(start: 6.5)).ok,
        isFalse,
      );
      expect(
        updateLyricWord(d, 'au1', 1, 1, (w) => w.copyWith(start: 3.9)).ok,
        isFalse,
      );
      expect(
        updateLyricWord(d, 'au1', 1, 1, (w) => w.copyWith(end: 4)).ok,
        isFalse,
      );
      expect(updateLyricWord(d, 'au1', 1, 5, (w) => w).ok, isFalse);
      expect(updateLyricWord(d, 'au1', 0, 0, (w) => w).ok, isFalse);
    });
  });

  test('bounds helpers describe what an edit accepts', () {
    const doc = LyricsDoc(lines: _lines);
    expect(lyricStartBounds(doc, 0), (min: 0.0, max: 4.0));
    expect(lyricStartBounds(doc, 1), (min: 1.0, max: 8.0));
    expect(lyricStartBounds(doc, 2).max, double.infinity);
    expect(lyricWordStartBounds(_lines[1], 0), (min: 4.0, max: 5.0));
    expect(lyricWordStartBounds(_lines[1], 1), (min: 4.0, max: 6.0));
    expect(lyricWordStartBounds(_lines[1], 2).max, double.infinity);
  });
}
