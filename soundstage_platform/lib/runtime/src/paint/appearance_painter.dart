import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../media/image_cache.dart';
import 'blend.dart';
import 'gradient.dart';
import 'image_filters.dart';
import 'image_scale.dart';
import 'outline.dart';
import 'stage_color.dart';
import 'stroke_geometry.dart';

export 'outline.dart';

/// Paints node appearances: the seam between render objects and the paint
/// pipeline (architecture §5, §6).
///
/// Render objects call these with the node's [StageOutline] in local
/// coordinates (the canvas is already translated to the node's box):
/// [paintDropShadows], then [paintFills], then [paintInnerShadows], then
/// (frames) children, then [paintStroke]. Layer effects (layer and
/// background blur) need compositing layers and are applied around all of
/// that by `paintStageAppearance` (`appearance_compositor.dart`). Clipping
/// to the node, group opacity and node blend modes stay in the render
/// objects.
///
/// Everything here draws straight onto the canvas: no method opens a
/// `saveLayer`, except text masks (see `text_paint.dart`). Each paint's own
/// `blendMode` is the canvas blend mode of its draw call, so it blends with
/// what is already on the canvas, which is the stack below it.
///
/// The `opacity` arguments multiply into every paint and effect colour. A
/// render object passes the node opacity here instead of opening an
/// opacity layer when the node has a single painted part.
class StageAppearancePainter {
  const StageAppearancePainter();

  // ---- Fills --------------------------------------------------------------------

  /// Paints [fills] bottom to top inside [outline]. Image fills come from
  /// [media]; when an image is still loading, [onImageReady] is called once
  /// it is (render objects pass `markNeedsPaint`). [devicePixelRatio] picks
  /// the asset variant.
  void paintFills(
    Canvas canvas,
    StageOutline outline,
    List<ir.Paint> fills, {
    StageMedia? media,
    VoidCallback? onImageReady,
    double devicePixelRatio = 1,
    double opacity = 1,
  }) {
    if (!outline.closed) return;
    paintStack(
      canvas,
      outline.bounds,
      fills,
      opacity: opacity,
      draw: (p) => outline.fill(canvas, p),
      clipToRegion: outline.clip,
      media: media,
      onImageReady: onImageReady,
      devicePixelRatio: devicePixelRatio,
    );
  }

  /// Paints a paint stack over a region described by two callbacks: [draw]
  /// fills the region with a simple `Paint` (solid or shader), and
  /// [clipToRegion] clips the canvas to it (used by diamond meshes and
  /// images, which cannot be drawn through a `Paint`). [box] is the node box
  /// that gradients and images are mapped to. Without [clipToRegion], mesh
  /// and image paints are skipped (a diamond falls back to its first stop).
  void paintStack(
    Canvas canvas,
    Rect box,
    List<ir.Paint> paints, {
    required void Function(Paint) draw,
    void Function(Canvas)? clipToRegion,
    StageMedia? media,
    VoidCallback? onImageReady,
    double devicePixelRatio = 1,
    double opacity = 1,
  }) {
    for (final p in paints) {
      if (!_visible(p)) continue;
      switch (p) {
        case ir.SolidPaint():
          draw(
            Paint()
              ..color = stageColor(p.color, p.opacity * opacity)
              ..blendMode = flutterBlendMode(p.blendMode),
          );
        case ir.GradientPaint():
          final o = p.opacity * opacity;
          if (p.kind == ir.GradientKind.diamond) {
            _paintDiamond(canvas, box, p, o, draw, clipToRegion);
            continue;
          }
          final shader = gradientShader(p, box.size, o);
          if (shader == null) continue;
          draw(
            Paint()
              ..shader = shader
              ..blendMode = flutterBlendMode(p.blendMode),
          );
        case ir.ImagePaint():
          if (clipToRegion == null) continue;
          _paintImage(
            canvas,
            box,
            p,
            opacity,
            clipToRegion,
            media,
            onImageReady,
            devicePixelRatio,
          );
      }
    }
  }

