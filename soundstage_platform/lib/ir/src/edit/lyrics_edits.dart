import '../audio.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../validate/validate.dart' show hasErrors;
import 'edit_core.dart';
import 'edit_result.dart';

// Pure lyrics edits on an audio track (architecture §10.4; m2.md "Lyrics
// lane"). Lines stay sorted by `start`: an edit never moves a line's start
// past a neighbour's, and a word never leaves its neighbours' order. The
// lane clamps drags to those bounds ([lyricStartBounds],
// [lyricWordStartBounds]); an edit that breaks them fails. Lines are
// addressed by index, words by index inside the line. Errors leave the
// document unchanged (see [EditResult]).

/// Replaces the lyrics of audio track [trackId] with [lyrics] (an LRC
/// import). Null or no lines clears them. The lines are checked like any
/// edit (finite, non-negative times, `end` after `start`, words in order)
/// and stably sorted by start.
EditResult setLyrics(StageDocument doc, String trackId, LyricsDoc? lyrics) {
  final clear = lyrics == null || lyrics.lines.isEmpty;
  return _editTrack(doc, trackId, (track, diags) {
    if (clear) {
      return track.lyrics == null ? track : track.copyWith(lyrics: null);
    }
    final order = [for (var i = 0; i < lyrics.lines.length; i++) i]
      ..sort((a, b) {
        final c = lyrics.lines[a].start.compareTo(lyrics.lines[b].start);
        return c != 0 ? c : a.compareTo(b);
      });
    final lines = [for (final i in order) lyrics.lines[i]];
    for (final (i, l) in lines.indexed) {
      final p = _checkLine(l, 'Line ${i + 1}');
      if (p != null) {
        diags.add(p);
        return null;
      }
    }
    return track.copyWith(lyrics: LyricsDoc(lines: lines));
  });
}

/// Clears the lyrics of audio track [trackId].
EditResult clearLyrics(StageDocument doc, String trackId) =>
    setLyrics(doc, trackId, null);

/// Replaces line [index] of track [trackId] by `change(line)`.
///
/// - The start must stay between the neighbouring lines' starts.
/// - Changing `text` of a line with words keeps the words when the new text
///   has the same number of whitespace-separated words (each word gets its
///   new text and keeps its timing); otherwise the words are dropped, with
///   a warning, and the line has line-level timing only.
EditResult updateLyricLine(
  StageDocument doc,
  String trackId,
  int index,
  LyricLine Function(LyricLine line) change,
) => _editLines(doc, trackId, (lines, diags) {
  if (!_inRange(index, lines.length)) {
    diags.add(_badIndex('line', index, lines.length));
    return null;
  }
  final old = lines[index];
  var next = change(old);
  if (identical(next, old) || next == old) return lines;
  if (next.text != old.text && old.words.isNotEmpty) {
    next = _retext(old, next, diags);
  }
  final p = _checkLine(next, 'Line ${index + 1}');
  if (p != null) {
    diags.add(p);
    return null;
  }
  final b = _startBounds(lines, index);
  if (next.start < b.min || next.start > b.max) {
    diags.add(_order('Line ${index + 1}', next.start, b));
    return null;
  }
  return [...lines]..[index] = next;
});

/// Moves line [index] so it starts at [start], shifting its end and every
/// word by the same amount (dragging a line block). The start is clamped to
/// [lyricStartBounds] with a warning.
EditResult moveLyricLine(
  StageDocument doc,
  String trackId,
  int index,
  double start,
) => _editLines(doc, trackId, (lines, diags) {
  if (!_inRange(index, lines.length)) {
    diags.add(_badIndex('line', index, lines.length));
    return null;
  }
  final old = lines[index];
  final b = _startBounds(lines, index);
  var s = start;
  if (!s.isFinite) {
    diags.add(_invalid('Line ${index + 1} needs a finite start.'));
    return null;
  }
  if (s < b.min || s > b.max) {
    diags.add(
      editWarning(
        IrDiagnosticKind.invalidEdit,
        'Line ${index + 1} was clamped between its neighbours.',
      ),
    );
    s = s.clamp(b.min, b.max);
  }
  final d = s - old.start;
  if (d == 0) return lines;
  final next = old.copyWith(
    start: s,
    end: old.end == null ? null : old.end! + d,
    words: [
      for (final w in old.words)
        w.copyWith(start: w.start + d, end: w.end == null ? null : w.end! + d),
    ],
  );
  return [...lines]..[index] = next;
});

/// Inserts [line] at its sorted position (after lines that start at the
/// same time). `createdIds` holds the new line's index as a string.
EditResult insertLyricLine(StageDocument doc, String trackId, LyricLine line) {
  var at = 0;
  return _editLines(doc, trackId, (lines, diags) {
    final p = _checkLine(line, 'The new line');
    if (p != null) {
      diags.add(p);
      return null;
    }
    while (at < lines.length && lines[at].start <= line.start) {
      at++;
    }
    return [...lines.sublist(0, at), line, ...lines.sublist(at)];
  }, created: () => ['$at']);
}

/// Removes line [index].
EditResult removeLyricLine(StageDocument doc, String trackId, int index) =>
    _editLines(doc, trackId, (lines, diags) {
      if (!_inRange(index, lines.length)) {
        diags.add(_badIndex('line', index, lines.length));
        return null;
      }
      return [...lines]..removeAt(index);
    });

