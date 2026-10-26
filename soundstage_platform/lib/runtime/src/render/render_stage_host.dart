import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'render_stage_shape.dart';
import 'shape_geometry.dart';

/// A stage box that hosts one ordinary render box (a video surface, a
/// Lottie or Rive view; m3.md T3.6). It lays out and paints like a shape
/// (its appearance shows behind the content), sizes the child to itself and
/// clips it to its corners. Stage frames only take stage children, so media
/// widgets live inside one of these.
class RenderStageHost extends RenderStageShape
    with RenderObjectWithChildMixin<RenderBox> {
  RenderStageHost({
    required super.node,
    required super.environment,
    super.repaintBoundary,
  });

  /// Values clocks feed to the content (embed inputs, a video's scrub
  /// position), by input name; [onInput] hears each change.
  final Map<String, double> inputs = {};
  void Function(String input, double value)? onInput;

  void setInput(String input, double value) {
    if (inputs[input] == value) return;
    inputs[input] = value;
    onInput?.call(input, value);
  }

  @override
  Size performStageLayout() {
    final s = super.performStageLayout();
    child?.layout(BoxConstraints.tight(s));
    return s;
  }

  ir.CornerRadius get _radius => switch (node) {
    ir.VideoNode(:final appearance) => appearance.cornerRadius,
    _ => const ir.CornerRadius.uniform(),
  };

  @override
  void paintStage(PaintingContext context, Offset offset) {
    super.paintStage(context, offset);
    final c = child;
    if (c == null) return;
    final outline = shapeOutline(
      const ir.ShapeGeometry.rectangle(),
      size,
      cornerRadius: _radius,
    );
    context.pushClipPath(
      needsCompositing,
      offset,
      Offset.zero & size,
      outline.path,
      (ctx, off) => ctx.paintChild(c, off),
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final c = child;
    return c != null && c.hitTest(result, position: position);
  }
}
