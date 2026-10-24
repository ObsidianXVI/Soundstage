import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show SizedBox, WidgetSpan;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../media/fonts.dart';
import '../../paint/text_variant.dart';
import 'text_reveal.dart';
import 'text_style_mapping.dart';

/// Extra width given to painters so text laid out at exactly its measured
/// width never wraps from floating-point noise.
const double _kWrapSlack = 0.01;

/// The ellipsis used for truncated text.
const String kStageEllipsis = '…';

/// The settings of a text node that shape its layout. Text styling comes
/// only from the resolved paragraphs.
class StageTextSettings {
  const StageTextSettings({
    this.autoResize = ir.TextAutoResize.widthAndHeight,
    this.maxLines,
    this.truncation = ir.TextTruncation.none,
    this.alignVertical = ir.TextAlignVertical.top,
    this.leadingTrim = ir.LeadingTrim.none,
  });

  factory StageTextSettings.of(ir.TextNode node) => StageTextSettings(
    autoResize: node.autoResize,
    maxLines: node.maxLines,
    truncation: node.truncation,
    alignVertical: node.alignVertical,
    leadingTrim: node.leadingTrim,
  );

  final ir.TextAutoResize autoResize;
  final int? maxLines;
  final ir.TextTruncation truncation;
  final ir.TextAlignVertical alignVertical;
  final ir.LeadingTrim leadingTrim;

  /// Whether lines past [maxLines] or the box height become an ellipsis:
  /// the `truncate` auto-resize mode, or `truncation: ending` in any mode.
  bool get truncates =>
      autoResize == ir.TextAutoResize.truncate ||
      truncation == ir.TextTruncation.ending;

  @override
  bool operator ==(Object other) =>
      other is StageTextSettings &&
      other.autoResize == autoResize &&
      other.maxLines == maxLines &&
      other.truncation == truncation &&
      other.alignVertical == alignVertical &&
      other.leadingTrim == leadingTrim;

  @override
  int get hashCode =>
      Object.hash(autoResize, maxLines, truncation, alignVertical, leadingTrim);
}

/// Lays out and paints resolved rich text (architecture §7).
///
/// Flutter has no paragraph spacing, so each paragraph gets its own
/// [TextPainter], stacked with the paragraph's `paragraphSpacing` after it.
/// `paragraphIndent` indents the first line (a leading placeholder), and
/// list paragraphs hang their text after a marker gutter. Every line uses
/// `TextLeadingDistribution.even`.
///
/// One instance is not shared between measuring and painting: render objects
/// keep one for dry layout and one for the laid-out state.
class StageTextLayout {
  StageTextLayout({
    required List<ir.ResolvedParagraph> paragraphs,
    required this.fonts,
    required this.settings,
  }) : _paras = _build(paragraphs, fonts);

  final StageTextSettings settings;
  final StageFontTable fonts;
  final List<_Para> _paras;

  /// The paragraphs the layout was built (or last restyled) from.
  List<ir.ResolvedParagraph> get paragraphs => [
    for (final p in _paras) p.source,
  ];

  /// Whether any span uses document font [familyId] (relayout on load).
  bool usesFamily(String familyId) {
    for (final p in _paras) {
      for (final s in p.source.spans) {
        if (s.style.fontFamilyId == familyId) return true;
      }
    }
    return false;
  }

  /// Replaces the paragraphs whose entry in [next] is not identical to the
  /// current one (animated text styles). Each replaced paragraph rebuilds
  /// its `TextSpan`s, reusing the mapped style of every span whose IR style
  /// is unchanged; unchanged paragraphs keep their painters. The layout is
  /// redone on the next [layout] / [relayout]. [next] must have as many
  /// paragraphs as the current layout.
  void restyle(List<ir.ResolvedParagraph> next) {
    assert(next.length == _paras.length);
    var changed = false;
    for (var i = 0; i < _paras.length && i < next.length; i++) {
      final old = _paras[i];
      if (identical(old.source, next[i])) continue;
      _paras[i] = _rebuildPara(old, next[i], fonts);
      old.dispose();
      changed = true;
    }
    if (!changed) return;
    _laidOut = false;
    _complexGroups = null;
    _simpleFill = null;
    _opaque = null;
    _revealGeometry = null;
  }

