import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'layout/auto_layout.dart';
import 'stage_environment.dart';

/// Parent data of every child of a [RenderStageFrame]: `offset` is the
/// top-left of the child's unrotated box in the frame's coordinates.
class StageParentData extends ContainerBoxParentData<RenderStageBox> {}

/// What a property change invalidates.
enum StageInvalidation { none, paint, layout }

/// The larger of two invalidations.
StageInvalidation maxInvalidation(StageInvalidation a, StageInvalidation b) =>
    a.index >= b.index ? a : b;

/// The phase a fault was injected into ([debugStageFaultInjector]).
enum StageFaultPhase { layout, paint }

/// Test hook: when it returns true for a node id and phase, that node
/// throws in that phase, so tests can prove faults stay contained (§17.2).
@visibleForTesting
bool Function(String nodeId, StageFaultPhase phase)? debugStageFaultInjector;

/// Box constraints that ask for a definite [width]/[height] where given and
/// the child's natural size elsewhere.
BoxConstraints stageMeasureConstraints(double? width, double? height) =>
    BoxConstraints(
      minWidth: width ?? 0,
      maxWidth: width ?? double.infinity,
      minHeight: height ?? 0,
      maxHeight: height ?? double.infinity,
    );

/// The outside portion of [stroke] on each side (§4.4 step 2): none for
/// `inside`, half for `center`, all for `outside`. Zero without a visible
/// paint.
EdgeInsets strokeOutsetsOf(ir.Stroke stroke) {
  final visible = stroke.paints.any(
    (p) => switch (p) {
      ir.SolidPaint(:final visible) ||
      ir.GradientPaint(:final visible) ||
      ir.ImagePaint(:final visible) => visible,
    },
  );
  if (!visible) return EdgeInsets.zero;
  final f = switch (stroke.align) {
    ir.StrokeAlign.inside => 0.0,
    ir.StrokeAlign.center => 0.5,
    ir.StrokeAlign.outside => 1.0,
  };
  if (f == 0) return EdgeInsets.zero;
  return switch (stroke.weight) {
    ir.UniformStrokeWeight(:final weight) => EdgeInsets.all(weight * f),
    ir.PerSideStrokeWeight(
      :final top,
      :final right,
      :final bottom,
      :final left,
    ) =>
      EdgeInsets.fromLTRB(left * f, top * f, right * f, bottom * f),
  };
}

/// The base of every Soundstage render object (architecture §14).
///
/// **Layout protocol.** On each axis a tight constraint is the node's size;
/// otherwise the node takes its natural size: its content size if it hugs
/// that axis ([hugsWidth]/[hugsHeight]), else its stored size. Parents
/// measure children with dry layout and then lay them out tight. Min/max and
/// placement are the parent's job.
///
/// **Transforms.** Geometric `rotation` and `flipX/flipY` turn the box about
/// its centre; the paint-only `motion` transform (origin normalised in the
/// box) applies on top, in the parent's space. Both apply at paint and hit
/// test only: layout sees the unrotated box, and the parent places it so its
/// rotated bounding box sits where layout put it. The node applies its own
/// transform and opacity, so a paint-only change repaints just this node
/// (a repaint boundary when animated).
///
/// **Faults (§17.2).** An exception while laying out or painting the node is
/// caught here, reported once through [FlutterError.reportError], and the
/// node is sized from its stored geometry. It paints an error box in
/// [StageRenderMode.edit] and nothing in play. Placeholders (nodes that
/// failed to resolve) behave the same way.
abstract class RenderStageBox extends RenderBox {
  RenderStageBox({
    required this._node,
    required this._environment,
    this._repaintBoundary = false,
    this._placeholder = false,
  });

  ir.Node _node;
  ir.Node get node => _node;
  set node(ir.Node value) {
    if (identical(value, _node)) return;
    final old = _node;
    _node = value;
    if (_compositingOpacity(old.common.opacity) !=
        _compositingOpacity(value.common.opacity)) {
      markNeedsCompositingBitsUpdate();
    }
    applyInvalidation(invalidationFor(old, value));
  }

