import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'stage_text_layout.dart';
import 'text_style_mapping.dart';

// In-place text editing on the real text render object (T1.8, m1.md
// "Settled designs"): geometry queries over a laid-out [StageTextLayout] and
// the decoration (selection, caret, composing underline) painted with the
// text. The runtime knows nothing about the editor: colours and sizes come
// in with [StageTextEditing].
//
// Offsets here are paragraph offsets in the source text (the resolved
// spans' text). The painter text differs from it by the indent placeholder
// and by text-case transforms that change length (rare: `ß` → `SS`); both are
// mapped.

/// What a text node in edit mode paints over and under its text. Offsets
/// are document offsets (paragraphs joined by one separator unit).
///
/// - [selection]: the selected range (start ≤ end); painted under the text
///   in [selectionColor] when not collapsed.
/// - [caret]: the caret offset, painted when [caretVisible], [caretWidth]
///   wide (in the node's own units: the editor divides by its zoom), in
///   [caretColor]. [caretUpstream] places a caret at a soft line break at
///   the end of the upper line.
/// - [composing]: the IME composing range, underlined.
/// - [revealFull]: a truncating node shows all its text (no ellipsis) while
///   edited.
@immutable
class StageTextEditing {
  const StageTextEditing({
    required this.selectionColor,
    required this.caretColor,
    this.selection,
    this.caret,
    this.caretVisible = true,
    this.caretUpstream = false,
    this.caretWidth = 1.5,
    this.composing,
    this.revealFull = true,
  });

  final (int, int)? selection;
  final int? caret;
  final bool caretVisible;
  final bool caretUpstream;
  final double caretWidth;
  final (int, int)? composing;
  final Color selectionColor;
  final Color caretColor;
  final bool revealFull;

  @override
  bool operator ==(Object other) =>
      other is StageTextEditing &&
      other.selection == selection &&
      other.caret == caret &&
      other.caretVisible == caretVisible &&
      other.caretUpstream == caretUpstream &&
      other.caretWidth == caretWidth &&
      other.composing == composing &&
      other.selectionColor == selectionColor &&
      other.caretColor == caretColor &&
      other.revealFull == revealFull;

  @override
  int get hashCode => Object.hash(
    selection,
    caret,
    caretVisible,
    caretUpstream,
    caretWidth,
    composing,
    selectionColor,
    caretColor,
    revealFull,
  );
}

/// The source length of [p].
int resolvedParagraphLength(ir.ResolvedParagraph p) {
  var n = 0;
  for (final s in p.spans) {
    n += s.text.length;
  }
  return n;
}

/// Document offset [offset] of [paras] as (paragraph, offset), clamped.
(int, int) paragraphPointOf(List<ir.ResolvedParagraph> paras, int offset) {
  if (paras.isEmpty) return (0, 0);
  var rest = math.max(0, offset);
  for (var i = 0; i < paras.length; i++) {
    final len = resolvedParagraphLength(paras[i]);
    if (rest <= len) return (i, rest);
    rest -= len + 1;
  }
  final last = paras.length - 1;
  return (last, resolvedParagraphLength(paras[last]));
}

/// The document offset of (paragraph, offset) in [paras].
int documentOffsetOf(
  List<ir.ResolvedParagraph> paras,
  int paragraph,
  int offset,
) {
  var n = 0;
  for (var i = 0; i < paragraph && i < paras.length; i++) {
    n += resolvedParagraphLength(paras[i]) + 1;
  }
  return n + offset;
}

bool _changesLength(ir.TextCase c) =>
    c == ir.TextCase.upper || c == ir.TextCase.lower || c == ir.TextCase.title;