  void _paintDiamond(
    Canvas canvas,
    Rect box,
    ir.GradientPaint p,
    double opacity,
    void Function(Paint) draw,
    void Function(Canvas)? clipToRegion,
  ) {
    if (clipToRegion == null) {
      // No region to clip a mesh to (native strokes): the first stop.
      if (p.stops.isEmpty) return;
      draw(
        Paint()
          ..color = stageColor(p.stops.first.color, opacity)
          ..blendMode = flutterBlendMode(p.blendMode),
      );
      return;
    }
    final mesh = diamondMesh(p, box.size, opacity);
    if (mesh == null) return;
    final vertices = mesh.toVertices();
    canvas.save();
    clipToRegion(canvas);
    canvas
      ..translate(box.left, box.top)
      ..drawVertices(
        vertices,
        ui.BlendMode.src,
        Paint()..blendMode = flutterBlendMode(p.blendMode),
      )
      ..restore();
    vertices.dispose();
  }

  void _paintImage(
    Canvas canvas,
    Rect box,
    ir.ImagePaint p,
    double opacity,
    void Function(Canvas) clipToRegion,
    StageMedia? media,
    VoidCallback? onReady,
    double dpr,
  ) {
    if (media == null) return;
    final quarter = quarterTurnsOf(p.rotation);
    // Pick the variant for the width the image is rendered at (§6): ask
    // with the original's geometry when the asset declares it.
    final intrinsic = media.intrinsicSize(p.assetId);
    final shownIntrinsic = intrinsic == null
        ? null
        : rotatedImageSize(intrinsic, quarter);
    var target = box.width * dpr;
    if (shownIntrinsic != null) {
      final plan = placeImage(
        box: box.size,
        image: shownIntrinsic,
        mode: p.scaleMode,
        focalPoint: p.focalPoint,
        cropRect: p.cropRect,
        tileScale: p.tileScale,
      );
      final scale = plan.src.width == 0 ? 1.0 : plan.dst.width / plan.src.width;
      // The width of the whole (unrotated) image on screen.
      target =
          (quarter.isOdd ? shownIntrinsic.height : shownIntrinsic.width) *
          scale *
          dpr;
    }
    final image = media.image(p.assetId, targetWidth: target, onReady: onReady);
    if (image == null) {
      final placeholder = media.placeholderColor(p.assetId);
      if (placeholder != null) {
        canvas.save();
        clipToRegion(canvas);
        canvas.drawRect(
          box,
          Paint()
            ..color = placeholder.withValues(alpha: placeholder.a * opacity),
        );
        canvas.restore();
      }
      return;
    }
    final decoded = Size(image.width.toDouble(), image.height.toDouble());
    final shown = rotatedImageSize(decoded, quarter);
    final placement = placeImage(
      box: box.size,
      image: shown,
      mode: p.scaleMode,
      focalPoint: p.focalPoint,
      cropRect: p.cropRect,
      tileScale: p.tileScale,
      intrinsic: shownIntrinsic,
    );
    final matrix = imageTransform(placement, decoded, quarter);
    final paint = Paint()
      ..isAntiAlias = true
      ..filterQuality = FilterQuality.medium
      ..blendMode = flutterBlendMode(p.blendMode)
      ..color = const Color(0xFFFFFFFF).withValues(alpha: p.opacity * opacity);
    final filter = imageColorFilter(p.filters);
    if (filter != null) paint.colorFilter = filter;

    canvas.save();
    clipToRegion(canvas);
    canvas
      ..clipRect(box)
      ..translate(box.left, box.top);
    if (placement.tile) {
      paint.shader = ui.ImageShader(
        image,
        ui.TileMode.repeated,
        ui.TileMode.repeated,
        matrix.storage,
        filterQuality: FilterQuality.medium,
      );
      canvas.drawRect(Offset.zero & box.size, paint);
    } else {
      canvas
        ..transform(matrix.storage)
        ..drawImageRect(
          image,
          Offset.zero & decoded,
          Offset.zero & decoded,
          paint,
        );
    }
    canvas.restore();
  }

  // ---- Strokes ------------------------------------------------------------------

