import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../animator/compiled_track.dart';
import '../paint/appearance_overrides.dart';
import '../paint/blend.dart';
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

  /// The node as rendered: the resolved node with any animated node-level
  /// overrides applied ([nodeAnimator]).
  ir.Node get node => _node;

  /// Sets the resolved node. With a [nodeAnimator], the rendered node is
  /// the animator's output for it.
  set node(ir.Node value) {
    if (identical(value, _baseNode)) return;
    _baseNode = value;
    final animate = _nodeAnimator;
    _setRenderedNode(animate == null ? value : animate(value));
  }

  void _setRenderedNode(ir.Node value) {
    if (identical(value, _node)) return;
    final old = _node;
    final couldNeedCompositing = alwaysNeedsCompositing;
    final wasBoundary = isRepaintBoundary;
    final wasIsolating = isolatesBlend;
    _node = value;
    if (old.effectiveBlendMode != value.effectiveBlendMode) {
      final p = parent;
      if (p is RenderStageBox) p.childBlendChanged();
    }
    if (wasIsolating != isolatesBlend) _updateChildBlendGroups();
    if (couldNeedCompositing != alwaysNeedsCompositing ||
        wasBoundary != isRepaintBoundary) {
      markNeedsCompositingBitsUpdate();
    }
    applyInvalidation(invalidationFor(old, value));
  }

  // ---- Animated overrides (T0.6, architecture §14) -------------------------------
  //
  // Three layers sit over the resolved node while tracks play:
  //
  // - Typed slots for the compositing-class properties (`opacity` and
  //   `motion.*`), written by the animator with [setAnimatedSlot] without
  //   allocating, and read directly at compositing, paint and hit test.
  // - Typed paint overrides (T0.6b) for the numeric and colour properties
  //   of a frame's or shape's appearance (fills, stroke paints and weight,
  //   effects, corners): channels written in place by the animator and
  //   read by the paint seam at paint time ([appearanceOverrides]).
  // - A node animator for every other property: a function from the
  //   resolved node to the rendered node (the animator applies its tracks'
  //   current values through the property registry), re-run by
  //   [refreshAnimatedNode] and whenever the resolved node changes.

  late ir.Node _baseNode = _node;

  /// The resolved node, before animated overrides.
  ir.Node get baseNode => _baseNode;

  ir.Node Function(ir.Node resolved)? _nodeAnimator;

  /// Sets (or clears, with null) the node-level animated override and
  /// re-renders the node through it.
  set nodeAnimator(ir.Node Function(ir.Node resolved)? value) {
    if (identical(value, _nodeAnimator)) return;
    _nodeAnimator = value;
    refreshAnimatedNode();
  }

  /// Re-applies the node animator to the resolved node (after the
  /// animator's values changed). Invalidates by what changed (paint or
  /// layout), like a resolved-node update.
  void refreshAnimatedNode() {
    final animate = _nodeAnimator;
    _setRenderedNode(animate == null ? _baseNode : animate(_baseNode));
  }

  /// Slot indices of the typed overrides.
  static const int slotOpacity = 0;
  static const int slotTranslateX = 1;
  static const int slotTranslateY = 2;
  static const int slotScaleX = 3;
  static const int slotScaleY = 4;
  static const int slotRotate = 5;
  static const int slotSkewX = 6;
  static const int slotSkewY = 7;
  static const int slotOriginX = 8;
  static const int slotOriginY = 9;
  static const int slotCount = 10;

  /// The typed slot for [path] (`opacity`, `motion.*`), or −1.
  static int slotForPath(String path) => switch (path) {
    'opacity' => slotOpacity,
    'motion.translateX' => slotTranslateX,
    'motion.translateY' => slotTranslateY,
    'motion.scaleX' => slotScaleX,
    'motion.scaleY' => slotScaleY,
    'motion.rotate' => slotRotate,
    'motion.skewX' => slotSkewX,
    'motion.skewY' => slotSkewY,
    'motion.originX' => slotOriginX,
    'motion.originY' => slotOriginY,
    _ => -1,
  };

  /// NaN = not overridden. Allocated on first use.
  Float64List? _slots;

  // ---- Typed paint overrides (T0.6b) ---------------------------------------------

  /// Whether this render object reads typed paint overrides (frames and
  /// shapes). Others animate their appearance through the registry.
  bool get supportsAppearanceOverrides => false;

  StageAppearanceOverrides? _appearanceOverrides;

  /// The typed paint overrides, or null when there are none.
  StageAppearanceOverrides? get appearanceOverrides {
    final o = _appearanceOverrides;
    return o == null || o.isEmpty ? null : o;
  }

  /// Adds a typed paint override for [path] (when a track binds). Which
  /// overrides exist can change the node's compositing (a blur with an
  /// animated radius needs its layer), so this updates compositing bits.
  StageAppearanceChannel addAppearanceOverride(StageAppearancePath path) {
    assert(supportsAppearanceOverrides);
    final channel = (_appearanceOverrides ??= StageAppearanceOverrides()).add(
      path,
    );
    _appearanceOverridesChanged(layout: path.affectsLayout);
    return channel;
  }

  /// Removes the typed paint override [channel].
  void removeAppearanceOverride(StageAppearanceChannel channel) {
    final o = _appearanceOverrides;
    if (o == null) return;
    o.remove(channel);
    _appearanceOverridesChanged(layout: channel.path.affectsLayout);
  }

  // The `StageTypedTrackHost` side of typed paint overrides: frames and
  // shapes implement the host interface (shared with text styles, T0.7)
  // with these.

  /// Binds [track] as a typed paint override when its property has one and
  /// every keyframe is typed; returns the handle, or null (the registry
  /// path then applies it).
  @protected
  Object? bindAppearanceTrack(CompiledTrack track) {
    if (!supportsAppearanceOverrides || !track.isTyped) return null;
    final path = StageAppearancePath.parse(track.track.property);
    if (path == null || path.stride != track.stride) return null;
    final binding = _AppearanceTrack(addAppearanceOverride(path), track);
    binding.pull();
    return binding;
  }

  /// The bound track's output changed: copies it into its channel and
  /// invalidates. Allocation-free.
  @protected
  void appearanceTrackChanged(Object handle) {
    final binding = handle as _AppearanceTrack;
    binding.pull();
    appearanceOverrideChanged(binding.channel);
  }

  @protected
  void unbindAppearanceTrack(Object handle) =>
      removeAppearanceOverride((handle as _AppearanceTrack).channel);

  /// Removes every typed paint override.
  void clearAppearanceOverrides() {
    final o = _appearanceOverrides;
    if (o == null || o.isEmpty) return;
    final layout = o.overridesStrokeWeight;
    o.clear();
    _appearanceOverridesChanged(layout: layout);
  }

  void _appearanceOverridesChanged({required bool layout}) {
    markNeedsCompositingBitsUpdate();
    if (layout) {
      markStageLayoutDirty();
    } else {
      markNeedsPaint();
    }
  }

  /// The animator wrote [channel]: repaints this node, and relayouts it
  /// (with its parent) when a stroke weight change moves the parent's auto
  /// layout (`strokesIncludedInLayout`). Allocation-free.
  void appearanceOverrideChanged(StageAppearanceChannel channel) {
    if (channel.path.affectsLayout) {
      final p = parent;
      if (p is RenderStageBox && p.includesChildStrokesInLayout) {
        markStageLayoutDirty();
        return;
      }
    }
    markNeedsPaint();
  }

  /// Whether this node's layout reads its children's stroke outsets
  /// (auto layout with `strokesIncludedInLayout`).
  @protected
  bool get includesChildStrokesInLayout => false;

  // ---- Blend groups (T0.6b) -----------------------------------------------------

  bool _inBlendGroup = false;

  /// False until the first attach decides [inBlendGroup]. Until then the
  /// node is not a repaint boundary: the framework assumes a node that was
  /// a boundary at construction has a layer, so it must not stop being one
  /// before its first paint.
  bool _blendGroupResolved = false;

  /// Whether an ancestor isolates a blended group (a non-normal blend mode,
  /// or a `normal` frame with a blending child: one canvas `saveLayer`).
  ///
  /// Such a group must stay one canvas layer: a descendant that started a
  /// compositing layer of its own would paint outside the `saveLayer`. So a
  /// node in a group is never a repaint boundary, applies its opacity and
  /// layer blur with canvas `saveLayer`s, and repaints with the group when
  /// its animated values change. Decided at attach, and again whenever an
  /// ancestor's blend (or a frame's blending children) changes.
  bool get inBlendGroup => _inBlendGroup;

  void _updateBlendGroup() {
    final p = parent;
    final inGroup = p is RenderStageBox && (p._inBlendGroup || p.isolatesBlend);
    if (inGroup == _inBlendGroup) return;
    _inBlendGroup = inGroup;
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
    _updateChildBlendGroups();
  }

  void _updateChildBlendGroups() {
    visitChildren((child) {
      if (child is RenderStageBox) child._updateBlendGroup();
    });
  }

  /// A child's blend mode changed, or a blending child was added or
  /// removed: this node's isolation (and its children's groups) may change.
  @protected
  void childBlendChanged() {
    markNeedsCompositingBitsUpdate();
    markNeedsPaint();
    _updateChildBlendGroups();
  }

  /// The animated value in [slot], or NaN when it is not overridden.
  double animatedSlot(int slot) => _slots?[slot] ?? double.nan;

  /// Overrides [slot] with [value] (NaN clears it). Never relayouts.
  /// Allocation-free after the first call.
  ///
  /// On a repaint boundary this only updates the node's composited layers
  /// (its `TransformLayer` and `OpacityLayer`, through
  /// [updateCompositedLayer]): the picture is not re-recorded. Otherwise it
  /// repaints the nearest repaint boundary.
  @pragma('vm:prefer-inline')
  void setAnimatedSlot(int slot, double value) {
    final slots = _slots ?? _createSlots();
    final old = slots[slot];
    if (old == value || (old.isNaN && value.isNaN)) return;
    if (isRepaintBoundary) {
      slots[slot] = value;
      markNeedsCompositedLayerUpdate();
      return;
    }
    final layerBefore =
        slot == slotOpacity && _compositingOpacity(effectiveOpacity);
    slots[slot] = value;
    _slotChanged(slot, layerBefore);
  }

  /// [setAnimatedSlot] with the value read from `values[index]` (the
  /// animator passes a compiled track's output). No double crosses the call,
  /// which keeps the push allocation-free in the VM's JIT even when the
  /// receiver is polymorphic (frames and shapes).
  void setAnimatedSlotFrom(int slot, Float64List values, int index) =>
      setAnimatedSlot(slot, values[index]);

  Float64List _createSlots() =>
      _slots = Float64List(slotCount)..fillRange(0, slotCount, double.nan);

  // Kept free of double parameters, so the push stays allocation-free in
  // the VM's JIT (doubles crossing a call that is not inlined are boxed).
  void _slotChanged(int slot, bool layerBefore) {
    // Only an opacity crossing into or out of (0, 1) can change whether
    // the node needs an opacity layer.
    if (slot == slotOpacity &&
        layerBefore != _compositingOpacity(effectiveOpacity)) {
      markNeedsCompositingBitsUpdate();
    }
    markNeedsPaint();
  }

  /// Clears every typed override.
  void clearAnimatedSlots() {
    final slots = _slots;
    if (slots == null) return;
    for (var i = 0; i < slotCount; i++) {
      setAnimatedSlot(i, double.nan);
    }
  }

  @pragma('vm:prefer-inline')
  double _slotOr(int slot, double base) {
    final slots = _slots;
    if (slots == null) return base;
    final v = slots[slot];
    return v.isNaN ? base : v;
  }

  @pragma('vm:prefer-inline')
  double _effectiveOpacityOf(ir.Node n) =>
      _slotOr(slotOpacity, n.common.opacity);

  /// The opacity as rendered (animated or resolved).
  @pragma('vm:prefer-inline')
  double get effectiveOpacity => _effectiveOpacityOf(_node);

  // ---- Registry (T0.6) ----------------------------------------------------------

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    final wasBoundary = isRepaintBoundary;
    _blendGroupResolved = true;
    _updateBlendGroup();
    if (wasBoundary != isRepaintBoundary) {
      markNeedsCompositingBitsUpdate();
      markNeedsPaint();
    }
    _environment.nodes?.attachNode(this);
  }

  @override
  void detach() {
    _environment.nodes?.detachNode(this);
    super.detach();
  }

  /// Test counters: how many times stage nodes ran layout and paint.
  @visibleForTesting
  static int debugLayoutCount = 0;

  /// See [debugLayoutCount].
  @visibleForTesting
  static int debugPaintCount = 0;

  /// Test counter: how many times this node recorded its content (paints
  /// skipped for invisible or faulted nodes do not count). Composited
  /// updates ([updateCompositedLayer]) do not count.
  @visibleForTesting
  int debugNodePaintCount = 0;

  StageEnvironment _environment;
  StageEnvironment get environment => _environment;
  set environment(StageEnvironment value) {
    if (identical(value, _environment)) return;
    final old = _environment;
    if (attached && !identical(old.nodes, value.nodes)) {
      old.nodes?.detachNode(this);
      value.nodes?.attachNode(this);
    }
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

  /// A node is a repaint boundary when asked to be ([repaintBoundary]),
  /// except inside a blended group ([inBlendGroup]) or when it blends
  /// itself: its blend must apply to the backdrop, inside one picture.
  @override
  bool get isRepaintBoundary =>
      _repaintBoundary &&
      _blendGroupResolved &&
      !_inBlendGroup &&
      !blendNeedsIsolation(_node.effectiveBlendMode);

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
    assert(() {
      debugLayoutCount++;
      return true;
    }());
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
    final tx = _slotOr(slotTranslateX, m.translateX);
    final ty = _slotOr(slotTranslateY, m.translateY);
    final sx = _slotOr(slotScaleX, m.scaleX);
    final sy = _slotOr(slotScaleY, m.scaleY);
    final rot = _slotOr(slotRotate, m.rotate);
    final kx = _slotOr(slotSkewX, m.skewX);
    final ky = _slotOr(slotSkewY, m.skewY);
    final geo = c.rotation % 360 != 0 || c.flipX || c.flipY;
    final mot =
        tx != 0 ||
        ty != 0 ||
        sx != 1 ||
        sy != 1 ||
        rot % 360 != 0 ||
        kx != 0 ||
        ky != 0;
    if (!geo && !mot) return null;
    final w = size.width;
    final h = size.height;
    final result = Matrix4.identity();
    if (mot) {
      final ox = _slotOr(slotOriginX, m.originX) * w;
      final oy = _slotOr(slotOriginY, m.originY) * h;
      final skew = Matrix4.identity()
        ..setEntry(0, 1, math.tan(_rad(kx)))
        ..setEntry(1, 0, math.tan(_rad(ky)));
      result
        ..multiply(Matrix4.translationValues(ox + tx, oy + ty, 0))
        ..multiply(Matrix4.rotationZ(_rad(rot)))
        ..multiply(skew)
        ..multiply(Matrix4.diagonal3Values(sx, sy, 1))
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

  double get _opacity => effectiveOpacity.clamp(0.0, 1.0);

  @pragma('vm:prefer-inline')
  static bool _compositingOpacity(double o) => o > 0 && o < 1;

  /// Whether a group opacity below 1 needs an opacity layer. A subclass
  /// with a single painted part returns false and multiplies [paintOpacity]
  /// into that part's colour instead (Figma's group opacity only differs
  /// from per-paint opacity where parts overlap).
  @protected
  bool get opacityNeedsLayer => true;

  /// The opacity a subclass must apply to its own paints: the node's
  /// opacity when it folds opacity into its paints ([opacityNeedsLayer] is
  /// false), else 1 because a layer applies it. A repaint boundary always
  /// applies it with its composited `OpacityLayer`, so opacity changes do
  /// not re-record its picture.
  @protected
  double get paintOpacity =>
      opacityNeedsLayer || isolatesBlend || isRepaintBoundary ? 1.0 : _opacity;

  /// Whether the node paints compositing layers of its own (layer or
  /// background blur), which makes it need compositing.
  @protected
  bool get hasEffectLayers => false;

  /// Whether the node is composited in an isolated group with a non-normal
  /// blend mode, using a `saveLayer` whose paint carries the blend mode and
  /// the opacity. A frame's default `passThrough` and `normal` never do.
  @protected
  bool get isolatesBlend => blendNeedsIsolation(node.effectiveBlendMode);

  /// Opacity layers count only outside blended groups (inside, opacity is
  /// a canvas `saveLayer`) and not on repaint boundaries (their composited
  /// layer applies it). Inside a group, [hasEffectLayers] reports only the
  /// effects that still need layers there (background blur).
  @override
  bool get alwaysNeedsCompositing {
    if (_inBlendGroup) return hasEffectLayers;
    return (!isRepaintBoundary &&
            _compositingOpacity(effectiveOpacity) &&
            opacityNeedsLayer &&
            !isolatesBlend) ||
        hasEffectLayers;
  }

  final LayerHandle<TransformLayer> _transformLayer =
      LayerHandle<TransformLayer>();
  final LayerHandle<OpacityLayer> _opacityLayer = LayerHandle<OpacityLayer>();

  static final Matrix4 _identity = Matrix4.identity();

  int get _alpha => (_opacity * 255).round();

  /// A repaint boundary's own layer is a `TransformLayer` carrying the
  /// node's paint transform (identity without one), with an `OpacityLayer`
  /// child (pushed by [paint]) carrying its opacity. Both are updated here,
  /// so `opacity` and `motion.*` changes reach the screen without
  /// re-recording the picture (architecture §17.1).
  @override
  OffsetLayer updateCompositedLayer({
    required covariant TransformLayer? oldLayer,
  }) {
    final layer = oldLayer ?? TransformLayer();
    layer.transform = paintTransform ?? _identity;
    _opacityLayer.layer?.alpha = _alpha;
    return layer;
  }

  /// Paints the node's own content and its children at [offset], in its
  /// untransformed box. Exceptions are contained by the caller.
  @protected
  void paintStage(PaintingContext context, Offset offset);

  @override
  void paint(PaintingContext context, Offset offset) {
    assert(() {
      debugPaintCount++;
      return true;
    }());
    if (!common.visible) return;
    if (_layoutFault || _placeholder) {
      _paintFaultBox(context, offset);
      return;
    }
    assert(() {
      debugNodePaintCount++;
      return true;
    }());
    if (isRepaintBoundary) {
      // The transform is this boundary's own layer (updateCompositedLayer);
      // the opacity layer is kept even when opaque or transparent, so later
      // changes only update its alpha.
      _transformLayer.layer = null;
      _opacityLayer.layer = context.pushOpacity(
        offset,
        _alpha,
        _paintComposited,
        oldLayer: _opacityLayer.layer,
      );
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

  void _paintComposited(PaintingContext context, Offset offset) {
    if (isolatesBlend) {
      _paintBlended(context, offset, 1);
    } else {
      _paintGuarded(context, offset);
    }
  }

  void _paintWithOpacity(PaintingContext context, Offset offset) {
    final o = _opacity;
    if (isolatesBlend) {
      _opacityLayer.layer = null;
      _paintBlended(context, offset, o);
    } else if (o < 1 && opacityNeedsLayer && _inBlendGroup) {
      // Inside a blended group: a canvas layer, never an OpacityLayer.
      _opacityLayer.layer = null;
      _paintBlended(context, offset, o, blendMode: BlendMode.srcOver);
    } else if (o < 1 && opacityNeedsLayer) {
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

  /// Paints into a `saveLayer` that blends with the backdrop using the
  /// node's blend mode and opacity. The group is one canvas layer, so
  /// descendants that start compositing layers of their own (repaint
  /// boundaries, opacity layers, blurs) paint outside it; keep blended
  /// groups free of those.
  void _paintBlended(
    PaintingContext context,
    Offset offset,
    double opacity, {
    BlendMode? blendMode,
  }) {
    final canvas = context.canvas;
    canvas.saveLayer(
      null,
      Paint()
        ..blendMode = blendMode ?? flutterBlendMode(node.effectiveBlendMode)
        ..color = Color.fromARGB((opacity * 255).round(), 255, 255, 255),
    );
    _paintGuarded(context, offset);
    if (identical(context.canvas, canvas)) canvas.restore();
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

/// A track bound to a typed paint override channel.
final class _AppearanceTrack {
  _AppearanceTrack(this.channel, this.track);

  final StageAppearanceChannel channel;
  final CompiledTrack track;

  void pull() => channel.write(track.out, uniform: track.outputUniform);
}
