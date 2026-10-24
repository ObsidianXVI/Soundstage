import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../paint/appearance_painter.dart';
import 'render_stage_box.dart';
import 'render_stage_frame.dart' show RenderStageFrame, stageDevicePixelRatio;
import 'stage_environment.dart';

/// Hosts one scene's stage root at a viewport size (architecture §3.2) and
/// paints the scene background behind it.
///
/// - `pinned`: the root is sized to the viewport.
/// - `flow`: the root is laid out at the viewport width with its own
///   vertical sizing (hug or stored height), and then **grows to its
///   content**: when a child's (rotated) box reaches below that height, the
///   root is laid out again exactly as tall as the lowest child bottom, so
///   nothing below the stored height is clipped or unreachable (DECISIONS
///   wave D). Its reference size stays the stored height, so top-anchored
///   children keep their place; bottom/centre/scale-anchored children follow
///   the grown bottom. One extra pass at most.
///
/// Scrolling, pinning and the scene clock are T0.6 (`SliverStageScene`).
class RenderStageScene extends RenderBox
    with RenderObjectWithChildMixin<RenderStageBox> {
  RenderStageScene({
    required this._kind,
    required this._viewportSize,
    required this._background,
    required this._environment,
  });

  ir.SceneKind _kind;
  set kind(ir.SceneKind value) {
    if (value == _kind) return;
    _kind = value;
    markNeedsLayout();
  }

  Size _viewportSize;
  set viewportSize(Size value) {
    if (value == _viewportSize) return;
    _viewportSize = value;
    markNeedsLayout();
  }

  List<ir.Paint> _background;
  set background(List<ir.Paint> value) {
    if (identical(value, _background)) return;
    _background = value;
    markNeedsPaint();
  }

  StageEnvironment _environment;
  set environment(StageEnvironment value) {
    if (identical(value, _environment)) return;
    _environment = value;
    markNeedsPaint();
  }

  BoxConstraints get _childConstraints => _kind == ir.SceneKind.pinned
      ? BoxConstraints.tight(_viewportSize)
      : BoxConstraints.tightFor(width: _viewportSize.width);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final c = child;
    if (_kind == ir.SceneKind.pinned || c == null) {
      return constraints.constrain(_viewportSize);
    }
    return constraints.constrain(c.getDryLayout(_childConstraints));
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.constrain(
        _kind == ir.SceneKind.pinned
            ? _viewportSize
            : Size(_viewportSize.width, 0),
      );
      return;
    }
    c.layout(_childConstraints, parentUsesSize: true);
    if (_kind == ir.SceneKind.flow) {
      final bottom = c is RenderStageFrame ? c.contentBottom : 0.0;
      if (bottom > c.size.height + 0.5) {
        c.layout(
          BoxConstraints.tightFor(width: _viewportSize.width, height: bottom),
          parentUsesSize: true,
        );
      }
    }
    size = constraints.constrain(
      _kind == ir.SceneKind.pinned ? _viewportSize : c.size,
    );
  }

  void _onImageReady() {
    if (attached) markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (_background.isNotEmpty) {
      final canvas = context.canvas
        ..save()
        ..translate(offset.dx, offset.dy);
      _environment.painter.paintFills(
        canvas,
        StageOutline.box(size, const ir.CornerRadius.uniform()),
        _background,
        media: _environment.media,
        onImageReady: _onImageReady,
        devicePixelRatio: stageDevicePixelRatio(),
      );
      canvas.restore();
    }
    final c = child;
    if (c != null) context.paintChild(c, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      child?.hitTest(result, position: position) ?? false;
}
