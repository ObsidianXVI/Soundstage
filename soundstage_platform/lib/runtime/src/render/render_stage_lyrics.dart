import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../media/fonts.dart';
import 'render_stage_box.dart';
import 'stage_environment.dart';
import 'text/text_style_mapping.dart';

/// How long a line takes to cross-fade between its inactive and active
/// styles, in seconds of audio time.
const double kLyricsFade = 0.25;

/// How long the line stack takes to scroll to a new line (easeInOutCubic).
const double kLyricsScroll = 0.6;

/// The cross-fade (0 inactive … 1 active) of a line that is active from
/// [start] to [end] at audio time [t]: it fades in over [kLyricsFade] from
/// its start and out over [kLyricsFade] from its end.
double lyricLineMix(double t, double start, double end) {
  if (t < start) return 0;
  final fadeIn = math.min(1.0, (t - start) / kLyricsFade);
  final double fadeOut = end.isInfinite
      ? 1.0
      : 1 - math.min(1.0, math.max(0.0, (t - end) / kLyricsFade));
  return math.min(fadeIn, fadeOut);
}

double _easeInOutCubic(double t) =>
    t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2;

/// The scroll offset of a line stack at audio time [t]: before the first
/// line, [targets]`[0]`; then it eases from the previous line's target to
/// the started line's target over [kLyricsScroll] from that line's start.
double lyricsScrollOffset(ir.LyricsDoc doc, List<double> targets, double t) {
  if (targets.isEmpty) return 0;
  final k = ir.lyricLineStartedAt(doc, t);
  if (k <= 0) return targets[0];
  final from = targets[k - 1], to = targets[k];
  final u = ((t - doc.lines[k].start) / kLyricsScroll).clamp(0.0, 1.0);
  return from + (to - from) * _easeInOutCubic(u);
}

class _Line {
  _Line(this.source, this.inactive, this.active, this.unsung, this.words);

  final ir.LyricLine source;
  final TextPainter inactive;
  final TextPainter active;

  /// The active layout in the inactive fills (word-timed lines only): what
  /// the not-yet-sung part of the active line shows.
  final TextPainter? unsung;

  /// Each word's `[start, end)` range in the line text.
  final List<TextRange> words;
  List<List<Rect>>? wordBoxes;
  double top = 0;
  double height = 0;

  void dispose() {
    inactive.dispose();
    active.dispose();
    unsung?.dispose();
  }
}

/// A `Lyrics` behaviour (architecture §9, §10.4): the lines of a
/// [ir.LyricsDoc], laid out as a stack in place of the frame's first text
/// child, which is the line template (its first span's style, alignment,
/// width and position).
///
/// - **Styles.** Each line has an inactive (template ⊕ `inactiveStyle`)
///   and an active (template ⊕ `activeStyle`) rendering, cross-faded over
///   [kLyricsFade] as the line starts and ends ([lyricLineMix]).
/// - **Layout** never changes with time: each line's slot is as tall as
///   its taller rendering, with the template's paragraph spacing between
///   lines. The stack hugs its height; the frame should clip it.
/// - **Scrolling** (`scrollMode`): `center` keeps the started line at the
///   frame's vertical centre, `top` at the stack's own top position, and
///   `none` never scrolls. The stack eases between lines over
///   [kLyricsScroll] ([lyricsScrollOffset]).
/// - **Words.** On word-timed lines the active line shows sung words in
///   the active style and the rest in the inactive fills, sweeping through
///   the current word.
/// - Time comes from [time] (the animator's lyrics driver, on the track's
///   audio clock). Changing it only repaints.
class RenderStageLyrics extends RenderStageBox {
  RenderStageLyrics({
    required ir.TextNode node,
    required this._paragraphs,
    required this._behavior,
    required this._lyrics,
    required super.environment,
    super.repaintBoundary,
  }) : super(node: node);

  List<ir.ResolvedParagraph> _paragraphs;
  set paragraphs(List<ir.ResolvedParagraph> v) {
    if (identical(v, _paragraphs)) return;
    _paragraphs = v;
    _reset();
  }

  ir.LyricsBehavior _behavior;
  ir.LyricsBehavior get behavior => _behavior;
  set behavior(ir.LyricsBehavior v) {
    if (identical(v, _behavior)) return;
    _behavior = v;
    _reset();
  }

  ir.LyricsDoc? _lyrics;
  set lyrics(ir.LyricsDoc? v) {
    if (identical(v, _lyrics)) return;
    _lyrics = v;
    _reset();
  }

  double _time = 0;

  /// Audio time in seconds.
  double get time => _time;
  set time(double v) {
    if (v == _time) return;
    _time = v;
    markNeedsPaint();
  }

  List<_Line>? _lines;
  double _laidOutWidth = -1;