  /// Lays out again at the last [layout]'s width and box height if the text
  /// changed since (a paint-only restyle).
  void relayout() {
    if (_laidOut) return;
    layout(width: _width, boxHeight: _boxHeight);
  }

  /// Whether the layout is current.
  bool get isLaidOut => _laidOut;

  double _trimTop = 0;

  /// How much `leadingTrim: capHeight` removed above the first line (0
  /// without trim).
  double get leadingTrimTop => _trimTop;

  /// The reveal painting the text (TextReveal); null paints it whole.
  StageTextRevealPaint? reveal;

  List<RevealUnitGeometry>? _revealGeometry;
  ir.TextRevealUnit? _revealUnit;

  /// Per visible paragraph, its reveal unit boxes for [unit].
  List<RevealUnitGeometry> revealGeometryFor(ir.TextRevealUnit unit) {
    final cached = _revealGeometry;
    if (cached != null && _revealUnit == unit) return cached;
    _revealUnit = unit;
    return _revealGeometry = [
      for (final p in _paras)
        p.visible
            ? revealGeometry(p.painter, unit)
            : RevealUnitGeometry(const []),
    ];
  }

  /// The number of reveal units for [unit] (after layout).
  int revealUnitCount(ir.TextRevealUnit unit) {
    var n = 0;
    for (final g in revealGeometryFor(unit)) {
      n += g.length;
    }
    return n;
  }

  double? _width;
  double? _boxHeight;
  bool _laidOut = false;
  Size _size = Size.zero;

  /// The content size from the last [layout]: the text block's width (the
  /// given width, or the widest paragraph when hugging) and the height of
  /// the visible paragraphs.
  Size get size => _size;

  /// Lays the text out at [width] (null = no wrapping, hug the widest
  /// paragraph). [boxHeight] is the box's definite height, which limits
  /// lines when the text truncates.
  void layout({double? width, double? boxHeight}) {
    if (_laidOut && width == _width && boxHeight == _boxHeight) return;
    _laidOut = true;
    _width = width;
    _boxHeight = boxHeight;
    _revealGeometry = null;

    var w = width;
    if (w == null) {
      var widest = 0.0;
      for (final p in _paras) {
        p.reset();
        p.painter.layout();
        widest = math.max(widest, p.gutter + p.painter.maxIntrinsicWidth);
      }
      w = widest;
    }

    final truncates = settings.truncates;
    final lineLimit = truncates ? settings.maxLines : null;
    final heightLimit = truncates ? boxHeight : null;
    var y = 0.0;
    var lines = 0;
    var stopped = false;
    for (var i = 0; i < _paras.length; i++) {
      final p = _paras[i];
      if (stopped) {
        p.visible = false;
        continue;
      }
      if (i > 0) y += _paras[i - 1].spacing;
      final tw = math.max(0.0, w - p.gutter);
      p.reset();
      p.painter.layout(minWidth: tw, maxWidth: tw + _kWrapSlack);
      if (lineLimit != null || heightLimit != null) {
        final metrics = p.painter.computeLineMetrics();
        var allowed = metrics.length;
        if (lineLimit != null) allowed = math.min(allowed, lineLimit - lines);
        if (heightLimit != null) {
          var fit = 0;
          var top = y;
          for (final m in metrics) {
            if (top + m.height > heightLimit + 0.5) break;
            top += m.height;
            fit++;
          }
          allowed = math.min(allowed, fit);
        }
        // The first paragraph always shows at least one line.
        if (allowed <= 0 && i == 0) allowed = 1;
        if (allowed <= 0) {
          p.visible = false;
          stopped = true;
          // Undo the spacing added for this paragraph.
          y -= _paras[i - 1].spacing;
          continue;
        }
        if (allowed < metrics.length) {
          p.painter
            ..maxLines = allowed
            ..ellipsis = kStageEllipsis
            ..layout(minWidth: tw, maxWidth: tw + _kWrapSlack);
          stopped = true;
        }
        lines += allowed;
      }
      p.visible = true;
      p.laidOut(tw);
      p.offset = Offset(p.gutter, y);
      y += p.painter.height;
    }
    final (top, bottom) = _leadingTrim();
    _trimTop = top;
    if (top != 0) {
      for (final p in _paras) {
        p.offset = p.offset.translate(0, -top);
      }
    }
    _size = Size(w, math.max(0, y - top - bottom));
  }

