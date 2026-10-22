import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show SizedBox, WidgetSpan;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../media/fonts.dart';
import '../../paint/text_variant.dart';
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
  });

  factory StageTextSettings.of(ir.TextNode node) => StageTextSettings(
    autoResize: node.autoResize,
    maxLines: node.maxLines,
    truncation: node.truncation,
    alignVertical: node.alignVertical,
  );

  final ir.TextAutoResize autoResize;
  final int? maxLines;
  final ir.TextTruncation truncation;
  final ir.TextAlignVertical alignVertical;

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
      other.alignVertical == alignVertical;

  @override
  int get hashCode =>
      Object.hash(autoResize, maxLines, truncation, alignVertical);
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
    required StageFontTable fonts,
    required this.settings,
  }) : _paras = _build(paragraphs, fonts);

  final StageTextSettings settings;
  final List<_Para> _paras;

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
    _size = Size(w, y);
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
    for (final p in _paras) {
      if (!p.visible) continue;
      final at = offset + p.offset + Offset(0, dy);
      final v = variant == null ? null : p.variant(variant);
      final painter = v?.painter ?? p.painter;
      painter.paint(canvas, at);
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
  late final List<List<ir.Paint>> complexFillGroups = _complexGroups();

  List<List<ir.Paint>> _complexGroups() {
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
  late final bool hasSimpleFill = _hasSimpleFill();

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
  late final bool fillsAreOpaque = _fillsAreOpaque();

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
    TextStyle? baseStyle,
  ) {
    final spans = para.spans;
    final first = spans.isEmpty ? const ir.TextStyle() : spans.first.style;
    final base = baseStyle ?? stageTextStyle(first, fonts, variant: variant);
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
          style: stageTextStyle(s.style, fonts, variant: variant),
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
