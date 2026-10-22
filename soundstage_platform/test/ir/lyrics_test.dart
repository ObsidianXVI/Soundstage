import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

void main() {
  group('parseLrc', () {
    test('line times, fractions and metadata', () {
      final r = parseLrc(
        '﻿[ti:Song]\r\n[ar:Someone]\n[00:01.5]One\n[00:02.25]Two\n'
        '[01:03.125]Three\n[00:04]Four',
      );
      expect(r.diagnostics, isEmpty);
      expect(r.metadata, {'ti': 'Song', 'ar': 'Someone'});
      expect([for (final l in r.doc.lines) l.start], [1.5, 2.25, 4, 63.125]);
      expect(
        [for (final l in r.doc.lines) l.text],
        ['One', 'Two', 'Four', 'Three'],
      );
      expect(
        r.doc.lines.every((l) => l.end == null && l.words.isEmpty),
        isTrue,
      );
    });

    test('colon fraction variant', () {
      final r = parseLrc('[00:03:50]x');
      expect(r.doc.lines.single.start, 3.5);
    });

    test('several timestamps on one line', () {
      final r = parseLrc('[00:10.00][00:30.00]Chorus\n[00:20.00]Verse');
      expect(
        [for (final l in r.doc.lines) (l.start, l.text)],
        [(10.0, 'Chorus'), (20.0, 'Verse'), (30.0, 'Chorus')],
      );
    });

    test('offset shifts earlier, clamped at 0', () {
      final r = parseLrc('[offset:+500]\n[00:00.20]a\n[00:02.00]b');
      expect(r.offset, 0.5);
      expect([for (final l in r.doc.lines) l.start], [0, 1.5]);
      final neg = parseLrc('[offset:-250]\n[00:01.00]a');
      expect(neg.doc.lines.single.start, 1.25);
      expect(r.metadata.containsKey('offset'), isFalse);
    });

    test('empty timed line ends the previous line', () {
      final r = parseLrc('[00:01.00]a\n[00:03.00]\n[00:05.00]b');
      expect(r.doc.lines.length, 2);
      expect(r.doc.lines[0].end, 3);
      expect(r.doc.lines[1].end, isNull);
    });

    test('enhanced LRC word times', () {
      final r = parseLrc(
        '[offset:1000]\n[00:11.00]<00:11.00>Hello <00:11.50>bright <00:12.25>world<00:13.00>',
      );
      final l = r.doc.lines.single;
      expect(l.start, 10);
      expect(l.text, 'Hello bright world');
      expect(
        [for (final w in l.words) (w.text, w.start, w.end)],
        [
          ('Hello', 10.0, 10.5),
          ('bright', 10.5, 11.25),
          ('world', 11.25, 12.0),
        ],
      );
    });

    test('lead text before the first word time starts at the line', () {
      final l = parseLrc('[00:01.00]Oh <00:01.40>yes').doc.lines.single;
      expect(
        [for (final w in l.words) (w.text, w.start)],
        [('Oh', 1.0), ('yes', 1.4)],
      );
    });

    test('malformed lines produce diagnostics and never throw', () {
      final r = parseLrc(
        'plain text\n[00:99.00]bad seconds\n[00:01.00 unclosed\n'
        '[??]\n[offset:abc]\n[00:02.00]ok\n[ti:x] trailing',
      );
      expect(r.doc.lines.single.text, 'ok');
      expect(r.diagnostics.length, 6);
      expect(
        r.diagnostics.every(
          (d) =>
              d.kind == IrDiagnosticKind.invalidLyrics &&
              d.severity == IrSeverity.warning,
        ),
        isTrue,
      );
      expect(r.diagnostics.first.message, contains('line 1'));
    });

    test('garbage input', () {
      for (final s in ['', '[', ']]]', '[:]', '<00:01.00>', '\n\n\n']) {
        expect(() => parseLrc(s), returnsNormally);
      }
    });
  });

  group('lyric timing', () {
    final doc = parseLrc(
      '[00:01.00]a\n[00:02.00]b\n[00:04.00]\n[00:05.00]c',
    ).doc;

    test('line started at, around boundaries', () {
      expect(lyricLineStartedAt(doc, 0.999), -1);
      expect(lyricLineStartedAt(doc, 1.0), 0);
      expect(lyricLineStartedAt(doc, 1.999), 0);
      expect(lyricLineStartedAt(doc, 2.0), 1);
      expect(lyricLineStartedAt(doc, 4.5), 1);
      expect(lyricLineStartedAt(doc, 5), 2);
      expect(lyricLineStartedAt(doc, 1e9), 2);
    });

    test('active line, around boundaries and breaks', () {
      expect(activeLyricLine(doc, 0.5), -1);
      expect(activeLyricLine(doc, 1), 0);
      expect(activeLyricLine(doc, 2 - 1e-9), 0);
      expect(activeLyricLine(doc, 2), 1);
      expect(activeLyricLine(doc, 3.999), 1);
      expect(activeLyricLine(doc, 4), -1);
      expect(activeLyricLine(doc, 5), 2);
      expect(lyricLineEnd(doc, 2), double.infinity);
      expect(activeLyricLine(doc, 100), 2);
    });

    test('word progress', () {
      final l = parseLrc('[00:01.00]<00:01.00>a <00:02.00>b').doc.lines.single;
      expect(lyricWordProgress(l, 0, 0.5, 3), 0);
      expect(lyricWordProgress(l, 0, 1.5, 3), 0.5);
      expect(lyricWordProgress(l, 0, 2, 3), 1);
      expect(lyricWordProgress(l, 1, 2.5, 3), 0.5);
      expect(lyricWordProgress(l, 1, 2.5, double.infinity), 1);
    });
  });
}