/// Source offset → painter offset in [b].
int toPainterOffset(StageTextParagraphBox b, int offset) {
  final spans = b.source.spans;
  if (!spans.any((s) => _changesLength(s.style.textCase))) {
    return b.leadingUnits + offset;
  }
  var src = 0, out = b.leadingUnits;
  var startsWord = true;
  for (final s in spans) {
    final painted = applyTextCase(
      s.text,
      s.style.textCase,
      startsWord: startsWord,
    ).length;
    final len = s.text.length;
    if (offset <= src + len) {
      final k = offset - src;
      return out +
          (len == painted ? k : (k * painted / math.max(1, len)).round());
    }
    src += len;
    out += painted;
    if (s.text.isNotEmpty) {
      startsWord = s.text.substring(s.text.length - 1).trim().isEmpty;
    }
  }
  return out;
}

/// Painter offset → source offset in [b] (clamped to the paragraph).
int toSourceOffset(StageTextParagraphBox b, int painterOffset) {
  final spans = b.source.spans;
  final total = resolvedParagraphLength(b.source);
  final o = painterOffset - b.leadingUnits;
  if (!spans.any((s) => _changesLength(s.style.textCase))) {
    return o.clamp(0, total);
  }
  var src = 0, out = 0;
  var startsWord = true;
  for (final s in spans) {
    final painted = applyTextCase(
      s.text,
      s.style.textCase,
      startsWord: startsWord,
    ).length;
    final len = s.text.length;
    if (o <= out + painted) {
      final k = o - out;
      return (src +
              (len == painted ? k : (k * len / math.max(1, painted)).round()))
          .clamp(0, total);
    }
    src += len;
    out += painted;
    if (s.text.isNotEmpty) {
      startsWord = s.text.substring(s.text.length - 1).trim().isEmpty;
    }
  }
  return total;
}

/// Text-editing geometry of a laid-out [StageTextLayout] in a box of
/// [boxHeight]: everything in the box's coordinates.
class StageTextEditingGeometry {
  StageTextEditingGeometry(this.layout, this.boxHeight)
    : _dy = layout.alignOffset(boxHeight);

  final StageTextLayout layout;
  final double boxHeight;
  final double _dy;

  Offset _origin(StageTextParagraphBox b) => b.offset + Offset(0, _dy);

  /// The (paragraph, offset) nearest to [point]: the paragraph whose lines
  /// span the point's y (between paragraphs, the nearer one), then the
  /// closest caret position on its line.
  (int, int) positionAt(Offset point) {
    final n = layout.paragraphCount;
    if (n == 0) return (0, 0);
    var best = -1;
    var bestDist = double.infinity;
    for (var i = 0; i < n; i++) {
      final b = layout.paragraphBox(i);
      if (!b.visible) continue;
      final top = _origin(b).dy;
      final bottom = top + b.painter.height;
      final d = point.dy < top
          ? top - point.dy
          : (point.dy > bottom ? point.dy - bottom : 0.0);
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
      if (d == 0) break;
    }
    if (best < 0) return (0, 0);
    final b = layout.paragraphBox(best);
    final o = _origin(b);
    final local = point - o;
    final y = local.dy
        .clamp(0.0, math.max(0.0, b.painter.height - 0.01))
        .toDouble();
    final pos = b.painter.getPositionForOffset(Offset(local.dx, y));
    return (best, toSourceOffset(b, pos.offset));
  }

  /// The line box of the painter line at [dy] (painter coordinates): top
  /// and height, or null without lines.
  static (double, double)? _lineAt(TextPainter painter, double dy) {
    final lines = painter.computeLineMetrics();
    if (lines.isEmpty) return null;
    var top = 0.0;
    for (final l in lines) {
      if (dy < top + l.height - 0.01 || identical(l, lines.last)) {
        return (top, l.height);
      }
      top += l.height;
    }
    return null;
  }

  /// The caret's rect for ([paragraph], [offset]), [width] wide, spanning
  /// its line box.
  Rect caretRect(
    int paragraph,
    int offset, {
    bool upstream = false,
    double width = 1.5,
  }) {
    if (layout.paragraphCount == 0) return Rect.fromLTWH(0, 0, width, 16);
    final b = layout.paragraphBox(
      paragraph.clamp(0, layout.paragraphCount - 1),
    );
    final pos = TextPosition(
      offset: toPainterOffset(b, offset),
      affinity: upstream ? TextAffinity.upstream : TextAffinity.downstream,
    );
    final at = b.painter.getOffsetForCaret(pos, Rect.zero);
    final line = _lineAt(b.painter, at.dy + 0.5);
    final top = line?.$1 ?? at.dy;
    final height = line?.$2 ?? b.painter.getFullHeightForCaret(pos, Rect.zero);
    final o = _origin(b);
    return Rect.fromLTWH(o.dx + at.dx - width / 2, o.dy + top, width, height);
  }