  /// Paints the paint stack of [stroke] around [outline].
  ///
  /// - Box outlines without dashes (and with the default miter join, or
  ///   per-side weights) are drawn as a filled band between an inner and an
  ///   outer outline, so inside/center/outside alignment and per-side
  ///   weights are exact and gradient, diamond and image paints work.
  /// - Otherwise (paths, dashes, round or bevel joins) the outline is
  ///   stroked natively: centre strokes directly, inside/outside strokes at
  ///   double width clipped to the inside or outside of the outline. Diamond
  ///   paints fall back to their first stop and image paints are skipped.
  /// - Per-side weights apply to box outlines only; other shapes use the
  ///   largest side. Lines are always centred.
  void paintStroke(
    Canvas canvas,
    StageOutline outline,
    ir.Stroke stroke, {
    StageMedia? media,
    VoidCallback? onImageReady,
    double devicePixelRatio = 1,
    double opacity = 1,
  }) {
    var w = sideWeights(stroke.weight);
    if (w.isZero || stroke.paints.isEmpty) return;
    final align = outline.closed ? stroke.align : ir.StrokeAlign.center;
    final dashed = stroke.dash.any((d) => d > 0);
    final band =
        outline.isBox &&
        !dashed &&
        (!w.isUniform || stroke.join == ir.StrokeJoin.miter);
    if (band) {
      final path = strokeBandPath(outline, align, w);
      paintStack(
        canvas,
        outline.bounds,
        stroke.paints,
        opacity: opacity,
        draw: (p) => canvas.drawPath(path, p),
        clipToRegion: (c) => c.clipPath(path),
        media: media,
        onImageReady: onImageReady,
        devicePixelRatio: devicePixelRatio,
      );
      return;
    }
    if (!w.isUniform) w = SideWeights.uniform(w.max);
    final weight = w.top;
    final path = dashed ? dashPath(outline.path, stroke.dash) : outline.path;
    ui.Path? outsideClip;
    if (align == ir.StrokeAlign.outside) {
      outsideClip = complementPath(
        outline.bounds.inflate(weight * 2 + 2),
        outline.path,
      );
    }
    canvas.save();
    switch (align) {
      case ir.StrokeAlign.center:
        break;
      case ir.StrokeAlign.inside:
        outline.clip(canvas);
      case ir.StrokeAlign.outside:
        canvas.clipPath(outsideClip!);
    }
    final strokeWidth = align == ir.StrokeAlign.center ? weight : weight * 2;
    paintStack(
      canvas,
      outline.bounds,
      stroke.paints,
      opacity: opacity,
      draw: (p) => canvas.drawPath(
        path,
        p
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = switch (stroke.cap) {
            ir.StrokeCap.none => StrokeCap.butt,
            ir.StrokeCap.round => StrokeCap.round,
            ir.StrokeCap.square => StrokeCap.square,
          }
          ..strokeJoin = switch (stroke.join) {
            ir.StrokeJoin.miter => StrokeJoin.miter,
            ir.StrokeJoin.bevel => StrokeJoin.bevel,
            ir.StrokeJoin.round => StrokeJoin.round,
          }
          ..strokeMiterLimit = stroke.miterLimit,
      ),
    );
    canvas.restore();
  }

  // ---- Shadows ------------------------------------------------------------------

  /// The sigma of a Gaussian blur for a Figma blur [radius] (Figma's radius
  /// is twice the standard deviation, as in CSS `box-shadow`).
  static double sigmaForRadius(double radius) => radius <= 0 ? 0 : radius / 2;