  StageEnvironment _environment;
  StageEnvironment get environment => _environment;
  set environment(StageEnvironment value) {
    if (identical(value, _environment)) return;
    final old = _environment;
    _environment = value;
    applyInvalidation(environmentInvalidation(old, value));
  }

  bool _repaintBoundary;
  set repaintBoundary(bool value) {
    if (value == _repaintBoundary) return;
    _repaintBoundary = value;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => _repaintBoundary;

  bool _placeholder;
  bool get placeholder => _placeholder;
  set placeholder(bool value) {
    if (value == _placeholder) return;
    _placeholder = value;
    markStageLayoutDirty();
  }

  ir.NodeCommon get common => _node.common;
  String get nodeId => _node.common.id;
  ir.LayoutChild get layoutChild => _node.common.layoutChild;

  /// The stored (design-time) size, never negative.
  Size get storedSize =>
      Size(math.max(0, common.width), math.max(0, common.height));

  /// Whether the node's natural width is its content width.
  bool get hugsWidth => false;

  /// Whether the node's natural height is its content height.
  bool get hugsHeight => false;

  /// The outside portion of the node's strokes (for
  /// `strokesIncludedInLayout`).
  EdgeInsets get strokeOutsets => EdgeInsets.zero;

  /// How the node sizes along [axis] inside an auto-layout parent: `fill`
  /// when its layoutChild says so, else `hug` when it hugs that axis, else
  /// `fixed`.
  StageAxisSizing sizingIn(Axis axis) {
    final s = axis == Axis.horizontal
        ? layoutChild.horizontalSizing
        : layoutChild.verticalSizing;
    if (s == ir.Sizing.fill) return StageAxisSizing.fill;
    final hugs = axis == Axis.horizontal ? hugsWidth : hugsHeight;
    return hugs ? StageAxisSizing.hug : StageAxisSizing.fixed;
  }

  /// Whether the last layout failed.
  bool get hasLayoutFault => _layoutFault;

  /// Whether the last paint failed.
  bool get hasPaintFault => _paintFault;

  bool _layoutFault = false;
  bool _paintFault = false;
  bool _dryFaultReported = false;
  bool _layoutFaultReported = false;
  bool _paintFaultReported = false;

  // ---- Invalidation -------------------------------------------------------------

  /// What changing the node from [old] to [next] invalidates. Subclasses
  /// add their kind's fields. Compares with `identical()` and primitive
  /// equality only (architecture §17.1).
  @protected
  StageInvalidation invalidationFor(ir.Node old, ir.Node next) {
    final o = old.common;
    final n = next.common;
    if (identical(o, n)) return StageInvalidation.none;
    if (o.x != n.x ||
        o.y != n.y ||
        o.width != n.width ||
        o.height != n.height ||
        o.rotation != n.rotation ||
        o.visible != n.visible ||
        !identical(o.layoutChild, n.layoutChild)) {
      return StageInvalidation.layout;
    }
    return StageInvalidation.paint;
  }

  /// What changing the environment invalidates.
  @protected
  StageInvalidation environmentInvalidation(
    StageEnvironment old,
    StageEnvironment next,
  ) => StageInvalidation.paint;

  @protected
  void applyInvalidation(StageInvalidation i) {
    switch (i) {
      case StageInvalidation.layout:
        markStageLayoutDirty();
      case StageInvalidation.paint:
        markNeedsPaint();
      case StageInvalidation.none:
        break;
    }
  }

  /// Marks this node and its parent for layout. A child laid out with tight
  /// constraints is its own relayout boundary, but its parent's layout reads
  /// the child's geometry and sizing, so the parent must relayout too.
  void markStageLayoutDirty() {
    markNeedsLayout();
    parent?.markNeedsLayout();
  }

  // ---- Layout -------------------------------------------------------------------

  /// Lays the node out for [constraints] and returns its size.
  @protected
  Size performStageLayout();

  /// The size [performStageLayout] would produce for [constraints], without
  /// laying anything out.
  @protected
  Size computeStageDryLayout(BoxConstraints constraints);

  /// The first alphabetic baseline for [constraints] (null = no text).
  @protected
  double? computeStageDryBaseline(BoxConstraints constraints) => null;

  @override
  void performLayout() {
    try {
      _maybeInjectFault(StageFaultPhase.layout);
      size = _placeholder
          ? constraints.constrain(storedSize)
          : performStageLayout();
      _layoutFault = false;
      _layoutFaultReported = false;
      _dryFaultReported = false;
    } catch (e, stack) {
      _layoutFault = true;
      if (!_layoutFaultReported) {
        _layoutFaultReported = true;
        _report(e, stack, 'laying out');
      }
      size = constraints.constrain(storedSize);
    }
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    if (_placeholder) return constraints.constrain(storedSize);
    try {
      _maybeInjectFault(StageFaultPhase.layout);
      return computeStageDryLayout(constraints);
    } catch (e, stack) {
      if (!_dryFaultReported) {
        _dryFaultReported = true;
        _report(e, stack, 'measuring');
      }
      return constraints.constrain(storedSize);
    }
  }

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    if (_placeholder) return null;
    try {
      _maybeInjectFault(StageFaultPhase.layout);
      return computeStageDryBaseline(constraints);
    } catch (_) {
      return null; // reported by computeDryLayout / performLayout
    }
  }

