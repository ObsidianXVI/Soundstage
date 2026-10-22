import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../media/image_cache.dart';
import '../../paint/appearance_compositor.dart';
import '../../paint/appearance_painter.dart';
import '../../paint/blend.dart';
import '../../paint/stage_color.dart';
import '../../paint/stroke_geometry.dart';
import '../../paint/text_variant.dart';
import 'stage_text_layout.dart';

/// How many separately painted parts a text node has (see
/// [paintedPartCount]): its simple-colour fill, each glyph-masked fill
/// group, each stroke paint and each visible effect.
int textPartCount(StageTextLayout layout, ir.TextAppearance a) {
  var n = layout.complexFillGroups.length + (layout.hasSimpleFill ? 1 : 0);
  for (final p in a.strokes.paints) {
    if (paintIsVisible(p)) n++;
  }
  for (final e in a.effects) {
    if (effectIsVisible(e)) n++;
  }
  return n;
}

/// Paints a text node: drop shadows, fills, then the stroke, inside the
/// layer blur if any (architecture §5, §7).
///
/// - **Simple fills** (one solid per span) are glyph colours; the layout is
///   painted once with no layer.
/// - **Complex fills** (gradient, image, stacked or blended) paint the fill
///   stack over the node box, then keep only the glyphs: two `saveLayer`s
///   per distinct fill stack (the stack, and the glyph mask composited with
///   `dstIn`).
/// - **Strokes** are outlined glyphs. A single solid centred stroke is
///   painted directly. Other strokes (gradient fills, inside/outside
///   alignment) use the glyph-mask path: inside is the double-width outline
///   `dstIn` the glyphs, outside is `dstOut`.
/// - **Drop shadows** repaint the glyphs in the shadow colour in a layer;
///   blurred shadows add an image-filter layer, and shadows hidden behind
///   translucent glyphs (the default) add a `dstOut` knock-out layer. Text
///   has no spread. Inner shadows and background blur do not apply to text.
void paintStageText({
  required PaintingContext context,
  required Offset offset,
  required Size size,
  required StageTextLayout layout,
  required ir.TextAppearance appearance,
  required StageAppearancePainter painter,
  required StageAppearanceLayers layers,
  StageMedia? media,
  VoidCallback? onImageReady,
  double devicePixelRatio = 1,
  double opacity = 1,
}) {
  final effects = appearance.effects;
  final box = Offset.zero & size;
  final textSize = layout.size;
  final dy = layout.alignOffset(size.height);
  final stroke = appearance.strokes;
  final weights = sideWeights(stroke.weight);
  var reach = weights.max * 2 + 4;
  for (final e in effects) {
    if (e is ir.DropShadow && e.visible) {
      reach = math.max(
        reach,
        e.blur * 2 + e.offset.x.abs() + e.offset.y.abs() + 4,
      );
    }
  }
  final content = box
      .expandToInclude(Rect.fromLTWH(0, dy, textSize.width, textSize.height))
      .inflate(reach);

  void run(PaintingContext ctx, Offset off) {
    final canvas = ctx.canvas
      ..save()
      ..translate(off.dx, off.dy);
    final h = size.height;

    // Drop shadows.
    for (final e in effects) {
      if (e is! ir.DropShadow || !e.visible) continue;
      final sigma = StageAppearancePainter.sigmaForRadius(e.blur);
      final knockOut = !e.showBehindTransparentAreas && !layout.fillsAreOpaque;
      canvas.saveLayer(
        content.inflate(sigma * 3),
        Paint()..blendMode = flutterBlendMode(e.blendMode),
      );
      if (sigma > 0) {
        canvas.saveLayer(
          content.inflate(sigma * 3),
          Paint()
            ..imageFilter = ui.ImageFilter.blur(
              sigmaX: sigma,
              sigmaY: sigma,
              tileMode: ui.TileMode.decal,
            ),
        );
      }
      canvas.save();
      canvas.translate(e.offset.x, e.offset.y);
      layout.paint(
        canvas,
        Offset.zero,
        h,
        variant: StageTextVariant.shadow(stageColor(e.color, opacity)),
      );
      canvas.restore();
      if (sigma > 0) canvas.restore();
      if (knockOut) {
        canvas.saveLayer(content, Paint()..blendMode = ui.BlendMode.dstOut);
        layout.paint(
          canvas,
          Offset.zero,
          h,
          variant: const StageTextVariant.mask(),
        );
        canvas.restore();
      }
      canvas.restore();
    }

    // Fills.
    final groups = layout.complexFillGroups;
    if (groups.isEmpty && opacity == 1) {
      layout.paint(canvas, Offset.zero, h);
    } else {
      layout.paint(
        canvas,
        Offset.zero,
        h,
        variant: StageTextVariant.base(opacity: opacity),
      );
    }
    for (final group in groups) {
      _paintMasked(
        canvas,
        painter,
        box,
        content,
        group,
        (c) => layout.paint(
          c,
          Offset.zero,
          h,
          variant: StageTextVariant.mask(fills: group),
        ),
        media: media,
        onImageReady: onImageReady,
        devicePixelRatio: devicePixelRatio,
        opacity: opacity,
      );
    }

    // Stroke.
    final visibleStroke = [
      for (final p in stroke.paints)
        if (paintIsVisible(p)) p,
    ];
    if (visibleStroke.isNotEmpty && !weights.isZero) {
      final w = weights.max;
      final join = switch (stroke.join) {
        ir.StrokeJoin.miter => ui.StrokeJoin.miter,
        ir.StrokeJoin.bevel => ui.StrokeJoin.bevel,
        ir.StrokeJoin.round => ui.StrokeJoin.round,
      };
      final only = visibleStroke.length == 1 ? visibleStroke.first : null;
      if (only is ir.SolidPaint &&
          only.blendMode == ir.BlendMode.normal &&
          stroke.align == ir.StrokeAlign.center) {
        layout.paint(
          canvas,
          Offset.zero,
          h,
          variant: StageTextVariant.stroke(
            width: w,
            color: stageColor(only.color, only.opacity * opacity),
            join: join,
            miterLimit: stroke.miterLimit,
          ),
        );
      } else {
        final doubled = stroke.align == ir.StrokeAlign.center ? w : w * 2;
        _paintMasked(
          canvas,
          painter,
          box,
          content,
          visibleStroke,
          (c) {
            layout.paint(
              c,
              Offset.zero,
              h,
              variant: StageTextVariant.stroke(
                width: doubled,
                color: const Color(0xFF000000),
                join: join,
                miterLimit: stroke.miterLimit,
              ),
            );
            if (stroke.align != ir.StrokeAlign.center) {
              c.saveLayer(
                content,
                Paint()
                  ..blendMode = stroke.align == ir.StrokeAlign.inside
                      ? ui.BlendMode.dstIn
                      : ui.BlendMode.dstOut,
              );
              layout.paint(
                c,
                Offset.zero,
                h,
                variant: const StageTextVariant.mask(),
              );
              c.restore();
            }
          },
          media: media,
          onImageReady: onImageReady,
          devicePixelRatio: devicePixelRatio,
          opacity: opacity,
        );
      }
    }
    canvas.restore();
  }

  layers.paintBlurred(context, offset, layerBlurOf(effects), run);
}

/// Paints [paints] through the alpha of whatever [drawMask] draws: the stack
/// is drawn over [content] in a layer, then the mask is composited with
/// `dstIn` in a second layer, so only the masked pixels keep the fill.
void _paintMasked(
  Canvas canvas,
  StageAppearancePainter painter,
  Rect box,
  Rect content,
  List<ir.Paint> paints,
  void Function(Canvas) drawMask, {
  StageMedia? media,
  VoidCallback? onImageReady,
  double devicePixelRatio = 1,
  double opacity = 1,
}) {
  canvas.saveLayer(content, Paint());
  painter.paintStack(
    canvas,
    box,
    paints,
    opacity: opacity,
    draw: (p) => canvas.drawRect(content, p),
    clipToRegion: (c) => c.clipRect(content),
    media: media,
    onImageReady: onImageReady,
    devicePixelRatio: devicePixelRatio,
  );
  canvas.saveLayer(content, Paint()..blendMode = ui.BlendMode.dstIn);
  drawMask(canvas);
  canvas
    ..restore()
    ..restore();
}