  /// `leadingTrim: capHeight` (architecture §7, best effort): trims the
  /// first line's top down to the cap height of its first span's font and
  /// the last line's bottom up to its baseline. Needs the font's OS/2
  /// `sCapHeight` (v2+); without it there is no trim and a font diagnostic.
  (double, double) _leadingTrim() {
    if (settings.leadingTrim != ir.LeadingTrim.capHeight) return (0, 0);
    _Para? first;
    _Para? last;
    for (final p in _paras) {
      if (!p.visible) continue;
      first ??= p;
      last = p;
    }
    if (first == null || last == null) return (0, 0);
    ir.TextStyle? style;
    for (final s in first.source.spans) {
      if (s.text.isNotEmpty) {
        style = s.style;
        break;
      }
    }
    if (style == null) return (0, 0);
    final id = style.fontFamilyId;
    final face = fonts.faceFor(id, style.fontWeight, style.italic);
    final capEm = face?.metrics?.capHeightEm;
    if (capEm == null) {
      if (id == null || !fonts.families.containsKey(id)) {
        fonts.report(
          id ?? '(default)',
          'leadingTrim: capHeight needs a document font with OS/2 metrics; '
          'not trimmed',
        );
      } else if (face != null) {
        fonts.report(
          id,
          'leadingTrim: capHeight needs OS/2 v2+ sCapHeight; not trimmed',
        );
      }
      return (0, 0);
    }
    final firstLines = first.painter.computeLineMetrics();
    final lastLines = identical(first, last)
        ? firstLines
        : last.painter.computeLineMetrics();
    if (firstLines.isEmpty || lastLines.isEmpty) return (0, 0);
    final top = firstLines.first.baseline - capEm * style.fontSize;
    final bottom = last.painter.height - lastLines.last.baseline;
    return (top, bottom);
  }

  /// Vertical offset of the text block inside a box of [boxHeight]
  /// (`alignVertical`; overflow is distributed the same way, as in Figma).
  double alignOffset(double boxHeight) {
    final free = boxHeight - _size.height;
    return switch (settings.alignVertical) {
      ir.TextAlignVertical.top => 0.0,
      ir.TextAlignVertical.middle => free / 2,
      ir.TextAlignVertical.bottom => free,
    };
  }

  /// The first line's alphabetic baseline from the top of a box of
  /// [boxHeight], or null without visible text.
  double? firstBaseline(double boxHeight) {
    for (final p in _paras) {
      if (!p.visible) continue;
      return p.offset.dy +
          p.painter.computeDistanceToActualBaseline(TextBaseline.alphabetic) +
          alignOffset(boxHeight);
    }
    return null;
  }