  /// The rects covering the selection from (pa, oa) to (pb, ob), one per
  /// line run; a selected paragraph break shows as a narrow box after the
  /// paragraph's last line.
  List<Rect> selectionRects(int pa, int oa, int pb, int ob) {
    final out = <Rect>[];
    final n = layout.paragraphCount;
    for (var p = math.max(0, pa); p <= pb && p < n; p++) {
      final b = layout.paragraphBox(p);
      if (!b.visible) continue;
      final len = resolvedParagraphLength(b.source);
      final from = p == pa ? oa : 0;
      final to = p == pb ? ob : len;
      final o = _origin(b);
      if (to > from) {
        for (final box in b.painter.getBoxesForSelection(
          TextSelection(
            baseOffset: toPainterOffset(b, from),
            extentOffset: toPainterOffset(b, to),
          ),
          boxHeightStyle: ui.BoxHeightStyle.max,
        )) {
          out.add(box.toRect().shift(o));
        }
      }
      if (p < pb) {
        // The paragraph break: a sliver after the last character.
        final end = caretRect(p, len, width: 0);
        out.add(Rect.fromLTWH(end.left, end.top, end.height * 0.3, end.height));
      }
    }
    return out;
  }

  /// The visual line around ([paragraph], [offset]) as source offsets.
  (int, int) lineBoundary(int paragraph, int offset, {bool upstream = false}) {
    if (layout.paragraphCount == 0) return (0, 0);
    final b = layout.paragraphBox(
      paragraph.clamp(0, layout.paragraphCount - 1),
    );
    final r = b.painter.getLineBoundary(
      TextPosition(
        offset: toPainterOffset(b, offset),
        affinity: upstream ? TextAffinity.upstream : TextAffinity.downstream,
      ),
    );
    return (toSourceOffset(b, r.start), toSourceOffset(b, r.end));
  }

  /// Paints [e] under ([under]) or over the text at [offset] (the box's
  /// top-left), for [paragraphs] (the layout's).
  void paint(
    Canvas canvas,
    Offset offset,
    StageTextEditing e,
    List<ir.ResolvedParagraph> paragraphs, {
    required bool under,
  }) {
    if (under) {
      final sel = e.selection;
      if (sel == null || sel.$1 == sel.$2) return;
      final (pa, oa) = paragraphPointOf(paragraphs, sel.$1);
      final (pb, ob) = paragraphPointOf(paragraphs, sel.$2);
      final paint = Paint()..color = e.selectionColor;
      for (final r in selectionRects(pa, oa, pb, ob)) {
        canvas.drawRect(r.shift(offset), paint);
      }
      return;
    }
    final comp = e.composing;
    if (comp != null && comp.$1 < comp.$2) {
      final (pa, oa) = paragraphPointOf(paragraphs, comp.$1);
      final (pb, ob) = paragraphPointOf(paragraphs, comp.$2);
      final paint = Paint()
        ..color = e.caretColor
        ..strokeWidth = e.caretWidth * 0.75;
      for (final r in selectionRects(pa, oa, pb, ob)) {
        final y = r.bottom - e.caretWidth;
        canvas.drawLine(
          offset + Offset(r.left, y),
          offset + Offset(r.right, y),
          paint,
        );
      }
    }
    final caret = e.caret;
    if (caret != null && e.caretVisible) {
      final (p, o) = paragraphPointOf(paragraphs, caret);
      final r = caretRect(p, o, upstream: e.caretUpstream, width: e.caretWidth);
      canvas.drawRect(r.shift(offset), Paint()..color = e.caretColor);
    }
  }
}
