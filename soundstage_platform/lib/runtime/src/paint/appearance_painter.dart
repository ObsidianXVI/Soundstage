import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../media/image_cache.dart';
import 'image_scale.dart';
import 'stage_color.dart';

/// The shape a node's appearance paints into, in the node's local
/// coordinates: a (rounded) rectangle for frames, rectangles and videos, or
/// a path for other shapes. Open outlines (lines) only take strokes.
class StageOutline {
  /// A box of [size] with [radius] corners.
  StageOutline.box(Size size, ir.CornerRadius radius)
    : bounds = Offset.zero & size,
      rrect = stageRRect(Offset.zero & size, radius),
      _path = null,
      closed = true;

  /// An arbitrary [path] inside [bounds].
  StageOutline.path(Path path, {required this.bounds, this.closed = true})
    : rrect = null,
      _path = path;

  final Rect bounds;

  /// Set for box outlines.
  final RRect? rrect;
  final Path? _path;

  /// False for open outlines (lines), which have no inside.
  final bool closed;

  Path get path => _path ?? (Path()..addRRect(rrect!));

  /// Clips [canvas] to the outline (no layer: a canvas clip).
  void clip(Canvas canvas) {
    final r = rrect;
    if (r != null) {
      if (r.isRect) {
        canvas.clipRect(r.outerRect);
      } else {
        canvas.clipRRect(r);
      }
    } else {
      canvas.clipPath(path);
    }
  }
}

/// [rect] with [radius] corners. Each radius is clamped to half the shorter
/// side, as in Figma.
RRect stageRRect(Rect rect, ir.CornerRadius radius) {
  final limit = math.max(0.0, math.min(rect.width, rect.height) / 2);
  Radius r(double v) => Radius.circular(v.clamp(0.0, limit));
  return switch (radius) {
    ir.UniformCornerRadius(:final radius) => RRect.fromRectAndRadius(
      rect,
      r(radius),
    ),
    ir.CornerRadii(:final tl, :final tr, :final br, :final bl) =>
      RRect.fromRectAndCorners(
        rect,
        topLeft: r(tl),
        topRight: r(tr),
        bottomRight: r(br),
        bottomLeft: r(bl),
      ),
  };
}

/// Paints node appearances: the seam between render objects and the paint
/// pipeline.
///
/// Render objects call [paintFills] before their content and [paintStroke]
/// after it, with the node's [StageOutline] in local coordinates (the canvas
/// is already translated to the node's box). Clipping and opacity are the
/// render objects' job (canvas clips and opacity layers).
///
/// T0.4 implements a minimal subset so documents are visible:
/// - fills: solid paints, and image paints in `fill` scale mode with
///   `focalPoint` (other scale modes paint as `fill`); the asset's
///   placeholder colour shows while the image loads. Gradients, image
///   filters, paint opacity on images and paint blend modes are skipped.
/// - strokes: the solid paints of the stack, one uniform weight (per-side
///   weights use the largest side), aligned inside/center/outside; caps and
///   joins on open paths. No dashes.
///
/// T0.5 replaces the internals with the full pipeline (gradients, every
/// image scale mode, filters, dashes, per-side strokes, effects, corner
/// smoothing, blend modes). Keep the signatures stable.
class StageAppearancePainter {
  const StageAppearancePainter();

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
  }) {
    if (!outline.closed) return;
    for (final p in fills) {
      if (!_visible(p)) continue;
      switch (p) {
        case ir.SolidPaint(:final color, :final opacity):
          _fillOutline(
            canvas,
            outline,
            Paint()..color = stageColor(color, opacity),
          );
        case ir.ImagePaint():
          _paintImage(
            canvas,
            outline,
            p,
            media,
            onImageReady,
            devicePixelRatio,
          );
        case ir.GradientPaint():
          break; // T0.5
      }
    }
  }

  /// Paints the solid paints of [stroke] around [outline].
  void paintStroke(Canvas canvas, StageOutline outline, ir.Stroke stroke) {
    final weight = switch (stroke.weight) {
      ir.UniformStrokeWeight(:final weight) => weight,
      ir.PerSideStrokeWeight(
        :final top,
        :final right,
        :final bottom,
        :final left,
      ) =>
        math.max(math.max(top, right), math.max(bottom, left)),
    };
    if (weight <= 0) return;
    for (final p in stroke.paints) {
      if (!_visible(p) || p is! ir.SolidPaint) continue;
      final paint = Paint()
        ..color = stageColor(p.color, p.opacity)
        ..style = PaintingStyle.stroke
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
        ..strokeMiterLimit = stroke.miterLimit;
      final align = outline.closed ? stroke.align : ir.StrokeAlign.center;
      final rrect = outline.rrect;
      if (rrect != null) {
        paint.strokeWidth = weight;
        final r = switch (align) {
          ir.StrokeAlign.inside => rrect.deflate(weight / 2),
          ir.StrokeAlign.center => rrect,
          ir.StrokeAlign.outside => rrect.inflate(weight / 2),
        };
        canvas.drawRRect(r, paint);
        continue;
      }
      final path = outline.path;
      switch (align) {
        case ir.StrokeAlign.center:
          canvas.drawPath(path, paint..strokeWidth = weight);
        case ir.StrokeAlign.inside:
          canvas
            ..save()
            ..clipPath(path)
            ..drawPath(path, paint..strokeWidth = weight * 2)
            ..restore();
        case ir.StrokeAlign.outside:
          final outside = Path.combine(
            PathOperation.difference,
            Path()..addRect(outline.bounds.inflate(weight * 2 + 1)),
            path,
          );
          canvas
            ..save()
            ..clipPath(outside)
            ..drawPath(path, paint..strokeWidth = weight * 2)
            ..restore();
      }
    }
  }

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

  void _fillOutline(Canvas canvas, StageOutline outline, Paint paint) {
    final rrect = outline.rrect;
    if (rrect == null) {
      canvas.drawPath(outline.path, paint);
    } else if (rrect.isRect) {
      canvas.drawRect(rrect.outerRect, paint);
    } else {
      canvas.drawRRect(rrect, paint);
    }
  }

  void _paintImage(
    Canvas canvas,
    StageOutline outline,
    ir.ImagePaint p,
    StageMedia? media,
    VoidCallback? onReady,
    double dpr,
  ) {
    if (media == null) return;
    final box = outline.bounds;
    final image = media.image(
      p.assetId,
      targetWidth: box.width * dpr,
      onReady: onReady,
    );
    if (image == null) {
      final placeholder = media.placeholderColor(p.assetId);
      if (placeholder != null) {
        _fillOutline(canvas, outline, Paint()..color = placeholder);
      }
      return;
    }
    final size = Size(image.width.toDouble(), image.height.toDouble());
    final dst = imageFillRect(box.size, size, p.focalPoint).shift(box.topLeft);
    canvas
      ..save()
      ..clipRect(box);
    outline.clip(canvas);
    canvas
      ..drawImageRect(
        image,
        Offset.zero & size,
        dst,
        Paint()
          ..filterQuality = ui.FilterQuality.medium
          ..isAntiAlias = true,
      )
      ..restore();
  }
}
