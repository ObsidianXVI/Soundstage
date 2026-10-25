import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../animator/compiled_track.dart';
import '../animator/text_style_tracks.dart';
import '../media/fonts.dart';
import '../paint/appearance_compositor.dart';
import 'render_stage_box.dart';
import 'render_stage_frame.dart' show stageDevicePixelRatio;
import 'stage_environment.dart';
import 'text/stage_text_layout.dart';
import 'text/text_editing.dart';
import 'text/text_paint.dart';
import 'text/text_reveal.dart';

/// Rich text (architecture §7), laid out from the resolved paragraphs only
/// (the resolver has merged every span's style; this never merges styles).
///
/// Natural size by `autoResize`: `widthAndHeight` hugs both axes without
/// wrapping, `height` wraps at its width and hugs height, `fixed` and
/// `truncate` keep the stored box. A width imposed by the parent (fill,
/// stretch constraints, max width) wraps the text. A `hug` layoutChild
/// sizing also makes the node hug that axis.
class RenderStageText extends RenderStageBox
    with RelayoutWhenSystemFontsChangeMixin
    implements StageTypedTrackHost {
  RenderStageText({
    required ir.TextNode node,
    required this._paragraphs,
    required super.environment,
    super.repaintBoundary,
  }) : _settings = StageTextSettings.of(node),
       super(node: node);

  ir.TextNode get text => node as ir.TextNode;

  List<ir.ResolvedParagraph> _paragraphs;
  List<ir.ResolvedParagraph> get paragraphs => _paragraphs;
  set paragraphs(List<ir.ResolvedParagraph> value) {
    if (identical(value, _paragraphs)) return;
    _paragraphs = value;
    _animDirty = true;
    _resetLayouts();
    markNeedsCompositingBitsUpdate();
    markStageLayoutDirty();
  }

  StageTextSettings _settings;

  StageTextLayout? _measureLayout;
  StageTextLayout? _paintLayout;

  StageTextLayout get _measure => _measureLayout ??= _newLayout();
  StageTextLayout get _paint => _paintLayout ??= _newLayout();

  StageTextLayout _newLayout() {
    _syncAnimated();
    return StageTextLayout(
      paragraphs: _rendered,
      fonts: environment.fonts,
      settings: _layoutSettings,
    );
  }

  /// [_settings], without truncation while [editing] reveals the full text.
  StageTextSettings get _layoutSettings {
    final s = _settings;
    if (_editing?.revealFull != true || !s.truncates) return s;
    return StageTextSettings(
      autoResize: s.autoResize == ir.TextAutoResize.truncate
          ? ir.TextAutoResize.fixed
          : s.autoResize,
      maxLines: s.maxLines,
      alignVertical: s.alignVertical,
      leadingTrim: s.leadingTrim,
    );
  }

  // ---- In-place editing (T1.8) ----------------------------------------------

  StageTextEditing? _editing;

  /// The editing decoration (selection, caret, composing underline) the
  /// editor sets on the node being edited; null outside edit mode. Paint
  /// only, except that a truncating node relays out to show its full text.
  StageTextEditing? get editing => _editing;
  set editing(StageTextEditing? value) {
    if (value == _editing) return;
    final wasFull = _editing?.revealFull == true;
    final full = value?.revealFull == true;
    _editing = value;
    if (wasFull != full && _settings.truncates) {
      _resetLayouts();
      markStageLayoutDirty();
      return;
    }
    if (!_detaching) markNeedsPaint();
  }

  /// Text-editing geometry of the laid-out text, in this box's coordinates
  /// (paragraph offsets). Needs a layout.
  StageTextEditingGeometry get editingGeometry {
    _syncAnimated();
    _paint.relayout();
    return StageTextEditingGeometry(_paint, hasSize ? size.height : 0);
  }

  /// The document offset nearest to [local] (a point in this box).
  int textOffsetAt(Offset local) {
    final (p, o) = editingGeometry.positionAt(local);
    return documentOffsetOf(renderedParagraphs, p, o);
  }

  /// The caret rect at document [offset], in this box.
  Rect caretRectAt(int offset, {bool upstream = false, double width = 1.5}) {
    final (p, o) = paragraphPointOf(renderedParagraphs, offset);
    return editingGeometry.caretRect(p, o, upstream: upstream, width: width);
  }

  /// The selection rects of document range [start, end), in this box.
  List<Rect> selectionRectsFor(int start, int end) {
    final paras = renderedParagraphs;
    final (pa, oa) = paragraphPointOf(paras, start < end ? start : end);
    final (pb, ob) = paragraphPointOf(paras, start < end ? end : start);
    return editingGeometry.selectionRects(pa, oa, pb, ob);
  }

  /// The visual line around document [offset], as document offsets.
  (int, int) lineBoundaryAt(int offset, {bool upstream = false}) {
    final paras = renderedParagraphs;
    final (p, o) = paragraphPointOf(paras, offset);
    final (a, b) = editingGeometry.lineBoundary(p, o, upstream: upstream);
    return (documentOffsetOf(paras, p, a), documentOffsetOf(paras, p, b));
  }

  // ---- Animated text styles (T0.7) ----------------------------------------------

  final StageTextAnimation _animation = StageTextAnimation();
  bool _animDirty = false;
  late List<ir.ResolvedParagraph> _rendered = _paragraphs;

  /// The paragraphs as rendered: the resolved paragraphs with animated
  /// style channels applied.
  List<ir.ResolvedParagraph> get renderedParagraphs {
    _syncAnimated();
    return _rendered;
  }

  /// Re-merges animated span styles if a channel changed, and restyles the
  /// existing layouts (only the affected paragraphs rebuild).
  void _syncAnimated() {
    if (!_animDirty) return;
    _animDirty = false;
    final next = _animation.apply(_paragraphs, text);
    if (identical(next, _rendered)) return;
    _rendered = next;
    if (next.length != (_paintLayout ?? _measureLayout)?.paragraphs.length) {
      _resetLayouts();
      return;
    }
    _measureLayout?.restyle(next);
    _paintLayout?.restyle(next);
  }

  /// Number of typed text-style channels bound (tests).
  int get animatedChannelCount => _animation.length;

  @override
  Object? bindTrack(CompiledTrack track) {
    final c = TextStyleChannel.compile(track);
    if (c == null) return null;
    _animation.add(c);
    trackChanged(c);
    return c;
  }

  @override
  void trackChanged(Object handle) {
    if (handle is! TextStyleChannel) return;
    _animDirty = true;
    applyInvalidation(handle.invalidation);
  }

  @override
  void unbindTrack(Object handle) {
    if (handle is! TextStyleChannel || !_animation.remove(handle)) return;
    _animDirty = true;
    // Unbinding while detaching (the node leaves the tree) invalidates
    // nothing: the node lays out again when it re-attaches.
    if (!_detaching) applyInvalidation(StageInvalidation.layout);
  }

  // ---- Fonts (T0.7) -------------------------------------------------------------

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
    final l = _paintLayout ?? _measureLayout;
    if (l != null && !l.usesFamily(familyId)) return;
    _resetLayouts();
    markStageLayoutDirty();
  }

  /// Fallback fonts (emoji, CJK) arrive asynchronously on the web and the
  /// engine reports them as a system font change: like `RenderParagraph`,
  /// drop the cached painters and lay out again, so glyphs drawn from the
  /// fallback are not left as tofu.
  @override
  void systemFontsDidChange() {
    super.systemFontsDidChange();
    _resetLayouts();
    markStageLayoutDirty();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listenFonts();
  }

  bool _detaching = false;

  @override
  void detach() {
    _listening?.removeListener(_fontLoaded);
    _listening = null;
    _detaching = true;
    try {
      super.detach();
    } finally {
      _detaching = false;
    }
  }

  // ---- TextReveal (T0.7) --------------------------------------------------------

  StageTextRevealPaint? _reveal;

  /// The reveal painting this text (set by the animator's TextReveal
  /// driver); null paints the text whole. Paint only.
  StageTextRevealPaint? get reveal => _reveal;
  set reveal(StageTextRevealPaint? value) {
    if (identical(value, _reveal)) return;
    _reveal = value;
    if (!_detaching) markNeedsPaint();
  }

  /// The number of reveal units of the laid-out text for [unit].
  int revealUnitCount(ir.TextRevealUnit unit) =>
      hasSize ? _paint.revealUnitCount(unit) : 0;

  void _resetLayouts() {
    _measureLayout?.dispose();
    _paintLayout?.dispose();
    _measureLayout = null;
    _paintLayout = null;
  }

  @override
  bool get hugsWidth =>
      text.autoResize == ir.TextAutoResize.widthAndHeight ||
      layoutChild.horizontalSizing == ir.Sizing.hug;

  @override
  bool get hugsHeight =>
      text.autoResize == ir.TextAutoResize.widthAndHeight ||
      text.autoResize == ir.TextAutoResize.height ||
      layoutChild.verticalSizing == ir.Sizing.hug;

  @override
  StageInvalidation invalidationFor(ir.Node old, ir.Node next) {
    var i = super.invalidationFor(old, next);
    if (next is! ir.TextNode) return StageInvalidation.layout;
    final settings = StageTextSettings.of(next);
    if (settings != _settings) {
      final layoutChanged =
          settings.autoResize != _settings.autoResize ||
          settings.maxLines != _settings.maxLines ||
          settings.truncation != _settings.truncation;
      _settings = settings;
      _resetLayouts();
      i = maxInvalidation(
        i,
        layoutChanged ? StageInvalidation.layout : StageInvalidation.paint,
      );
    }
    if (old is ir.TextNode && !identical(old.appearance, next.appearance)) {
      i = maxInvalidation(i, StageInvalidation.paint);
    }
    return i;
  }

  @override
  StageInvalidation environmentInvalidation(
    StageEnvironment old,
    StageEnvironment next,
  ) {
    if (!identical(old.fonts, next.fonts)) {
      _resetLayouts();
      if (attached) _listenFonts();
      return StageInvalidation.layout;
    }
    return StageInvalidation.paint;
  }

  Size _resolve(BoxConstraints c, StageTextLayout l) {
    _syncAnimated();
    double? width;
    if (c.hasTightWidth) {
      width = c.maxWidth;
    } else if (!hugsWidth) {
      width = c.constrainWidth(storedSize.width);
    }
    final double? boxHeight = c.hasTightHeight
        ? c.maxHeight
        : (hugsHeight ? null : c.constrainHeight(storedSize.height));
    l.layout(width: width, boxHeight: boxHeight);
    if (width == null && l.size.width > c.maxWidth) {
      width = c.maxWidth;
      l.layout(width: width, boxHeight: boxHeight);
    }
    return Size(
      c.constrainWidth(width ?? l.size.width),
      boxHeight ?? c.constrainHeight(l.size.height),
    );
  }

  @override
  Size computeStageDryLayout(BoxConstraints constraints) =>
      _resolve(constraints, _measure);

  @override
  double? computeStageDryBaseline(BoxConstraints constraints) {
    final s = _resolve(constraints, _measure);
    return _measure.firstBaseline(s.height);
  }

  @override
  Size performStageLayout() => _resolve(constraints, _paint);

  /// The first baseline of the laid-out text, from the top of the box.
  double? get firstBaseline {
    _syncAnimated();
    _paint.relayout();
    return _paint.firstBaseline(size.height);
  }

  /// The laid-out text (tests).
  StageTextLayout get textLayout => _paint;

  final StageAppearanceLayers _layers = StageAppearanceLayers();

  void _onImageReady() {
    if (attached) markNeedsPaint();
  }

  @override
  bool get opacityNeedsLayer => textPartCount(_paint, text.appearance) > 1;

  @override
  bool get hasEffectLayers => layerBlurOf(text.appearance.effects) != null;

  @override
  void paintStage(PaintingContext context, Offset offset) {
    final env = environment;
    _syncAnimated();
    // A paint-only restyle (colour) keeps the box size; the restyled
    // paragraphs lay out again at the same width.
    _paint
      ..relayout()
      ..reveal = _reveal;
    _reveal?.beginPaint();
    final editing = _editing;
    final geometry = editing == null
        ? null
        : StageTextEditingGeometry(_paint, size.height);
    geometry?.paint(context.canvas, offset, editing!, _rendered, under: true);
    paintStageText(
      context: context,
      offset: offset,
      size: size,
      layout: _paint,
      appearance: text.appearance,
      painter: env.painter,
      layers: _layers,
      media: env.media,
      onImageReady: _onImageReady,
      devicePixelRatio: stageDevicePixelRatio(),
      opacity: paintOpacity,
    );
    geometry?.paint(context.canvas, offset, editing!, _rendered, under: false);
  }

  @override
  void dispose() {
    _listening?.removeListener(_fontLoaded);
    _layers.dispose();
    _resetLayouts();
    super.dispose();
  }
}