/// Replaces word [word] of line [line] by `change(word)`. The word's start
/// must stay between its neighbours' starts and not before the line's
/// start; its `end` must not be before its start.
EditResult updateLyricWord(
  StageDocument doc,
  String trackId,
  int line,
  int word,
  LyricWord Function(LyricWord word) change,
) => _editLines(doc, trackId, (lines, diags) {
  if (!_inRange(line, lines.length)) {
    diags.add(_badIndex('line', line, lines.length));
    return null;
  }
  final l = lines[line];
  if (!_inRange(word, l.words.length)) {
    diags.add(_badIndex('word', word, l.words.length));
    return null;
  }
  final old = l.words[word];
  final next = change(old);
  if (identical(next, old) || next == old) return lines;
  final words = [...l.words]..[word] = next;
  final edited = l.copyWith(words: words);
  final p = _checkLine(edited, 'Line ${line + 1}');
  if (p != null) {
    diags.add(p);
    return null;
  }
  return [...lines]..[line] = edited;
});

/// The range line [index]'s start can take without passing a neighbour:
/// `min` is the previous line's start (0 for the first), `max` the next
/// line's start (infinity for the last).
({double min, double max}) lyricStartBounds(LyricsDoc doc, int index) =>
    _startBounds(doc.lines, index);

/// The range word [word] of [line] can start in: from the previous word's
/// start (the line's start for the first) to the next word's start (the
/// word's own end, or infinity, for the last).
({double min, double max}) lyricWordStartBounds(LyricLine line, int word) {
  final min = word == 0 ? line.start : line.words[word - 1].start;
  final max = word + 1 < line.words.length
      ? line.words[word + 1].start
      : double.infinity;
  return (min: min, max: max);
}

// ---- Internals -------------------------------------------------------------------

EditResult _editTrack(
  StageDocument doc,
  String trackId,
  AudioTrack? Function(AudioTrack track, List<IrDiagnostic> diags) edit,
) {
  final i = doc.audioTracks.indexWhere((t) => t.id == trackId);
  if (i < 0) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.missingAudioTrack,
        'There is no audio track "$trackId".',
      ),
    ]);
  }
  final diags = <IrDiagnostic>[];
  final old = doc.audioTracks[i];
  final next = edit(old, diags);
  if (next == null || hasErrors(diags)) {
    return failed(
      doc,
      diags.isEmpty ? [_invalid('Lyrics edit failed.')] : diags,
    );
  }
  if (identical(next, old) || next == old) return unchanged(doc, diags);
  return EditResult(
    document: doc.copyWith(audioTracks: [...doc.audioTracks]..[i] = next),
    changed: true,
    diagnostics: diags,
  );
}

EditResult _editLines(
  StageDocument doc,
  String trackId,
  List<LyricLine>? Function(List<LyricLine> lines, List<IrDiagnostic> diags)
  edit, {
  List<String> Function()? created,
}) {
  final r = _editTrack(doc, trackId, (track, diags) {
    final lines = track.lyrics?.lines ?? const <LyricLine>[];
    final next = edit(lines, diags);
    if (next == null) return null;
    if (identical(next, lines)) return track;
    return track.copyWith(lyrics: next.isEmpty ? null : LyricsDoc(lines: next));
  });
  return created == null || !r.changed ? r : r.copyWith(createdIds: created());
}

bool _inRange(int i, int n) => i >= 0 && i < n;

({double min, double max}) _startBounds(List<LyricLine> lines, int index) => (
  min: index == 0 ? 0.0 : lines[index - 1].start,
  max: index + 1 < lines.length ? lines[index + 1].start : double.infinity,
);

IrDiagnostic _badIndex(String what, int i, int n) => editError(
  IrDiagnosticKind.invalidEdit,
  'There is no $what $i (0–${n - 1}).',
);

IrDiagnostic _invalid(String message) =>
    editError(IrDiagnosticKind.invalidValue, message);

IrDiagnostic _order(String what, double start, ({double min, double max}) b) =>
    editError(
      IrDiagnosticKind.invalidEdit,
      '$what cannot start at ${start.toStringAsFixed(2)} s: lines stay in '
      'order, between ${b.min.toStringAsFixed(2)} s and '
      '${b.max.isFinite ? '${b.max.toStringAsFixed(2)} s' : 'the end'}.',
    );

/// Why [l] is not a valid line, or null.
IrDiagnostic? _checkLine(LyricLine l, String name) {
  if (!l.start.isFinite || l.start < 0) {
    return _invalid('$name needs a start of zero or more seconds.');
  }
  if (l.text.trim().isEmpty) return _invalid('$name has no text.');
  final end = l.end;
  if (end != null && (!end.isFinite || end < l.start)) {
    return _invalid('$name ends before it starts.');
  }
  var prev = l.start;
  for (final (i, w) in l.words.indexed) {
    if (!w.start.isFinite || w.start < prev) {
      return _invalid(
        '$name: word ${i + 1} starts before the line or the previous word.',
      );
    }
    final we = w.end;
    if (we != null && (!we.isFinite || we < w.start)) {
      return _invalid('$name: word ${i + 1} ends before it starts.');
    }
    prev = w.start;
  }
  return null;
}

/// [next] (a text edit of [old], which has words): the words follow the
/// new text when the word count is unchanged, else they are dropped.
LyricLine _retext(LyricLine old, LyricLine next, List<IrDiagnostic> diags) {
  if (!identical(next.words, old.words) && next.words != old.words) {
    return next; // The caller edited the words itself.
  }
  final parts = next.text.trim().split(RegExp(r'\s+'));
  if (parts.length == old.words.length) {
    return next.copyWith(
      words: [
        for (final (i, w) in old.words.indexed) w.copyWith(text: parts[i]),
      ],
    );
  }
  diags.add(
    editWarning(
      IrDiagnosticKind.invalidEdit,
      'The word timings were dropped: the new text has ${parts.length} '
      'words, the line had ${old.words.length}.',
    ),
  );
  return next.copyWith(words: const []);
}
