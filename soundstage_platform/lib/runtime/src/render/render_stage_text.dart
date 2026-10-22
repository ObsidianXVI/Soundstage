import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../paint/appearance_compositor.dart';
import 'render_stage_box.dart';
import 'render_stage_frame.dart' show stageDevicePixelRatio;
import 'stage_environment.dart';
import 'text/stage_text_layout.dart';
import 'text/text_paint.dart';

/// Rich text (architecture §7), laid out from the resolved paragraphs only
/// (the resolver has merged every span's style; this never merges styles).
///
/// Natural size by `autoResize`: `widthAndHeight` hugs both axes without
/// wrapping, `height` wraps at its width and hugs height, `fixed` and
/// `truncate` keep the stored box. A width imposed by the parent (fill,
/// stretch constraints, max width) wraps the text. A `hug` layoutChild
/// sizing also makes the node hug that axis.
class RenderStageText extends RenderStageBox {
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
    _resetLayouts();
    markNeedsCompositingBitsUpdate();
    markStageLayoutDirty();
  }

  StageTextSettings _settings;

  StageTextLayout? _measureLayout;
  StageTextLayout? _paintLayout;

  StageTextLayout get _measure => _measureLayout ??= _newLayout();
  StageTextLayout get _paint => _paintLayout ??= _newLayout();

  StageTextLayout _newLayout() => StageTextLayout(
    paragraphs: _paragraphs,
    fonts: environment.fonts,
    settings: _settings,
  );

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
      return StageInvalidation.layout;
    }
    return StageInvalidation.paint;
  }

  Size _resolve(BoxConstraints c, StageTextLayout l) {
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
  double? get firstBaseline => _paint.firstBaseline(size.height);

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
  }

  @override
  void dispose() {
    _layers.dispose();
    _resetLayouts();
    super.dispose();
  }
}
