import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../media/image_cache.dart';
import 'appearance_painter.dart';

/// Whether [p] is visible and not fully transparent.
bool paintIsVisible(ir.Paint p) => switch (p) {
  ir.SolidPaint(:final visible, :final opacity) ||
  ir.GradientPaint(:final visible, :final opacity) ||
  ir.ImagePaint(:final visible, :final opacity) => visible && opacity > 0,
};

bool effectIsVisible(ir.Effect e) => switch (e) {
  ir.DropShadow(:final visible) ||
  ir.InnerShadow(:final visible) ||
  ir.LayerBlur(:final visible) ||
  ir.BackgroundBlur(:final visible) => visible,
};

/// The first visible layer blur, if any.
ir.LayerBlur? layerBlurOf(List<ir.Effect> effects) {
  for (final e in effects) {
    if (e is ir.LayerBlur && e.visible && e.radius > 0) return e;
  }
  return null;
}

/// The first visible background blur, if any.
ir.BackgroundBlur? backgroundBlurOf(List<ir.Effect> effects) {
  for (final e in effects) {
    if (e is ir.BackgroundBlur && e.visible && e.radius > 0) return e;
  }
  return null;
}

/// Whether [effects] need compositing layers (layer or background blur).
bool hasLayerEffects(List<ir.Effect> effects) =>
    layerBlurOf(effects) != null || backgroundBlurOf(effects) != null;

/// How many separately painted parts an appearance has: each visible paint
/// of the fills and of the stroke, and each visible effect. A node with one
/// part can apply its opacity to that part's colour; with more, parts
/// overlap and the opacity needs a group layer (Figma's group opacity).
int paintedPartCount(
  List<ir.Paint> fills,
  ir.Stroke stroke,
  List<ir.Effect> effects,
) {
  var n = 0;
  for (final p in fills) {
    if (paintIsVisible(p)) n++;
  }
  for (final p in stroke.paints) {
    if (paintIsVisible(p)) n++;
  }
  for (final e in effects) {
    if (effectIsVisible(e)) n++;
  }
  return n;
}

/// Whether every fill is an opaque, normally blended solid, so the outline
/// is fully covered. Lets drop shadows skip their knock-out clip.
bool fillsAreOpaque(List<ir.Paint> fills) {
  for (final p in fills.reversed) {
    if (!paintIsVisible(p)) continue;
    if (p is ir.SolidPaint &&
        p.opacity >= 1 &&
        p.color.a >= 1 &&
        p.blendMode == ir.BlendMode.normal) {
      return true;
    }
    return false;
  }
  return false;
}

/// The compositing layers a node reuses between paints: its layer blur, the
/// clip and backdrop filter of a background blur, and the content clip of a
/// frame. Render objects own one and call [dispose] when they are disposed.
class StageAppearanceLayers {
  final LayerHandle<ImageFilterLayer> _blur = LayerHandle<ImageFilterLayer>();
  final LayerHandle<ClipPathLayer> _backdropClip = LayerHandle<ClipPathLayer>();
  final LayerHandle<BackdropFilterLayer> _backdrop =
      LayerHandle<BackdropFilterLayer>();
  final LayerHandle<ClipRRectLayer> _clipRRect = LayerHandle<ClipRRectLayer>();
  final LayerHandle<ClipPathLayer> _clipPath = LayerHandle<ClipPathLayer>();

  /// Pushes a clip to [outline] (a rounded-rect clip, or a path clip for
  /// smoothed corners) around [painter].
  void pushOutlineClip(
    bool needsCompositing,
    PaintingContext context,
    Offset offset,
    StageOutline outline,
    PaintingContextCallback painter,
  ) {
    final rrect = outline.rrect;
    if (rrect != null) {
      _clipPath.layer = null;
      _clipRRect.layer = context.pushClipRRect(
        needsCompositing,
        offset,
        outline.bounds,
        rrect,
        painter,
        clipBehavior: rrect.isRect ? Clip.hardEdge : Clip.antiAlias,
        oldLayer: _clipRRect.layer,
      );
    } else {
      _clipRRect.layer = null;
      _clipPath.layer = context.pushClipPath(
        needsCompositing,
        offset,
        outline.bounds,
        outline.path,
        painter,
        clipBehavior: Clip.antiAlias,
        oldLayer: _clipPath.layer,
      );
    }
  }

