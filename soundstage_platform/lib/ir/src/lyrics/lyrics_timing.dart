// Lyric timing queries (architecture §10.4). Pure Dart.

import '../audio.dart';

/// When line [i] of [doc] ends: its `end`, else the next line's start, else
/// never (infinity). Lines are expected in start order (as [parseLrc]
/// returns them).
double lyricLineEnd(LyricsDoc doc, int i) {
  final lines = doc.lines;
  final e = lines[i].end;
  if (e != null) return e;
  return i + 1 < lines.length ? lines[i + 1].start : double.infinity;
}

/// The last line that has started at time [t] (start ≤ t), or −1 before the
/// first line. This is the line a lyrics view scrolls to: it stays put
/// through instrumental breaks.
int lyricLineStartedAt(LyricsDoc doc, double t) {
  final lines = doc.lines;
  var lo = 0, hi = lines.length - 1, found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].start <= t) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

/// The line being sung at time [t] (start ≤ t < end), or −1 (before the
/// first line, in a break, after the last line's explicit end).
int activeLyricLine(LyricsDoc doc, double t) {
  final i = lyricLineStartedAt(doc, t);
  if (i < 0) return -1;
  return t < lyricLineEnd(doc, i) ? i : -1;
}

/// When word [w] of [line] ends: its `end`, else the next word's start,
/// else the line's [lineEnd].
double lyricWordEnd(LyricLine line, int w, double lineEnd) {
  final words = line.words;
  final e = words[w].end;
  if (e != null) return e;
  return w + 1 < words.length ? words[w + 1].start : lineEnd;
}

/// How far word [w] of [line] has been sung at [t]: 0 before its start, 1
/// after its end, linear in between.
double lyricWordProgress(LyricLine line, int w, double t, double lineEnd) {
  final start = line.words[w].start;
  if (t <= start) return 0;
  final end = lyricWordEnd(line, w, lineEnd);
  if (t >= end || end <= start || end.isInfinite) return 1;
  return (t - start) / (end - start);
}
