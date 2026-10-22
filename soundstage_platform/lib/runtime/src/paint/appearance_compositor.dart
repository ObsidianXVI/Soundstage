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

/// The first visible layer blur, if any, with its typed overrides. A blur
/// whose radius is animated counts even at radius 0, so the node's
/// compositing does not change while it animates.
ir.LayerBlur? layerBlurOf(
  List<ir.Effect> effects, [
  StageAppearanceOverrides? overrides,
]) {
  for (var i = 0; i < effects.length; i++) {
    final e = effects[i];
    if (e is! ir.LayerBlur || !e.visible) continue;
    if (overrides != null && overrides.overridesBlurRadius(e.id)) {
      return overrides.effect(e) as ir.LayerBlur;
    }
    if (e.radius > 0) return e;
  }
  return null;
}

/// The first visible background blur, if any (see [layerBlurOf]).
ir.BackgroundBlur? backgroundBlurOf(
  List<ir.Effect> effects, [
  StageAppearanceOverrides? overrides,
]) {
  for (var i = 0; i < effects.length; i++) {
    final e = effects[i];
    if (e is! ir.BackgroundBlur || !e.visible) continue;
    if (overrides != null && overrides.overridesBlurRadius(e.id)) {
      return overrides.effect(e) as ir.BackgroundBlur;
    }
    if (e.radius > 0) return e;
  }
  return null;
}

bool _hasBlur(
  List<ir.Effect> effects,
  StageAppearanceOverrides? overrides, {
  required bool background,
}) {
  for (var i = 0; i < effects.length; i++) {
    final e = effects[i];
    double radius;
    if (background) {
      if (e is! ir.BackgroundBlur || !e.visible) continue;
      radius = e.radius;
    } else {
      if (e is! ir.LayerBlur || !e.visible) continue;
      radius = e.radius;
    }
    if (radius > 0) return true;
    if (overrides != null && overrides.overridesBlurRadius(e.id)) return true;
  }
  return false;
}

/// Whether [effects] need compositing layers (layer or background blur).
/// Allocation-free (it runs while the animator pushes values).
bool hasLayerEffects(
  List<ir.Effect> effects, [
  StageAppearanceOverrides? overrides,
]) =>
    _hasBlur(effects, overrides, background: false) ||
    _hasBlur(effects, overrides, background: true);

/// Whether [effects] have a background blur (see [hasLayerEffects]).
bool hasBackgroundBlur(
  List<ir.Effect> effects, [
  StageAppearanceOverrides? overrides,
]) => _hasBlur(effects, overrides, background: true);

bool _partVisible(
  ir.Paint p,
  StagePaintStack stack,
  StageAppearanceOverrides? overrides,
) {
  if (paintIsVisible(p)) return true;
  // An animated opacity can make a transparent paint visible: count it, so
  // the opacity-layer decision does not change while it animates.
  return overrides != null && p.visible && overrides.mayHidePaint(stack, p.id);
}

/// How many separately painted parts an appearance has: each visible paint
/// of the fills and of the stroke, and each visible effect. A node with one
/// part can apply its opacity to that part's colour; with more, parts
/// overlap and the opacity needs a group layer (Figma's group opacity).
/// Paints with an animated opacity count as visible. Allocation-free.
int paintedPartCount(
  List<ir.Paint> fills,
  ir.Stroke stroke,
  List<ir.Effect> effects, [
  StageAppearanceOverrides? overrides,
]) {
  var n = 0;
  for (var i = 0; i < fills.length; i++) {
    if (_partVisible(fills[i], StagePaintStack.fills, overrides)) n++;
  }
  final paints = stroke.paints;
  for (var i = 0; i < paints.length; i++) {
    if (_partVisible(paints[i], StagePaintStack.strokes, overrides)) n++;
  }
  for (var i = 0; i < effects.length; i++) {
    if (effectIsVisible(effects[i])) n++;
  }
  return n;
}

/// Whether every fill is an opaque, normally blended solid, so the outline
/// is fully covered. Lets drop shadows skip their knock-out clip. A top fill
/// with typed overrides is not treated as opaque (the knock-out is always
/// correct, only slower).
bool fillsAreOpaque(
  List<ir.Paint> fills, [
  StageAppearanceOverrides? overrides,
]) {
  for (final p in fills.reversed) {
    if (!paintIsVisible(p) &&
        !(overrides != null &&
            p.visible &&
            overrides.mayHidePaint(StagePaintStack.fills, p.id))) {
      continue;
    }
    if (overrides != null &&
        overrides.overridesPaint(StagePaintStack.fills, p.id)) {
      return false;
    }
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
  /// Without [composited] (inside a blended group, which must stay one
  /// canvas layer) the blur is a canvas `saveLayer` with the image filter.
  void paintBlurred(
    PaintingContext context,
    Offset offset,
    ir.LayerBlur? blur,
    PaintingContextCallback content, {
    bool composited = true,
  }) {
    if (blur == null) {
      _blur.layer = null;
      content(context, offset);
      return;
    }
    final sigma = StageAppearancePainter.sigmaForRadius(blur.radius);
    if (!composited) {
      _blur.layer = null;
      final canvas = context.canvas;
      canvas.saveLayer(
        null,
        Paint()
          ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma,
            sigmaY: sigma,
            tileMode: ui.TileMode.decal,
          ),
      );
      content(context, offset);
      if (identical(context.canvas, canvas)) canvas.restore();
      return;
    }
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
///
/// [overrides] are the node's typed animated values, read here at paint
/// time. Without [composited] (a node inside a blended group) the layer blur
/// is a canvas `saveLayer` instead of an `ImageFilterLayer`; a background
/// blur still needs its layers (see the runtime README, blend groups).
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
  StageAppearanceOverrides? overrides,
  bool composited = true,
}) {
  final o = overrides != null && overrides.isEmpty ? null : overrides;
  final effects = appearance.effects;
  final blur = layerBlurOf(effects, o);
  final backdrop = backgroundBlurOf(effects, o);

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
      fillsOpaque: fillsAreOpaque(appearance.fills, o),
      overrides: o,
    );
    painter.paintFills(
      canvas,
      outline,
      appearance.fills,
      media: media,
      onImageReady: onImageReady,
      devicePixelRatio: devicePixelRatio,
      opacity: opacity,
      overrides: o,
    );
    painter.paintInnerShadows(
      canvas,
      outline,
      effects,
      opacity: opacity,
      overrides: o,
    );
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
        overrides: o,
      );
      c.restore();
    }
  }

  layers.paintBlurred(context, offset, blur, content, composited: composited);
}