  /// Paints the text into a box at [offset] of [boxHeight]: in the spans'
  /// own fill colours, or as a [variant] (mask, stroke, shadow).
  void paint(
    Canvas canvas,
    Offset offset,
    double boxHeight, {
    StageTextVariant? variant,
  }) {
    final dy = alignOffset(boxHeight);
    final r = reveal;
    final geometry = r == null ? null : revealGeometryFor(r.unit);
    var unit = 0;
    for (final (i, p) in _paras.indexed) {
      if (!p.visible) continue;
      final at = offset + p.offset + Offset(0, dy);
      final v = variant == null ? null : p.variant(variant);
      final painter = v?.painter ?? p.painter;
      if (r == null || geometry == null) {
        painter.paint(canvas, at);
      } else {
        paintRevealed(canvas, painter, at, geometry[i], unit, r);
        unit += geometry[i].length;
        // Markers appear with the paragraph's first unit.
        if (geometry[i].length == 0 ||
            r.unitProgress(unit - geometry[i].length) <= 0) {
          continue;
        }
      }
      final marker = v == null ? p.marker : v.marker;
      if (marker != null) {
        final base = painter.computeDistanceToActualBaseline(
          TextBaseline.alphabetic,
        );
        final mBase = marker.computeDistanceToActualBaseline(
          TextBaseline.alphabetic,
        );
        marker.paint(canvas, Offset(at.dx - p.gutter, at.dy + base - mBase));
      }
    }
  }

  /// The distinct fill stacks of spans that need a glyph mask (gradient,
  /// image or stacked fills), in order of first use.
  List<List<ir.Paint>> get complexFillGroups =>
      _complexGroups ??= _computeComplexGroups();
  List<List<ir.Paint>>? _complexGroups;

  List<List<ir.Paint>> _computeComplexGroups() {
    final out = <List<ir.Paint>>[];
    for (final p in _paras) {
      for (final s in p.source.spans) {
        if (s.text.isEmpty || isSimpleTextFill(s.style.fills)) continue;
        if (!out.any((g) => listEquals(g, s.style.fills))) {
          out.add(s.style.fills);
        }
      }
    }
    return out;
  }

  /// Whether any span has a visible simple (single solid) fill.
  bool get hasSimpleFill => _simpleFill ??= _hasSimpleFill();
  bool? _simpleFill;

  bool _hasSimpleFill() {
    for (final p in _paras) {
      for (final s in p.source.spans) {
        if (s.text.isNotEmpty &&
            isSimpleTextFill(s.style.fills) &&
            simpleTextColor(s.style.fills).a > 0) {
          return true;
        }
      }
    }
    return false;
  }

  /// Whether every visible span is an opaque solid (shadows then need no
  /// knock-out behind the glyphs).
  bool get fillsAreOpaque => _opaque ??= _fillsAreOpaque();
  bool? _opaque;

  bool _fillsAreOpaque() {
    for (final p in _paras) {
      for (final s in p.source.spans) {
        if (s.text.isEmpty) continue;
        if (!isSimpleTextFill(s.style.fills) ||
            simpleTextColor(s.style.fills).a < 1) {
          return false;
        }
      }
    }
    return true;
  }

  /// The visible paragraphs' painters (tests and hit testing).
  Iterable<TextPainter> get visiblePainters =>
      _paras.where((p) => p.visible).map((p) => p.painter);

  /// The number of paragraphs (shown or not).
  int get paragraphCount => _paras.length;

  /// Paragraph [index] as laid out, for text editing (T1.8): its painter,
  /// its top-left in the text block (before [alignOffset]), whether it is
  /// shown, and the painter text units before the paragraph's own text (1
  /// when an indent placeholder leads it).
  StageTextParagraphBox paragraphBox(int index) {
    final p = _paras[index];
    final root = p.painter.text;
    var lead = 0;
    if (root is TextSpan) {
      final kids = root.children;
      if (kids != null && kids.isNotEmpty && kids.first is WidgetSpan) lead = 1;
    }
    return StageTextParagraphBox(
      painter: p.painter,
      offset: p.offset,
      visible: p.visible,
      leadingUnits: lead,
      source: p.source,
    );
  }

  void dispose() {
    for (final p in _paras) {
      p.dispose();
    }
  }