  /// Paints the visible drop shadows of [effects], beneath the fills.
  ///
  /// Shadows follow the outline (not the painted pixels). Unless
  /// `showBehindTransparentAreas` is set, the shadow is knocked out inside
  /// the outline, so translucent fills do not show it. [fillsOpaque] skips
  /// that knock-out when the fills already cover the outline.
  void paintDropShadows(
    Canvas canvas,
    StageOutline outline,
    List<ir.Effect> effects, {
    double opacity = 1,
    bool fillsOpaque = false,
  }) {
    if (!outline.closed) return;
    for (final e in effects) {
      if (e is! ir.DropShadow || !e.visible) continue;
      final shape = _spread(outline, e.spread);
      final paint = Paint()
        ..color = stageColor(e.color, opacity)
        ..blendMode = flutterBlendMode(e.blendMode);
      final sigma = sigmaForRadius(e.blur);
      if (sigma > 0) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);
      }
      canvas.save();
      if (!e.showBehindTransparentAreas && !fillsOpaque) {
        final reach = outline.bounds.inflate(
          e.blur * 2 + e.offset.x.abs() + e.offset.y.abs() + e.spread.abs() + 8,
        );
        canvas.clipPath(complementPath(reach, outline.path));
      }
      canvas
        ..translate(e.offset.x, e.offset.y)
        ..drawPath(shape.path, paint)
        ..restore();
    }
  }

  /// Paints the visible inner shadows of [effects], inside the outline and
  /// above the fills: the blurred, offset complement of the outline
  /// (shrunk by `spread`), clipped to the outline.
  void paintInnerShadows(
    Canvas canvas,
    StageOutline outline,
    List<ir.Effect> effects, {
    double opacity = 1,
  }) {
    if (!outline.closed) return;
    for (final e in effects) {
      if (e is! ir.InnerShadow || !e.visible) continue;
      final hole = _spread(outline, -e.spread);
      final reach = outline.bounds.inflate(
        e.blur * 3 + e.offset.x.abs() + e.offset.y.abs() + e.spread.abs() + 8,
      );
      final ring = complementPath(
        reach,
        hole.path.shift(Offset(e.offset.x, e.offset.y)),
      );
      final paint = Paint()
        ..color = stageColor(e.color, opacity)
        ..blendMode = flutterBlendMode(e.blendMode);
      final sigma = sigmaForRadius(e.blur);
      if (sigma > 0) {
        paint.maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);
      }
      canvas.save();
      outline.clip(canvas);
      canvas
        ..drawPath(ring, paint)
        ..restore();
    }
  }

  /// [outline] grown by [spread] (negative shrinks). Box outlines grow
  /// exactly, with concentric corners. Other shapes scale about their centre
  /// (an approximation, but it keeps the shape and avoids stroking the
  /// outline into a region).
  static StageOutline _spread(StageOutline outline, double spread) {
    if (spread == 0) return outline;
    final grown = outline.inflated(spread);
    if (grown != null) return grown;
    final b = outline.bounds;
    final sx = b.width <= 0
        ? 1.0
        : math.max(0.0, (b.width + 2 * spread) / b.width);
    final sy = b.height <= 0
        ? 1.0
        : math.max(0.0, (b.height + 2 * spread) / b.height);
    final m = Matrix4.identity()
      ..translateByDouble(b.center.dx, b.center.dy, 0, 1)
      ..scaleByDouble(sx, sy, 1, 1)
      ..translateByDouble(-b.center.dx, -b.center.dy, 0, 1);
    return StageOutline.path(
      outline.path.transform(m.storage),
      bounds: b.inflate(spread),
    );
  }

  // ---- Fault box ----------------------------------------------------------------

  /// The edit-mode error box for a node that failed to lay out or paint, or
  /// a placeholder for something that failed to resolve (§17.2).
  void paintErrorBox(Canvas canvas, Rect rect) {
    const red = Color(0xFFE5484D);
    final r = rect.isEmpty ? Rect.fromLTWH(rect.left, rect.top, 24, 24) : rect;
    canvas.drawRect(r, Paint()..color = const Color(0x33E5484D));
    final line = Paint()
      ..color = red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas
      ..drawRect(r.deflate(0.5), line)
      ..drawLine(r.topLeft, r.bottomRight, line)
      ..drawLine(r.topRight, r.bottomLeft, line);
  }

  static bool _visible(ir.Paint p) => switch (p) {
    ir.SolidPaint(:final visible, :final opacity) ||
    ir.GradientPaint(:final visible, :final opacity) ||
    ir.ImagePaint(:final visible, :final opacity) => visible && opacity > 0,
  };
}