  // ---- Transform ----------------------------------------------------------------

  /// The node's paint transform in its own box coordinates (geometric
  /// rotation and flips about the centre, then `motion` about its origin),
  /// or null when it is the identity. Valid after layout.
  Matrix4? get paintTransform {
    final c = common;
    final m = c.motion;
    final geo = c.rotation % 360 != 0 || c.flipX || c.flipY;
    final mot =
        m.translateX != 0 ||
        m.translateY != 0 ||
        m.scaleX != 1 ||
        m.scaleY != 1 ||
        m.rotate % 360 != 0 ||
        m.skewX != 0 ||
        m.skewY != 0;
    if (!geo && !mot) return null;
    final w = size.width;
    final h = size.height;
    final result = Matrix4.identity();
    if (mot) {
      final ox = m.originX * w;
      final oy = m.originY * h;
      final skew = Matrix4.identity()
        ..setEntry(0, 1, math.tan(_rad(m.skewX)))
        ..setEntry(1, 0, math.tan(_rad(m.skewY)));
      result
        ..multiply(
          Matrix4.translationValues(ox + m.translateX, oy + m.translateY, 0),
        )
        ..multiply(Matrix4.rotationZ(_rad(m.rotate)))
        ..multiply(skew)
        ..multiply(Matrix4.diagonal3Values(m.scaleX, m.scaleY, 1))
        ..multiply(Matrix4.translationValues(-ox, -oy, 0));
    }
    if (geo) {
      result
        ..multiply(Matrix4.translationValues(w / 2, h / 2, 0))
        ..multiply(Matrix4.rotationZ(_rad(c.rotation)))
        ..multiply(
          Matrix4.diagonal3Values(c.flipX ? -1 : 1, c.flipY ? -1 : 1, 1),
        )
        ..multiply(Matrix4.translationValues(-w / 2, -h / 2, 0));
    }
    return result;
  }

  static double _rad(double degrees) => degrees * math.pi / 180;

  // ---- Paint --------------------------------------------------------------------

  double get _opacity => common.opacity.clamp(0.0, 1.0);

  static bool _compositingOpacity(double o) => o > 0 && o < 1;

  @override
  bool get alwaysNeedsCompositing => _compositingOpacity(common.opacity);

