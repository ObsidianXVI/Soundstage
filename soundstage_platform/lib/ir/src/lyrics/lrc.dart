// LRC and enhanced-LRC parsing (architecture §10.4). Pure Dart.

import '../audio.dart';
import '../diagnostics.dart';

/// The result of [parseLrc]: the lyrics, the file's metadata tags and any
/// problems found. Parsing never throws.
class LrcParseResult {
  const LrcParseResult({
    required this.doc,
    this.metadata = const {},
    this.offset = 0,
    this.diagnostics = const [],
  });

  final LyricsDoc doc;

  /// Metadata tags by lower-cased key (`ti`, `ar`, `al`, `by`, `length`,
  /// `re`, `ve`, …), without `offset`.
  final Map<String, String> metadata;

  /// The `[offset:]` tag in seconds (already applied to every time).
  final double offset;

  /// Lines that could not be parsed (warnings; the line is skipped).
  final List<IrDiagnostic> diagnostics;
}

final RegExp _tag = RegExp(r'^\[([^\]]*)\]');
final RegExp _time = RegExp(r'^(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?$');
final RegExp _wordTime = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');
final RegExp _meta = RegExp(r'^([A-Za-z#][A-Za-z0-9_#-]*)\s*:(.*)$');

/// Seconds for an `mm:ss(.xx)` match, or null when seconds are out of
/// range. Fractions are read as decimals: `.5` = 0.5 s, `.05` = 0.05 s,
/// `.005` = 0.005 s.
double? _seconds(String mm, String ss, String? frac) {
  final m = int.parse(mm);
  final s = int.parse(ss);
  if (s >= 60) return null;
  var f = 0.0;
  if (frac != null && frac.isNotEmpty) {
    f = int.parse(frac) / _pow10(frac.length);
  }
  return m * 60 + s + f;
}