  void _reset() {
    for (final l in _lines ?? const <_Line>[]) {
      l.dispose();
    }
    _lines = null;
    _laidOutWidth = -1;
    markStageLayoutDirty();
  }

  ir.TextStyle get _template {
    for (final p in _paragraphs) {
      for (final s in p.spans) {
        return s.style;
      }
    }
    return const ir.TextStyle();
  }

  TextAlign get _align => switch (_paragraphs.isEmpty
      ? ir.TextAlignHorizontal.left
      : _paragraphs.first.alignHorizontal) {
    ir.TextAlignHorizontal.left => TextAlign.left,
    ir.TextAlignHorizontal.center => TextAlign.center,
    ir.TextAlignHorizontal.right => TextAlign.right,
    ir.TextAlignHorizontal.justified => TextAlign.justify,
  };

  double get _spacing =>
      _paragraphs.isEmpty ? 0 : _paragraphs.first.paragraphSpacing;

  List<_Line> _build() {
    final doc = _lyrics;
    if (doc == null) return const [];
    final fonts = environment.fonts;
    final template = _template;
    final inactive = ir.mergeTextStyle(template, _behavior.inactiveStyle);
    final active = ir.mergeTextStyle(template, _behavior.activeStyle);
    final unsung = active.copyWith(fills: inactive.fills);
    final align = _align;
    TextPainter painter(String text, ir.TextStyle s) => TextPainter(
      text: TextSpan(
        text: applyTextCase(text, s.textCase),
        style: stageTextStyle(s, fonts),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    );
    return [
      for (final line in doc.lines)
        _Line(
          line,
          painter(line.text, inactive),
          painter(line.text, active),
          line.words.isEmpty ? null : painter(line.text, unsung),
          _wordRanges(line),
        ),
    ];
  }

  static List<TextRange> _wordRanges(ir.LyricLine line) {
    final out = <TextRange>[];
    var cursor = 0;
    for (final w in line.words) {
      final i = line.text.indexOf(w.text, cursor);
      if (i < 0) {
        out.add(TextRange.empty);
        continue;
      }
      out.add(TextRange(start: i, end: i + w.text.length));
      cursor = i + w.text.length;
    }
    return out;
  }

  List<_Line> _layoutLines(double width) {
    final lines = _lines ??= _build();
    if (_laidOutWidth == width) return lines;
    _laidOutWidth = width;
    var y = 0.0;
    final gap = _spacing;
    for (final (i, l) in lines.indexed) {
      for (final p in [l.inactive, l.active, ?l.unsung]) {
        p.layout(minWidth: width, maxWidth: width);
      }
      l
        ..wordBoxes = null
        ..top = y
        ..height = math.max(l.inactive.height, l.active.height);
      y += l.height + (i < lines.length - 1 ? gap : 0);
    }
    return lines;
  }

  double _width(BoxConstraints c) =>
      c.hasTightWidth ? c.maxWidth : c.constrainWidth(storedSize.width);

  Size _sizeFor(BoxConstraints c) {
    final w = _width(c);
    final lines = _layoutLines(w);
    final h = lines.isEmpty ? 0.0 : lines.last.top + lines.last.height;
    return Size(w, c.hasTightHeight ? c.maxHeight : c.constrainHeight(h));
  }

  @override
  bool get hugsHeight => true;

  @override
  Size computeStageDryLayout(BoxConstraints constraints) =>
      _sizeFor(constraints);

  @override
  Size performStageLayout() => _sizeFor(constraints);

  @override
  StageInvalidation environmentInvalidation(
    StageEnvironment old,
    StageEnvironment next,
  ) {
    if (!identical(old.fonts, next.fonts)) {
      _reset();
      if (attached) _listenFonts();
      return StageInvalidation.layout;
    }
    return StageInvalidation.paint;
  }

  // ---- Fonts ------------------------------------------------------------------

  StageFontTable? _listening;

  void _listenFonts() {
    final f = environment.fonts;
    if (identical(f, _listening)) return;
    _listening?.removeListener(_fontLoaded);
    _listening = f;
    f.addListener(_fontLoaded);
  }

  void _fontLoaded(String familyId) {
    if (!attached) return;
    final t = _template;
    final uses =
        t.fontFamilyId == familyId ||
        _behavior.activeStyle.fontFamilyId == familyId ||
        _behavior.inactiveStyle.fontFamilyId == familyId;
    if (uses) _reset();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listenFonts();
  }

  @override
  void detach() {
    _listening?.removeListener(_fontLoaded);
    _listening = null;
    super.detach();
  }

  @override
  void dispose() {
    _listening?.removeListener(_fontLoaded);
    for (final l in _lines ?? const <_Line>[]) {
      l.dispose();
    }
    super.dispose();
  }

  // ---- State at a time (tests) ------------------------------------------------

  /// The scroll targets of each line for the current scroll mode.
  List<double> scrollTargets() {
    final lines = _lines;
    if (lines == null || !hasSize) return const [];
    switch (_behavior.scrollMode) {
      case ir.LyricsScrollMode.none:
        return List.filled(lines.length, 0);
      case ir.LyricsScrollMode.top:
        return [for (final l in lines) l.top];
      case ir.LyricsScrollMode.center:
        final p = parent;
        final frameH = p is RenderBox && p.hasSize
            ? p.size.height
            : size.height;
        final pd = parentData;
        final top = pd is BoxParentData ? pd.offset.dy : 0.0;
        return [for (final l in lines) top + l.top + l.height / 2 - frameH / 2];
    }
  }

  /// The current scroll offset of the stack.
  double get scrollOffset {
    final doc = _lyrics;
    if (doc == null) return 0;
    return lyricsScrollOffset(doc, scrollTargets(), _time);
  }

  /// The top of line [i] relative to the stack box (tests).
  double lineTop(int i) => _lines![i].top;

  // ---- Paint ------------------------------------------------------------------

  @override
  void paintStage(PaintingContext context, Offset offset) {
    final doc = _lyrics;
    final lines = _lines;
    if (doc == null || lines == null || lines.isEmpty) return;
    final canvas = context.canvas;
    final scroll = scrollOffset;
    final p = parent;
    final frameH = p is RenderBox && p.hasSize ? p.size.height : size.height;
    final t = _time;
    final o = paintOpacity;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final y = l.top - scroll;
      if (y + l.height < -frameH || y > frameH * 2 + size.height) continue;
      final end = ir.lyricLineEnd(doc, i);
      final mix = lyricLineMix(t, l.source.start, end);
      final at = offset + Offset(0, y);
      if (mix <= 0) {
        _paintPainter(canvas, l.inactive, at, l.height, o);
      } else if (mix >= 1 && o >= 1) {
        _paintActive(canvas, l, at, t, end);
      } else {
        _layer(canvas, at, l, o * (1 - mix), () {
          l.inactive.paint(canvas, at + Offset(0, _dy(l, l.inactive)));
        });
        _layer(
          canvas,
          at,
          l,
          o * mix,
          () => _paintActive(canvas, l, at, t, end),
        );
      }
    }
  }