  final LayerHandle<TransformLayer> _transformLayer =
      LayerHandle<TransformLayer>();
  final LayerHandle<OpacityLayer> _opacityLayer = LayerHandle<OpacityLayer>();

  /// Paints the node's own content and its children at [offset], in its
  /// untransformed box. Exceptions are contained by the caller.
  @protected
  void paintStage(PaintingContext context, Offset offset);

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!common.visible) return;
    if (_layoutFault || _placeholder) {
      _paintFaultBox(context, offset);
      return;
    }
    if (_opacity <= 0) return;
    final t = paintTransform;
    if (t == null) {
      _transformLayer.layer = null;
      _paintWithOpacity(context, offset);
    } else {
      _transformLayer.layer = context.pushTransform(
        needsCompositing,
        offset,
        t,
        _paintWithOpacity,
        oldLayer: _transformLayer.layer,
      );
    }
  }

  void _paintWithOpacity(PaintingContext context, Offset offset) {
    final o = _opacity;
    if (o < 1) {
      _opacityLayer.layer = context.pushOpacity(
        offset,
        (o * 255).round(),
        _paintGuarded,
        oldLayer: _opacityLayer.layer,
      );
    } else {
      _opacityLayer.layer = null;
      _paintGuarded(context, offset);
    }
  }

  void _paintGuarded(PaintingContext context, Offset offset) {
    final canvas = context.canvas;
    final saveCount = canvas.getSaveCount();
    try {
      _maybeInjectFault(StageFaultPhase.paint);
      paintStage(context, offset);
      _paintFault = false;
      _paintFaultReported = false;
    } catch (e, stack) {
      if (identical(context.canvas, canvas)) canvas.restoreToCount(saveCount);
      _paintFault = true;
      if (!_paintFaultReported) {
        _paintFaultReported = true;
        _report(e, stack, 'painting');
      }
      _paintFaultBox(context, offset);
    }
  }

  void _paintFaultBox(PaintingContext context, Offset offset) {
    if (_environment.mode != StageRenderMode.edit) return;
    _environment.painter.paintErrorBox(context.canvas, offset & size);
  }

  @override
  void dispose() {
    _transformLayer.layer = null;
    _opacityLayer.layer = null;
    super.dispose();
  }

  // ---- Hit testing --------------------------------------------------------------

  /// Whether children outside the node's box are unreachable (frames that
  /// clip). Unclipped frames let their overflowing children be hit.
  @protected
  bool get clipsHitTesting => true;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!common.visible) return false;
    if ((_layoutFault || _placeholder) &&
        _environment.mode != StageRenderMode.edit) {
      return false;
    }
    final t = paintTransform;
    if (t == null) return _hitTestLocal(result, position);
    return result.addWithPaintTransform(
      transform: t,
      position: position,
      hitTest: (r, p) => _hitTestLocal(r, p),
    );
  }

  bool _hitTestLocal(BoxHitTestResult result, Offset position) {
    final inside = size.contains(position);
    if ((inside || !clipsHitTesting) &&
        !_layoutFault &&
        !_placeholder &&
        hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    if (inside && hitTestSelf(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  bool hitTestSelf(Offset position) => true;

  // ---- Faults -------------------------------------------------------------------

  void _maybeInjectFault(StageFaultPhase phase) {
    final inject = debugStageFaultInjector;
    if (inject != null && inject(nodeId, phase)) {
      throw StateError('Injected ${phase.name} fault in node "$nodeId"');
    }
  }

  void _report(Object e, StackTrace stack, String doing) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: e,
        stack: stack,
        library: 'soundstage runtime',
        context: ErrorDescription('while $doing stage node "$nodeId"'),
      ),
    );
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(StringProperty('node', nodeId))
      ..add(
        FlagProperty('placeholder', value: _placeholder, ifTrue: 'placeholder'),
      )
      ..add(
        FlagProperty(
          'layoutFault',
          value: _layoutFault,
          ifTrue: 'layout fault',
        ),
      );
  }
}
