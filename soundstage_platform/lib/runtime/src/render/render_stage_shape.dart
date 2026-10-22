import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../paint/appearance_compositor.dart';
import 'render_stage_box.dart';
import 'render_stage_frame.dart' show stageDevicePixelRatio;
import 'shape_geometry.dart';

/// A primitive shape (architecture §4.1): rectangle, ellipse (with arc and
/// inner radius), line, polygon or star. Shapes never hug; their natural
/// size is their stored size.
///
/// Until their runtimes land, video (M3) and embed (M3) nodes also render
/// through this box: a video paints its appearance (fills show behind where
/// the video will be), an embed paints nothing.
class RenderStageShape extends RenderStageBox {
  RenderStageShape({
    required super.node,
    required super.environment,
    super.repaintBoundary,
  });

  ir.ShapeGeometry get geometry => switch (node) {
    ir.ShapeNode(:final geometry) => geometry,
    _ => const ir.ShapeGeometry.rectangle(),
  };

  ir.Appearance get appearance => switch (node) {
    ir.ShapeNode(:final appearance) ||
    ir.VideoNode(:final appearance) => appearance,
    _ => const ir.Appearance(),
  };

  @override
  bool get supportsAppearanceOverrides => true;

  @override
  EdgeInsets get strokeOutsets {
    final o = appearanceOverrides;
    final s = o == null ? appearance.strokes : o.stroke(appearance.strokes);
    // Lines have no inside: their stroke is always centred.
    return geometry is ir.LineGeometry
        ? strokeOutsetsOf(s.copyWith(align: ir.StrokeAlign.center))
        : strokeOutsetsOf(s);
  }

  @override
  StageInvalidation invalidationFor(ir.Node old, ir.Node next) {
    var i = super.invalidationFor(old, next);
    if (old.runtimeType != next.runtimeType) return StageInvalidation.layout;
    final oa = switch (old) {
      ir.ShapeNode(:final appearance) ||
      ir.VideoNode(:final appearance) => appearance,
      _ => null,
    };
    final na = appearance;
    if (oa != null && !identical(oa, na)) {
      i = maxInvalidation(
        i,
        identical(oa.strokes, na.strokes)
            ? StageInvalidation.paint
            : StageInvalidation.layout,
      );
    }
    if (old is ir.ShapeNode &&
        next is ir.ShapeNode &&
        !identical(old.geometry, next.geometry)) {
      i = maxInvalidation(i, StageInvalidation.paint);
    }
    return i;
  }

  @override
  Size computeStageDryLayout(BoxConstraints constraints) =>
      constraints.constrain(storedSize);

  @override
  Size performStageLayout() => constraints.constrain(storedSize);

  final StageAppearanceLayers _layers = StageAppearanceLayers();

  void _onImageReady() {
    if (attached) markNeedsPaint();
  }

  @override
  bool get opacityNeedsLayer =>
      paintedPartCount(
        appearance.fills,
        appearance.strokes,
        appearance.effects,
        appearanceOverrides,
      ) >
      1;

  @override
  bool get hasEffectLayers => inBlendGroup
      ? hasBackgroundBlur(appearance.effects, appearanceOverrides)
      : hasLayerEffects(appearance.effects, appearanceOverrides);

  @override
  void paintStage(PaintingContext context, Offset offset) {
    final a = appearance;
    if (a.fills.isEmpty && a.strokes.paints.isEmpty && a.effects.isEmpty) {
      return;
    }
    final o = appearanceOverrides;
    final outline = shapeOutline(
      geometry,
      size,
      cornerRadius: o == null ? a.cornerRadius : o.cornerRadius(a.cornerRadius),
      cornerSmoothing: o == null
          ? a.cornerSmoothing
          : o.cornerSmoothing(a.cornerSmoothing),
    );
    final env = environment;
    paintStageAppearance(
      context: context,
      offset: offset,
      painter: env.painter,
      layers: _layers,
      outline: outline,
      appearance: a,
      media: env.media,
      onImageReady: _onImageReady,
      devicePixelRatio: stageDevicePixelRatio(),
      opacity: paintOpacity,
      overrides: o,
      composited: !inBlendGroup,
    );
  }

  @override
  void dispose() {
    _layers.dispose();
    super.dispose();
  }
}