  double _dy(_Line l, TextPainter p) => (l.height - p.height) / 2;

  void _paintPainter(
    Canvas canvas,
    TextPainter p,
    Offset at,
    double slot,
    double opacity,
  ) {
    final dy = (slot - p.height) / 2;
    if (opacity >= 1) {
      p.paint(canvas, at + Offset(0, dy));
      return;
    }
    if (opacity <= 0) return;
    canvas.saveLayer(
      (at & Size(size.width, slot)).inflate(slot),
      Paint()..color = Color.fromRGBO(0, 0, 0, opacity),
    );
    p.paint(canvas, at + Offset(0, dy));
    canvas.restore();
  }

  void _layer(
    Canvas canvas,
    Offset at,
    _Line l,
    double opacity,
    VoidCallback paint,
  ) {
    if (opacity <= 0) return;
    canvas.saveLayer(
      (at & Size(size.width, l.height)).inflate(l.height),
      Paint()..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
    );
    paint();
    canvas.restore();
  }

  void _paintActive(Canvas canvas, _Line l, Offset at, double t, double end) {
    final active = l.active;
    final pos = at + Offset(0, _dy(l, active));
    final unsung = l.unsung;
    if (unsung == null || l.source.words.isEmpty) {
      active.paint(canvas, pos);
      return;
    }
    unsung.paint(canvas, pos);
    final boxes = l.wordBoxes ??= [
      for (final r in l.words)
        r.isCollapsed
            ? const <Rect>[]
            : [
                for (final b in active.getBoxesForSelection(
                  TextSelection(baseOffset: r.start, extentOffset: r.end),
                  boxHeightStyle: ui.BoxHeightStyle.max,
                ))
                  b.toRect(),
              ],
    ];
    final sung = Path();
    var any = false;
    for (var w = 0; w < l.source.words.length && w < boxes.length; w++) {
      final p = ir.lyricWordProgress(l.source, w, t, end);
      if (p <= 0) break;
      for (final r in boxes[w]) {
        final right = p >= 1 ? r.right : r.left + r.width * p;
        // Extend left so a word's sweep joins the previous word.
        sung.addRect(
          Rect.fromLTRB(r.left - 1, r.top, right, r.bottom).shift(pos),
        );
        any = true;
      }
    }
    if (!any) return;
    canvas
      ..save()
      ..clipPath(sung);
    active.paint(canvas, pos);
    canvas.restore();
  }
}
