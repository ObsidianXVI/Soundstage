import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../paint/appearance_compositor.dart';
import '../paint/appearance_painter.dart';
import '../paint/blend.dart';
import 'layout/auto_layout.dart';
import 'layout/constraints.dart';
import 'render_stage_box.dart';

/// The device pixel ratio used to pick image variants.
double stageDevicePixelRatio() =>
    ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 1.0;

/// The result of laying out a frame's children.
class StageFrameLayout {
  const StageFrameLayout({
    required this.size,
    required this.boxes,
    required this.paintOrder,
    required this.items,
    required this.baselineBoxes,
  });

  final Size size;

  /// Every child's unrotated box in the frame (hidden children at their
  /// stored geometry).
  final List<Rect> boxes;
  final List<int> paintOrder;
  final List<AutoLayoutChild> items;

  /// [boxes] with children that do not count for the first baseline nulled.
  final List<Rect?> baselineBoxes;
}

/// A frame (architecture §4.1): free (children placed by constraints, §4.3),
/// auto layout (§4.4), or grid (laid out as free until M3).
///
/// Its children's constraints are resolved against its reference size: its
/// own stored size, or [referenceSize] when set (a scene root uses the active
/// breakpoint's `designSize`).
///
/// Paint: fills, then children (clipped to the frame's rounded box when
/// `clipContent`), then the stroke on top.
class RenderStageFrame extends RenderStageBox
    with
        ContainerRenderObjectMixin<RenderStageBox, StageParentData>,
        RenderBoxContainerDefaultsMixin<RenderStageBox, StageParentData> {
  RenderStageFrame({
    required ir.FrameNode node,
    required super.environment,
    this._referenceSize,
    super.repaintBoundary,
    super.placeholder,
  }) : super(node: node);

  ir.FrameNode get frame => node as ir.FrameNode;

  Size? _referenceSize;

  /// The size the children's stored geometry was designed against.
  Size get referenceSize => _referenceSize ?? storedSize;
  set referenceSize(Size? value) {
    if (value == _referenceSize) return;
    _referenceSize = value;
    markNeedsLayout();
  }

  /// The auto layout in effect; grid frames lay out as free until M3.
  ir.AutoLayout? get _autoLayout =>
      frame.grid == null ? frame.autoLayout : null;

  // `hug` means "hug the auto-layout content", so without auto layout it is
  // treated as fixed. Sizing is per axis and comes only from `layoutChild`.
  @override
  bool get hugsWidth =>
      _autoLayout != null && layoutChild.horizontalSizing == ir.Sizing.hug;

  @override
  bool get hugsHeight =>
      _autoLayout != null && layoutChild.verticalSizing == ir.Sizing.hug;

  @override
  bool get supportsAppearanceOverrides => true;

  @override
  EdgeInsets get strokeOutsets {
    final s = frame.appearance.strokes;
    final o = appearanceOverrides;
    return strokeOutsetsOf(o == null ? s : o.stroke(s));
  }

  @override
  bool get includesChildStrokesInLayout =>
      _autoLayout?.strokesIncludedInLayout ?? false;

  @override
  void adoptChild(RenderObject child) {
    super.adoptChild(child);
    if (child is RenderStageBox &&
        blendNeedsIsolation(child.node.effectiveBlendMode)) {
      childBlendChanged();
    }
  }

  @override
  void dropChild(RenderObject child) {
    super.dropChild(child);
    if (child is RenderStageBox &&
        blendNeedsIsolation(child.node.effectiveBlendMode)) {
      childBlendChanged();
    }
  }

  @override
  bool get clipsHitTesting => frame.clipContent;

  @override
  StageInvalidation invalidationFor(ir.Node old, ir.Node next) {
    var i = super.invalidationFor(old, next);
    if (old is! ir.FrameNode || next is! ir.FrameNode) {
      return StageInvalidation.layout;
    }
    if (!identical(old.autoLayout, next.autoLayout) ||
        !identical(old.grid, next.grid)) {
      return StageInvalidation.layout;
    }
    if (!identical(old.appearance, next.appearance)) {
      i = maxInvalidation(
        i,
        identical(old.appearance.strokes, next.appearance.strokes)
            ? StageInvalidation.paint
            : StageInvalidation.layout,
      );
    }
    if (old.clipContent != next.clipContent) {
      i = maxInvalidation(i, StageInvalidation.paint);
    }
    return i;
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! StageParentData) {
      child.parentData = StageParentData();
    }
  }

  // ---- Layout -------------------------------------------------------------------

  List<RenderStageBox> _paintOrdered = const [];

  /// The layout of the children for [constraints], measuring them with dry
  /// layout. Shared by dry and real layout.
  StageFrameLayout computeFrameLayout(BoxConstraints constraints) {
    final children = getChildrenAsList();
    final al = _autoLayout;
    final lc = layoutChild;
    final stored = storedSize;
    final double? w = constraints.hasTightWidth
        ? constraints.maxWidth
        : (hugsWidth ? null : constraints.constrainWidth(stored.width));
    final double? h = constraints.hasTightHeight
        ? constraints.maxHeight
        : (hugsHeight ? null : constraints.constrainHeight(stored.height));

    final items = [
      for (final child in children)
        _item(
          child,
          inFlow:
              al != null &&
              child.common.visible &&
              child.layoutChild.positioning == ir.Positioning.auto,
        ),
    ];

    Size size;
    List<Rect?> boxes;
    List<int> paintOrder;
    if (al != null) {
      final res = computeAutoLayout(
        layout: al,
        children: items,
        width: w,
        height: h,
        minWidth: lc.minWidth,
        maxWidth: lc.maxWidth,
        minHeight: lc.minHeight,
        maxHeight: lc.maxHeight,
      );
      size = constraints.constrain(res.size);
      boxes = res.boxes;
      paintOrder = res.paintOrder;
    } else {
      size = Size(w ?? stored.width, h ?? stored.height);
      boxes = List<Rect?>.filled(children.length, null);
      paintOrder = stagePaintOrder(children.length, reverseZIndex: false);
    }

    // §4.4 step 9 / §4.3: absolute children (and every child of a free
    // frame) are placed by constraints against the reference size.
    final ref = referenceSize;
    final all = <Rect>[];
    final forBaseline = <Rect?>[];
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      final c = child.common;
      final placed =
          boxes[i] ??
          (c.visible
              ? _placeByConstraints(child, size, ref)
              : Rect.fromLTWH(
                  c.x,
                  c.y,
                  child.storedSize.width,
                  child.storedSize.height,
                ));
      all.add(placed);
      final counts = al != null ? items[i].inFlow : c.visible;
      forBaseline.add(counts ? placed : null);
    }
    return StageFrameLayout(
      size: size,
      boxes: all,
      paintOrder: paintOrder,
      items: items,
      baselineBoxes: forBaseline,
    );
  }

  AutoLayoutChild _item(RenderStageBox child, {required bool inFlow}) {
    final c = child.common;
    final lc = child.layoutChild;
    return AutoLayoutChild(
      width: child.storedSize.width,
      height: child.storedSize.height,
      inFlow: inFlow,
      horizontalSizing: child.sizingIn(Axis.horizontal),
      verticalSizing: child.sizingIn(Axis.vertical),
      minWidth: lc.minWidth,
      maxWidth: lc.maxWidth,
      minHeight: lc.minHeight,
      maxHeight: lc.maxHeight,
      rotation: c.rotation,
      strokeOutsets: child.strokeOutsets,
      measure: (w, h) => child.getDryLayout(stageMeasureConstraints(w, h)),
      baseline: (s) => child.getDryBaseline(
        BoxConstraints.tight(s),
        TextBaseline.alphabetic,
      ),
    );
  }

  /// Places [child] by its constraints (§4.3) in a parent of [parentSize]
  /// designed at [reference]. Axes the child hugs are measured unless the
  /// constraint sets the size (stretch/scale).
  Rect _placeByConstraints(
    RenderStageBox child,
    Size parentSize,
    Size reference,
  ) {
    final c = child.common;
    final lc = child.layoutChild;
    final hK = horizontalAxisConstraint(lc.constraints.horizontal);
    final vK = verticalAxisConstraint(lc.constraints.vertical);
    final stored = child.storedSize;

    AxisPlacement vertical({double? content}) => resolveAxisConstraint(
      constraint: vK,
      position: c.y,
      size: stored.height,
      reference: reference.height,
      parent: parentSize.height,
      min: lc.minHeight,
      max: lc.maxHeight,
      contentSize: content,
    );

    final double? givenHeight = constraintSetsSize(vK) ? vertical().size : null;
    double? contentWidth;
    if (child.hugsWidth && !constraintSetsSize(hK)) {
      contentWidth = child
          .getDryLayout(stageMeasureConstraints(null, givenHeight))
          .width;
    }
    final hp = resolveAxisConstraint(
      constraint: hK,
      position: c.x,
      size: stored.width,
      reference: reference.width,
      parent: parentSize.width,
      min: lc.minWidth,
      max: lc.maxWidth,
      contentSize: contentWidth,
    );
    double? contentHeight;
    if (child.hugsHeight && !constraintSetsSize(vK)) {
      contentHeight = child
          .getDryLayout(stageMeasureConstraints(hp.size, null))
          .height;
    }
    final vp = vertical(content: contentHeight);
    return Rect.fromLTWH(hp.offset, vp.offset, hp.size, vp.size);
  }

  @override
  Size computeStageDryLayout(BoxConstraints constraints) =>
      computeFrameLayout(constraints).size;

  @override
  double? computeStageDryBaseline(BoxConstraints constraints) {
    final l = computeFrameLayout(constraints);
    return firstBaselineOf(l.items, l.baselineBoxes);
  }

  @override
  Size performStageLayout() {
    final l = computeFrameLayout(constraints);
    final children = getChildrenAsList();
    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      final box = l.boxes[i];
      child.layout(BoxConstraints.tight(box.size));
      (child.parentData! as StageParentData).offset = box.topLeft;
    }
    _paintOrdered = [for (final i in l.paintOrder) children[i]];
    return l.size;
  }

  // ---- Paint --------------------------------------------------------------------

  final StageAppearanceLayers _layers = StageAppearanceLayers();

  void _onImageReady() {
    if (attached) markNeedsPaint();
  }

  ir.Appearance get _appearance => frame.appearance;

  @override
  bool get opacityNeedsLayer =>
      childCount > 0 ||
      paintedPartCount(
            _appearance.fills,
            _appearance.strokes,
            _appearance.effects,
            appearanceOverrides,
          ) >
          1;

  @override
  bool get hasEffectLayers => inBlendGroup
      ? hasBackgroundBlur(_appearance.effects, appearanceOverrides)
      : hasLayerEffects(_appearance.effects, appearanceOverrides);

  @override
  bool get isolatesBlend {
    if (super.isolatesBlend) return true;
    // An explicit `normal` frame is an isolated group: it matters when a
    // child blends (a `passThrough` frame lets children blend with the
    // backdrop instead).
    if (node.effectiveBlendMode != ir.BlendMode.normal) return false;
    var child = firstChild;
    while (child != null) {
      if (blendNeedsIsolation(child.node.effectiveBlendMode)) return true;
      child = (child.parentData! as StageParentData).nextSibling;
    }
    return false;
  }

  @override
  void paintStage(PaintingContext context, Offset offset) {
    final env = environment;
    final appearance = _appearance;
    final o = appearanceOverrides;
    final outline = StageOutline.box(
      size,
      o == null
          ? appearance.cornerRadius
          : o.cornerRadius(appearance.cornerRadius),
      smoothing: o == null
          ? appearance.cornerSmoothing
          : o.cornerSmoothing(appearance.cornerSmoothing),
    );
    paintStageAppearance(
      context: context,
      offset: offset,
      painter: env.painter,
      layers: _layers,
      outline: outline,
      appearance: appearance,
      media: env.media,
      onImageReady: _onImageReady,
      devicePixelRatio: stageDevicePixelRatio(),
      opacity: paintOpacity,
      overrides: o,
      composited: !inBlendGroup,
      paintChildren: (ctx, off) {
        if (frame.clipContent) {
          _layers.pushOutlineClip(
            needsCompositing,
            ctx,
            off,
            outline,
            _paintChildren,
          );
        } else {
          _layers.releaseClip();
          _paintChildren(ctx, off);
        }
      },
    );
  }

  void _paintChildren(PaintingContext context, Offset offset) {
    for (final child in _paintOrdered) {
      final pd = child.parentData! as StageParentData;
      context.paintChild(child, offset + pd.offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (var i = _paintOrdered.length - 1; i >= 0; i--) {
      final child = _paintOrdered[i];
      final pd = child.parentData! as StageParentData;
      final hit = result.addWithPaintOffset(
        offset: pd.offset,
        position: position,
        hitTest: (r, p) => child.hitTest(r, position: p),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void applyPaintTransform(RenderStageBox child, Matrix4 transform) {
    final pd = child.parentData! as StageParentData;
    transform.multiply(
      Matrix4.translationValues(pd.offset.dx, pd.offset.dy, 0),
    );
    final t = child.paintTransform;
    if (t != null) transform.multiply(t);
  }

  @override
  void dispose() {
    _layers.dispose();
    super.dispose();
  }
}