  static List<_Para> _build(
    List<ir.ResolvedParagraph> paragraphs,
    StageFontTable fonts,
  ) {
    final out = <_Para>[];
    var ordinal = 0;
    for (final para in paragraphs) {
      final spans = para.spans;
      final first = spans.isEmpty ? const ir.TextStyle() : spans.first.style;
      final base = stageTextStyle(first, fonts);
      var gutter = 0.0;
      var paraOrdinal = 0;
      TextPainter? marker;
      if (para.listStyle == ir.ListStyle.none) {
        ordinal = 0;
      } else {
        final ordered = para.listStyle == ir.ListStyle.ordered;
        ordinal = ordered ? ordinal + 1 : 0;
        paraOrdinal = ordinal;
        marker = _markerPainter(para, ordinal, fonts, null)..layout();
        final fs = first.fontSize;
        gutter = math.max(1.5 * fs, marker.width + 0.5 * fs);
      }
      out.add(
        _Para(
          source: para,
          fonts: fonts,
          ordinal: paraOrdinal,
          painter: _textPainter(para, fonts, null, base),
          spacing: para.paragraphSpacing,
          marker: marker,
          gutter: gutter,
        ),
      );
    }
    return out;
  }

  /// [old]'s paragraph rebuilt for [para] (same list position and ordinal).
  /// Spans whose IR style is identical to before reuse their mapped style.
  static _Para _rebuildPara(
    _Para old,
    ir.ResolvedParagraph para,
    StageFontTable fonts,
  ) {
    final spans = para.spans;
    final first = spans.isEmpty ? const ir.TextStyle() : spans.first.style;
    final reuse = Map<ir.TextStyle, TextStyle>.identity();
    for (final s in old.source.spans) {
      final mapped = old.mapped[s.style];
      if (mapped != null) reuse[s.style] = mapped;
    }
    TextPainter? marker;
    var gutter = 0.0;
    if (para.listStyle != ir.ListStyle.none) {
      marker = _markerPainter(para, old.ordinal, fonts, null)..layout();
      final fs = first.fontSize;
      gutter = math.max(1.5 * fs, marker.width + 0.5 * fs);
    }
    return _Para(
      source: para,
      fonts: fonts,
      ordinal: old.ordinal,
      painter: _textPainter(para, fonts, null, null, reuse),
      spacing: para.paragraphSpacing,
      marker: marker,
      gutter: gutter,
    );
  }

