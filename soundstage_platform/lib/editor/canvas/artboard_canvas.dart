import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'canvas_controller.dart';

/// Lays the artboards out side by side in world coordinates and shows them
/// through the camera of [controller] (m1.md "Canvas").
///
/// [breakpointIds] names the artboard of each child, in order. Children are
/// laid out unconstrained and size themselves (the artboard's width; a
/// pinned scene's viewport height or a flow scene's content height).
class ArtboardCanvas extends MultiChildRenderObjectWidget {
  const ArtboardCanvas({
    required this.controller,
    required this.breakpointIds,
    super.children,
    super.key,
  });

  final CanvasController controller;
  final List<String> breakpointIds;

  @override
  RenderArtboardCanvas createRenderObject(BuildContext context) =>
      RenderArtboardCanvas(
        controller: controller,
        breakpointIds: breakpointIds,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderArtboardCanvas renderObject,
  ) {
    renderObject
      ..controller = controller
      ..breakpointIds = breakpointIds;
  }
}

class ArtboardParentData extends ContainerBoxParentData<RenderBox> {}

/// The render object of [ArtboardCanvas].
///
/// - **Camera as a transform layer.** It is a repaint boundary that paints
///   no content of its own: a camera change repaints only this boundary,
///   which pushes one `TransformLayer` and re-appends the artboards'
///   retained layers (each artboard is a repaint boundary). Pan and zoom
///   never rebuild, relayout or re-record an artboard, and pictures stay
///   crisp at any zoom (the engine rasterises them at the final transform).
/// - **Culling.** Only artboards whose world rect intersects the visible
///   world rect are painted.
/// - [applyPaintTransform] and hit testing include the camera, so
///   `getTransformTo` from any stage node gives its screen transform.
class RenderArtboardCanvas extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, ArtboardParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, ArtboardParentData> {
  RenderArtboardCanvas({
    required this._controller,
    required this._breakpointIds,
  });

  CanvasController _controller;
  CanvasController get controller => _controller;
  set controller(CanvasController value) {
    if (identical(value, _controller)) return;
    if (attached) _unlisten();
    _controller = value;
    if (attached) _listen();
    markNeedsLayout();
  }

  List<String> _breakpointIds;
  set breakpointIds(List<String> value) {
    if (listEquals(value, _breakpointIds)) return;
    _breakpointIds = value;
    markNeedsLayout();
  }

  /// Test counter: paints of this render object (camera changes repaint it).
  @visibleForTesting
  int debugPaintCount = 0;

  /// Indices of the children painted by the last paint (tests).
  @visibleForTesting
  Set<int> get debugPaintedChildren => _painted;
  Set<int> _painted = const {};

  final LayerHandle<TransformLayer> _transform = LayerHandle<TransformLayer>();

  void _listen() {
    _controller.camera.addListener(markNeedsPaint);
    _controller.worldBox = this;
  }

  void _unlisten() {
    _controller.camera.removeListener(markNeedsPaint);
    if (identical(_controller.worldBox, this)) _controller.worldBox = null;
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _listen();
  }

  @override
  void detach() {
    _unlisten();
    super.detach();
  }

  @override
  void dispose() {
    _transform.layer = null;
    super.dispose();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! ArtboardParentData) {
      child.parentData = ArtboardParentData();
    }
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.biggest;

  @override
  void performLayout() {
    _controller.viewportSize = size;
    final children = getChildrenAsList();
    for (final c in children) {
      c.layout(const BoxConstraints(), parentUsesSize: true);
    }
    final xs = artboardOffsets([for (final c in children) c.size.width]);
    for (var i = 0; i < children.length; i++) {
      final c = children[i];
      final pd = c.parentData! as ArtboardParentData;
      pd.offset = Offset(xs[i], 0);
      if (i < _breakpointIds.length) {
        _controller.artboards[_breakpointIds[i]]?.worldRect =
            pd.offset & c.size;
      }
    }
    _controller.notifyGeometry();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    assert(() {
      debugPaintCount++;
      return true;
    }());
    _transform.layer = context.pushTransform(
      true,
      offset,
      _controller.camera.value.matrix,
      _paintArtboards,
      oldLayer: _transform.layer,
    );
  }

  void _paintArtboards(PaintingContext context, Offset offset) {
    final visible = _controller.visibleWorldRect;
    final painted = <int>{};
    var i = 0;
    var child = firstChild;
    while (child != null) {
      final pd = child.parentData! as ArtboardParentData;
      if ((pd.offset & child.size).overlaps(visible)) {
        context.paintChild(child, offset + pd.offset);
        painted.add(i);
      }
      i++;
      child = pd.nextSibling;
    }
    _painted = painted;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final pd = child.parentData! as ArtboardParentData;
    transform
      ..multiply(_controller.camera.value.matrix)
      ..translateByDouble(pd.offset.dx, pd.offset.dy, 0, 1);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      result.addWithPaintTransform(
        transform: _controller.camera.value.matrix,
        position: position,
        hitTest: (r, p) => defaultHitTestChildren(r, position: p),
      );
}
