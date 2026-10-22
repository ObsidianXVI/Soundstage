import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:soundstage_platform/ir/ir.dart' as ir;

// TextReveal (architecture §9): each unit of text (character, word or line)
// fades and rises in, staggered across the behaviour's clock range. Painted
// per glyph run from the text layout's boxes; no widgets are split.
//
// **Default look** (the behaviour has no look fields, so it is fixed):
// - a unit's opacity goes 0 → 1 and it rises from [kRevealRise] × its line
//   height below its place to its place, both on easeOutCubic over the
//   unit's slot;
// - units with progress 0 are not painted; whitespace is never a unit.
//
// **Timing.** With `n` units, stagger `s` (a fraction of the range between
// successive unit starts) and the clock's progress `p` through `range`
// (0–1, clamped): each unit animates for `d = max(1 − (n − 1)·s, s)`, the
// whole reveal lasts `T = (n − 1)·s + d` (1 unless the stagger is too large
// to fit, in which case time is compressed to fit the range), and unit `i`
// is at `clamp((p·T − i·s) / d, 0, 1)`. `s = 0` reveals everything at once.

/// How far below its place a unit starts, as a fraction of its line height.
const double kRevealRise = 0.4;

/// The progress (0–1) of a reveal over [range] at clock value [clock].
double revealProgress(ir.ClockRange range, double clock) {
  final span = range.end - range.start;
  if (span == 0) return clock >= range.end ? 1 : 0;
  final p = (clock - range.start) / span;
  return p < 0 ? 0 : (p > 1 ? 1 : p);
}

/// Precomputed stagger timing for [count] units (see the file comment).
class RevealTiming {
  RevealTiming(this.count, double stagger)
    : stagger = stagger < 0 ? 0 : stagger,
      duration = _duration(count, stagger < 0 ? 0 : stagger) {
    total = (count <= 1 ? 0 : (count - 1) * this.stagger) + duration;
  }

  static double _duration(int n, double s) {
    if (n <= 1) return 1;
    final d = 1 - (n - 1) * s;
    return math.max(d, s > 0 ? s : 1);
  }

  final int count;
  final double stagger;

  /// Each unit's share of the (normalised) reveal.
  final double duration;

  /// The whole reveal in units of the range (≥ 1 only when compressed).
  late final double total;

  /// Linear progress of unit [i] at reveal progress [p].
  double unit(int i, double p) {
    if (duration <= 0) return p >= 1 ? 1 : 0;
    final v = (p * total - i * stagger) / duration;
    // Snap rounding noise at the end so finished units paint whole.
    return v < 0 ? 0 : (v > 1 - 1e-9 ? 1 : v);
  }
}

/// easeOutCubic.
double revealEase(double t) {
  final u = 1 - t;
  return 1 - u * u * u;
}

/// The character or word units of [text] as `[start, end)` UTF-16 ranges.
/// Whitespace and the object replacement character (inline placeholders)
/// are never units. Characters are grapheme clusters.
List<TextRange> revealTextUnits(String text, ir.TextRevealUnit unit) {
  final out = <TextRange>[];
  bool blank(String ch) => ch.trim().isEmpty || ch == '￼';
  switch (unit) {
    case ir.TextRevealUnit.char:
      var o = 0;
      for (final ch in text.characters) {
        if (!blank(ch)) out.add(TextRange(start: o, end: o + ch.length));
        o += ch.length;
      }
    case ir.TextRevealUnit.word:
      var start = -1;
      var o = 0;
      for (final ch in text.characters) {
        final b = blank(ch);
        if (!b && start < 0) start = o;
        if (b && start >= 0) {
          out.add(TextRange(start: start, end: o));
          start = -1;
        }
        o += ch.length;
      }
      if (start >= 0) out.add(TextRange(start: start, end: o));
    case ir.TextRevealUnit.line:
      break; // lines come from layout
  }
  return out;
}

/// The reveal of one text node: which units it owns and how far each is.
/// Set on a `StageTextLayout` while painting.
abstract class StageTextRevealPaint {
  ir.TextRevealUnit get unit;

  /// Called before the node paints (its layout is current).
  void beginPaint() {}

  /// The linear progress (0–1) of the node's unit [i] (node-local index).
  double unitProgress(int i);
}

/// The geometry of a laid-out paragraph's reveal units (node-local).
class RevealUnitGeometry {
  RevealUnitGeometry(this.rects);

  /// Per unit, its boxes in the painter's coordinates.
  final List<List<Rect>> rects;
  int get length => rects.length;
}

/// Computes the unit boxes of [painter] (laid out) for [unit].
RevealUnitGeometry revealGeometry(TextPainter painter, ir.TextRevealUnit unit) {
  if (unit == ir.TextRevealUnit.line) {
    final out = <List<Rect>>[];
    var top = 0.0;
    for (final m in painter.computeLineMetrics()) {
      out.add([Rect.fromLTWH(m.left, top, m.width, m.height)]);
      top += m.height;
    }
    return RevealUnitGeometry(out);
  }
  final text = painter.plainText;
  final out = <List<Rect>>[];
  for (final r in revealTextUnits(text, unit)) {
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: r.start, extentOffset: r.end),
      boxHeightStyle: ui.BoxHeightStyle.max,
    );
    // Units the painter cut off (truncation) have no boxes.
    if (boxes.isEmpty) continue;
    out.add([for (final b in boxes) b.toRect().inflate(0.5)]);
  }
  return RevealUnitGeometry(out);
}

/// Paints [painter] at [at] with units [first]… of [reveal]: complete units
/// in one clipped draw, units in progress each in an alpha layer, risen.
void paintRevealed(
  Canvas canvas,
  TextPainter painter,
  Offset at,
  RevealUnitGeometry geometry,
  int first,
  StageTextRevealPaint reveal,
) {
  final n = geometry.length;
  if (n == 0) return;
  var allDone = true;
  var anyDone = false;
  for (var i = 0; i < n; i++) {
    final p = reveal.unitProgress(first + i);
    if (p < 1) allDone = false;
    if (p >= 1) anyDone = true;
  }
  if (allDone) {
    painter.paint(canvas, at);
    return;
  }
  if (anyDone) {
    final done = Path();
    for (var i = 0; i < n; i++) {
      if (reveal.unitProgress(first + i) < 1) continue;
      for (final r in geometry.rects[i]) {
        done.addRect(r.shift(at));
      }
    }
    canvas
      ..save()
      ..clipPath(done);
    painter.paint(canvas, at);
    canvas.restore();
  }
  for (var i = 0; i < n; i++) {
    final p = reveal.unitProgress(first + i);
    if (p <= 0 || p >= 1) continue;
    final e = revealEase(p);
    final rects = geometry.rects[i];
    var bounds = rects.first;
    for (final r in rects) {
      bounds = bounds.expandToInclude(r);
    }
    final rise = (1 - e) * kRevealRise * rects.first.height;
    final shifted = bounds.shift(at);
    canvas.saveLayer(
      shifted.translate(0, rise).inflate(2),
      Paint()..color = Color.fromRGBO(0, 0, 0, e),
    );
    canvas.translate(0, rise);
    if (rects.length == 1) {
      canvas.clipRect(shifted);
    } else {
      final path = Path();
      for (final r in rects) {
        path.addRect(r.shift(at));
      }
      canvas.clipPath(path);
    }
    painter.paint(canvas, at);
    canvas.restore();
  }
}