int _pow10(int n) {
  var r = 1;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

/// Parses LRC (`[mm:ss.xx]text`) and enhanced LRC (`<mm:ss.xx>` word times)
/// into a [LyricsDoc].
///
/// - Several timestamps on one line (`[00:12.00][00:40.00]text`) make one
///   lyric line per timestamp.
/// - `[offset:±ms]` shifts every time; positive values make lyrics appear
///   earlier (the LRC convention). Times never go below 0.
/// - Metadata tags (`[ar:…]`, `[ti:…]`, …) go to
///   [LrcParseResult.metadata].
/// - A timed line with no text ends the previous line (`end`) and adds no
///   line (an instrumental break).
/// - Enhanced LRC: each `<t>` starts a word that runs to the next `<t>`; a
///   trailing `<t>` ends the last word. Text before the first word time
///   belongs to a word at the line's start time.
/// - Lines are sorted by start time (stable). A line's `end` stays null
///   unless a break sets it (it then ends at the next line's start).
/// - Lines that cannot be parsed (bad timestamps, plain text, unclosed
///   tags) produce `invalidLyrics` warnings and are skipped.
LrcParseResult parseLrc(String source) {
  final diagnostics = <IrDiagnostic>[];
  final metadata = <String, String>{};
  // (start, text, raw body, source line) before the offset is applied.
  final timed = <({double start, String body, int line})>[];
  var offsetMs = 0;

  var text = source;
  if (text.startsWith('﻿')) text = text.substring(1);
  final lines = text.split(RegExp(r'\r\n|\r|\n'));
  for (var li = 0; li < lines.length; li++) {
    final raw = lines[li].trim();
    if (raw.isEmpty) continue;
    void warn(String why) => diagnostics.add(
      IrDiagnostic(
        IrDiagnosticKind.invalidLyrics,
        'LRC line ${li + 1}: $why',
        path: 'line ${li + 1}',
        severity: IrSeverity.warning,
      ),
    );
    if (!raw.startsWith('[')) {
      warn('no timestamp or tag ("$raw").');
      continue;
    }
    var rest = raw;
    final starts = <double>[];
    var bad = false;
    var isMeta = false;
    while (true) {
      final m = _tag.firstMatch(rest);
      if (m == null) break;
      final inner = m.group(1)!.trim();
      final t = _time.firstMatch(inner);
      if (t != null) {
        final s = _seconds(t.group(1)!, t.group(2)!, t.group(3));
        if (s == null) {
          warn('invalid timestamp "[$inner]".');
          bad = true;
          break;
        }
        starts.add(s);
      } else if (starts.isEmpty) {
        final mm = _meta.firstMatch(inner);
        if (mm == null) {
          warn('unrecognised tag "[$inner]".');
          bad = true;
          break;
        }
        final key = mm.group(1)!.toLowerCase();
        final value = mm.group(2)!.trim();
        if (key == 'offset') {
          final ms = int.tryParse(value.replaceFirst('+', ''));
          if (ms == null) {
            warn('invalid offset "$value".');
          } else {
            offsetMs = ms;
          }
        } else {
          metadata[key] = value;
        }
        isMeta = true;
      } else {
        // A non-time tag after a timestamp is part of the text.
        break;
      }
      rest = rest.substring(m.end);
    }
    if (bad) continue;
    if (starts.isEmpty) {
      if (!isMeta) warn('unclosed or empty tag ("$raw").');
      if (isMeta && rest.trim().isNotEmpty) {
        warn('text after a metadata tag is ignored.');
      }
      continue;
    }
    for (final s in starts) {
      timed.add((start: s, body: rest, line: li));
    }
  }

  final offset = offsetMs / 1000;
  double shift(double t) {
    final v = t - offset;
    return v < 0 ? 0 : v;
  }

  // Stable sort by start.
  final order = [for (var i = 0; i < timed.length; i++) i]
    ..sort((a, b) {
      final c = timed[a].start.compareTo(timed[b].start);
      return c != 0 ? c : a.compareTo(b);
    });

  final out = <LyricLine>[];
  for (final i in order) {
    final e = timed[i];
    final start = shift(e.start);
    final parsed = _parseWords(e.body, start, shift);
    if (parsed.text.isEmpty) {
      // A break: end the previous line here.
      if (out.isNotEmpty && out.last.end == null) {
        out[out.length - 1] = out.last.copyWith(end: start);
      }
      continue;
    }
    out.add(LyricLine(start: start, text: parsed.text, words: parsed.words));
  }
  return LrcParseResult(
    doc: LyricsDoc(lines: out),
    metadata: metadata,
    offset: offset,
    diagnostics: diagnostics,
  );
}

/// The line text and its words (enhanced LRC) from a line body.
({String text, List<LyricWord> words}) _parseWords(
  String body,
  double lineStart,
  double Function(double) shift,
) {
  final matches = _wordTime.allMatches(body).toList();
  if (matches.isEmpty) return (text: body.trim(), words: const []);
  final words = <LyricWord>[];
  final text = StringBuffer();
  void addWord(String chunk, double start, double? end) {
    text.write(chunk);
    final w = chunk.trim();
    if (w.isEmpty) return;
    words.add(LyricWord(start: start, text: w, end: end));
  }

  double timeOf(RegExpMatch m) =>
      shift(_seconds(m.group(1)!, m.group(2)!, m.group(3)) ?? 0);

  final lead = body.substring(0, matches.first.start);
  if (lead.trim().isNotEmpty) addWord(lead, lineStart, timeOf(matches.first));
  for (var i = 0; i < matches.length; i++) {
    final m = matches[i];
    final chunkEnd = i + 1 < matches.length
        ? matches[i + 1].start
        : body.length;
    final chunk = body.substring(m.end, chunkEnd);
    final next = i + 1 < matches.length ? timeOf(matches[i + 1]) : null;
    addWord(chunk, timeOf(m), next);
  }
  return (text: text.toString().trim(), words: words);
}