  /// Paints [content] into a layer blurred by [blur] (null = no blur, no
  /// layer). The content gets offset zero: the layer places it at [offset].
  void paintBlurred(
    PaintingContext context,
    Offset offset,
    ir.LayerBlur? blur,
    PaintingContextCallback content,
  ) {
    if (blur == null) {
      _blur.layer = null;
      content(context, offset);
      return;
    }
    final sigma = StageAppearancePainter.sigmaForRadius(blur.radius);
    final layer = _blur.layer ??= ImageFilterLayer();
    layer
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: ui.TileMode.decal,
      )
      ..offset = offset;
    context.pushLayer(layer, content, Offset.zero);
  }

  void releaseClip() {
    _clipRRect.layer = null;
    _clipPath.layer = null;
  }

  void dispose() {
    _blur.layer = null;
    _backdropClip.layer = null;
    _backdrop.layer = null;
    _clipRRect.layer = null;
    _clipPath.layer = null;
  }
}

/// Paints a node's appearance in order (architecture §5): background blur,
/// then, inside the layer blur if any, drop shadows, fills, inner shadows,
/// [paintChildren], and the stroke.
///
/// Layer costs: a layer blur is one `ImageFilterLayer` (an offscreen
/// buffer the size of the node's paint bounds, blurred when composited); a
/// background blur is a clip layer plus a `BackdropFilterLayer`, which
/// copies and blurs what is behind the node every frame it repaints. Both
/// exist only when the node has that effect. Shadows, fills and strokes
/// draw straight onto the canvas.
void paintStageAppearance({
  required PaintingContext context,
  required Offset offset,
  required StageAppearancePainter painter,
  required StageAppearanceLayers layers,
  required StageOutline outline,
  required ir.Appearance appearance,
  StageMedia? media,
  VoidCallback? onImageReady,
  double devicePixelRatio = 1,
  double opacity = 1,
  PaintingContextCallback? paintChildren,
}) {
  final effects = appearance.effects;
  final blur = layerBlurOf(effects);
  final backdrop = backgroundBlurOf(effects);

  if (backdrop != null && outline.closed) {
    final sigma = StageAppearancePainter.sigmaForRadius(backdrop.radius);
    layers._backdropClip.layer = context.pushClipPath(
      true,
      offset,
      outline.bounds,
      outline.path,
      (c, o) {
        final layer = layers._backdrop.layer ??= BackdropFilterLayer();
        layer.filter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
        c.pushLayer(layer, (_, _) {}, Offset.zero);
      },
      clipBehavior: Clip.antiAlias,
      oldLayer: layers._backdropClip.layer,
    );
  } else {
    layers._backdropClip.layer = null;
    layers._backdrop.layer = null;
  }

  void content(PaintingContext ctx, Offset off) {
    final canvas = ctx.canvas
      ..save()
      ..translate(off.dx, off.dy);
    painter.paintDropShadows(
      canvas,
      outline,
      effects,
      opacity: opacity,
      fillsOpaque: fillsAreOpaque(appearance.fills),
    );
    painter.paintFills(
      canvas,
      outline,
      appearance.fills,
      media: media,
      onImageReady: onImageReady,
      devicePixelRatio: devicePixelRatio,
      opacity: opacity,
    );
    painter.paintInnerShadows(canvas, outline, effects, opacity: opacity);
    canvas.restore();
    paintChildren?.call(ctx, off);
    if (appearance.strokes.paints.isNotEmpty) {
      final c = ctx.canvas
        ..save()
        ..translate(off.dx, off.dy);
      painter.paintStroke(
        c,
        outline,
        appearance.strokes,
        media: media,
        onImageReady: onImageReady,
        devicePixelRatio: devicePixelRatio,
        opacity: opacity,
      );
      c.restore();
    }
  }

  layers.paintBlurred(context, offset, blur, content);
}