  static TextPainter _markerPainter(
    ir.ResolvedParagraph para,
    int ordinal,
    StageFontTable fonts,
    StageTextVariant? variant,
  ) {
    final first = para.spans.isEmpty
        ? const ir.TextStyle()
        : para.spans.first.style;
    final ordered = para.listStyle == ir.ListStyle.ordered;
    return TextPainter(
      text: TextSpan(
        text: ordered ? '$ordinal.' : '•',
        style: stageTextStyle(
          first,
          fonts,
          variant: variant,
        ).copyWith(decoration: TextDecoration.none),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
  }

  /// The painter of [para], styled for [variant] (null = the spans' own
  /// fills). [baseStyle] is passed when already computed.
  static TextPainter _textPainter(
    ir.ResolvedParagraph para,
    StageFontTable fonts,
    StageTextVariant? variant,
    TextStyle? baseStyle, [
    Map<ir.TextStyle, TextStyle>? reuse,
  ]) {
    final spans = para.spans;
    final first = spans.isEmpty ? const ir.TextStyle() : spans.first.style;
    TextStyle mapped(ir.TextStyle s) {
      if (variant != null) return stageTextStyle(s, fonts, variant: variant);
      final hit = reuse?[s];
      if (hit != null) return hit;
      final m = stageTextStyle(s, fonts);
      reuse?[s] = m;
      return m;
    }

    final base = baseStyle ?? mapped(first);
    final children = <InlineSpan>[];
    final indent = para.paragraphIndent;
    final hasText = spans.any((s) => s.text.isNotEmpty);
    if (indent > 0 && hasText) {
      children.add(
        const WidgetSpan(
          child: SizedBox.shrink(),
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
        ),
      );
    }
    var startsWord = true;
    for (final s in spans) {
      children.add(
        TextSpan(
          text: applyTextCase(s.text, s.style.textCase, startsWord: startsWord),
          style: mapped(s.style),
        ),
      );
      if (s.text.isNotEmpty) {
        startsWord = s.text.substring(s.text.length - 1).trim().isEmpty;
      }
    }
    final painter = TextPainter(
      text: TextSpan(
        style: base,
        text: children.isEmpty ? '' : null,
        children: children.isEmpty ? null : children,
      ),
      textAlign: switch (para.alignHorizontal) {
        ir.TextAlignHorizontal.left => TextAlign.left,
        ir.TextAlignHorizontal.center => TextAlign.center,
        ir.TextAlignHorizontal.right => TextAlign.right,
        ir.TextAlignHorizontal.justified => TextAlign.justify,
      },
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    if (indent > 0 && hasText) {
      painter.setPlaceholderDimensions([
        PlaceholderDimensions(
          size: Size(indent, 0),
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          baselineOffset: 0,
        ),
      ]);
    }
    return painter;
  }
}

/// One laid-out paragraph of a [StageTextLayout] (see
/// [StageTextLayout.paragraphBox]).
class StageTextParagraphBox {
  const StageTextParagraphBox({
    required this.painter,
    required this.offset,
    required this.visible,
    required this.leadingUnits,
    required this.source,
  });

  final TextPainter painter;
  final Offset offset;
  final bool visible;
  final int leadingUnits;
  final ir.ResolvedParagraph source;
}

class _Variant {
  _Variant(this.painter, this.marker);
  final TextPainter painter;
  final TextPainter? marker;
  int rev = -1;
}

class _Para {
  _Para({
    required this.source,
    required this.fonts,
    required this.ordinal,
    required this.painter,
    required this.spacing,
    required this.gutter,
    this.marker,
  });

  final ir.ResolvedParagraph source;
  final StageFontTable fonts;

  /// The mapped style of each span's IR style, from the painter's spans
  /// (identity-keyed lookups first; see [StageTextLayout.restyle]).
  late final Map<ir.TextStyle, TextStyle> mapped = _mappedStyles();

  Map<ir.TextStyle, TextStyle> _mappedStyles() {
    final out = Map<ir.TextStyle, TextStyle>.identity();
    final root = painter.text;
    if (root is! TextSpan) return out;
    final children = root.children;
    if (children == null) return out;
    var i = 0;
    for (final c in children) {
      if (c is! TextSpan) continue;
      if (i >= source.spans.length) break;
      final style = c.style;
      if (style != null) out[source.spans[i].style] = style;
      i++;
    }
    return out;
  }

  final int ordinal;
  final TextPainter painter;
  final double spacing;
  final double gutter;
  final TextPainter? marker;
  Offset offset = Offset.zero;
  bool visible = true;

  /// Bumped on every layout; variant painters re-layout when stale.
  int rev = 0;
  double _width = 0;
  final Map<String, _Variant> _variants = {};

  void reset() {
    if (painter.maxLines != null) painter.maxLines = null;
    if (painter.ellipsis != null) painter.ellipsis = null;
  }

  /// Records the layout [painter] just got, so variants can repeat it.
  void laidOut(double textWidth) {
    rev++;
    _width = textWidth;
  }

  /// The painter for [v], laid out like [painter].
  _Variant variant(StageTextVariant v) {
    final e = _variants.putIfAbsent(v.key, () {
      TextPainter? m;
      if (marker != null) {
        m = StageTextLayout._markerPainter(source, ordinal, fonts, v)..layout();
      }
      return _Variant(StageTextLayout._textPainter(source, fonts, v, null), m);
    });
    if (e.rev != rev) {
      e.rev = rev;
      e.painter
        ..maxLines = painter.maxLines
        ..ellipsis = painter.ellipsis
        ..layout(minWidth: _width, maxWidth: _width + _kWrapSlack);
    }
    return e;
  }

  void dispose() {
    painter.dispose();
    marker?.dispose();
    for (final v in _variants.values) {
      v.painter.dispose();
      v.marker?.dispose();
    }
  }
}
