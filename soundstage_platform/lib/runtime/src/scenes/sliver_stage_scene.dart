import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

// ---- Scene scroll math (architecture §3.2) ------------------------------------

/// A pinned scene's scroll extent: `viewportHeight × (1 + scrollLength)`.
double pinnedSceneExtent(double viewportExtent, double scrollLength) =>
    viewportExtent * (1 + math.max(0.0, scrollLength));

/// Where a pinned scene's stage sits relative to the scene's leading edge
/// in the viewport: 0 (held at the top) until [scrollOffset] passes the pin
/// range `viewportHeight × scrollLength`, then it scrolls away.
double pinnedStageOffset(
  double scrollOffset,
  double viewportExtent,
  double scrollLength,
) {
  final pin = viewportExtent * math.max(0.0, scrollLength);
  return scrollOffset <= pin ? 0 : pin - scrollOffset;
}

/// A pinned scene's scroll clock: 0 when its top reaches the viewport top,
/// 1 at the end of the pin range. [scrollOffset] is the sliver's
/// `SliverConstraints.scrollOffset` (how far its top has scrolled past the
/// viewport top; 0 before). A zero-length pin is 0 before and 1 after.
double pinnedSceneProgress(
  double scrollOffset,
  double viewportExtent,
  double scrollLength,
) {
  final pin = viewportExtent * math.max(0.0, scrollLength);
  if (pin <= 0) return scrollOffset > 0 ? 1 : 0;
  return (scrollOffset / pin).clamp(0.0, 1.0);
}

/// A flow scene's scroll clock: 0 when its top enters the bottom of the
/// viewport, 1 when its bottom leaves the top. The distance travelled is
/// `viewportHeight + scrollOffset` once the top has passed the viewport top,
/// else the visible part of the viewport below the top
/// ([remainingPaintExtent]).
double flowSceneProgress({
  required double scrollOffset,
  required double remainingPaintExtent,
  required double viewportExtent,
  required double extent,
}) {
  final total = viewportExtent + extent;
  if (total <= 0) return 0;
  final travelled = scrollOffset > 0
      ? viewportExtent + scrollOffset
      : math.max(0.0, remainingPaintExtent);
  return (travelled / total).clamp(0.0, 1.0);
}

/// Called from a scene sliver's layout with the scene's scroll progress and
/// whether any of it is on screen. Runs inside a layout callback, so it may
/// mutate render objects of the scene's own subtree.
typedef StageSceneLayoutCallback =
    void Function(double progress, {required bool visible});

/// Builds a scene's stage when [inWindow] (within the lazy window), else a
/// cheap placeholder.
typedef StageSceneBuilder =
    Widget Function(BuildContext context, bool inWindow);

/// One scene in a `StagePlayer`'s `CustomScrollView` (architecture §3.2,
/// §14, §17.1).
///
/// - **Pinned:** the scroll extent is `viewportHeight × (1 + scrollLength)`.
///   The stage (viewport-sized) is held at the top of the viewport while
///   the scene scrolls through its pin range, and scrolls normally before
///   and after.
/// - **Flow:** the extent is the stage's laid-out height at the viewport
///   width.
/// - **Progress** is computed in layout from `SliverConstraints` and
///   reported through [onLayout]; no scroll listeners, no `setState`.
/// - **Lazy:** the stage subtree is built only while the scene is within
///   [windowViewports] viewports of the visible range (the player sets the
///   scroll view's cache extent to the same distance). Outside it the scene
///   keeps its extent (a flow scene its last laid-out height, or
///   [estimatedExtent] before its first build) with an empty child. The
///   subtree is built and dropped from layout, the way slivers build list
///   items, so crossing the window boundary is the only time scrolling
///   builds widgets.
///
/// Vertical, top-to-bottom scrolling only.
class SliverStageScene extends AbstractLayoutBuilder<bool> {
  const SliverStageScene({
    super.key,
    required this.kind,
    required this.scrollLength,
    required this.builder,
    required this.content,
    this.estimatedExtent = 0,
    this.windowViewports = 1,
    this.onLayout,
  });

  final ir.SceneKind kind;

  /// Pinned scenes: the pin range in viewport heights.
  final double scrollLength;

  @override
  final StageSceneBuilder builder;

  /// What the built child depends on (the resolved scene, viewport, …).
  /// The child is rebuilt only when this changes (by identity) or the scene
  /// enters or leaves the lazy window.
  final Object? content;

  /// A flow scene's extent before it has ever been laid out.
  final double estimatedExtent;

  /// The lazy window around the visible range, in viewport heights.
  final double windowViewports;
  final StageSceneLayoutCallback? onLayout;

  @override
  bool updateShouldRebuild(SliverStageScene oldWidget) =>
      !identical(content, oldWidget.content) || kind != oldWidget.kind;

  @override
  RenderSliverStageScene createRenderObject(BuildContext context) =>
      RenderSliverStageScene(
        kind: kind,
        scrollLength: scrollLength,
        estimatedExtent: estimatedExtent,
        windowViewports: windowViewports,
        onLayout: onLayout,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverStageScene renderObject,
  ) {
    renderObject
      ..kind = kind
      ..scrollLength = scrollLength
      ..estimatedExtent = estimatedExtent
      ..windowViewports = windowViewports
      ..onLayout = onLayout;
  }
}

/// The render object of [SliverStageScene].
class RenderSliverStageScene extends RenderSliverSingleBoxAdapter
    with
        RenderObjectWithLayoutCallbackMixin,
        RenderAbstractLayoutBuilderMixin<bool, RenderBox> {
  RenderSliverStageScene({
    required this._kind,
    required this._scrollLength,
    this._estimatedExtent = 0,
    this._windowViewports = 1,
    this._onLayout,
  });

  ir.SceneKind _kind;
  set kind(ir.SceneKind value) {
    if (value == _kind) return;
    _kind = value;
    markNeedsLayout();
  }

  double _scrollLength;
  set scrollLength(double value) {
    if (value == _scrollLength) return;
    _scrollLength = value;
    markNeedsLayout();
  }

  double _estimatedExtent;
  set estimatedExtent(double value) {
    if (value == _estimatedExtent) return;
    _estimatedExtent = value;
    if (_measuredExtent == null) markNeedsLayout();
  }

  double _windowViewports;
  set windowViewports(double value) {
    if (value == _windowViewports) return;
    _windowViewports = value;
    markNeedsLayout();
  }

  StageSceneLayoutCallback? _onLayout;
  set onLayout(StageSceneLayoutCallback? value) {
    if (identical(value, _onLayout)) return;
    _onLayout = value;
    _published = false;
    markNeedsLayout();
  }

  bool _inWindow = false;
  double? _measuredExtent;
  double _childPosition = 0;

  bool _published = false;
  double _lastProgress = double.nan;
  bool _lastVisible = false;

  /// Whether the stage subtree is built (within the lazy window).
  bool get inWindow => _inWindow;

  /// The scene's scroll progress from the last layout.
  double get progress => _lastProgress;

  /// Whether any of the scene was on screen at the last layout.
  bool get visible => _lastVisible;

  @override
  bool get layoutInfo => _inWindow;

  double _extentFor(double viewportExtent) => _kind == ir.SceneKind.pinned
      ? pinnedSceneExtent(viewportExtent, _scrollLength)
      : (_measuredExtent ?? _estimatedExtent);

  @override
  double childMainAxisPosition(RenderBox child) => _childPosition;

  @override
  void performLayout() {
    final c = constraints;
    assert(
      c.axisDirection == AxisDirection.down,
      'SliverStageScene supports top-to-bottom scrolling only.',
    );
    final vh = c.viewportMainAxisExtent;
    final s = c.scrollOffset;

    // The lazy window: within `windowViewports` viewports above the
    // viewport top (by our own extent), or inside the viewport's cache
    // region below it (the player sets the cache extent to match).
    final window = vh * _windowViewports;
    _inWindow = s > 0
        ? s < _extentFor(vh) + window
        : c.remainingPaintExtent > 0 || c.remainingCacheExtent > 0;
    runLayoutCallback();

    final child = this.child;
    double extent;
    if (_kind == ir.SceneKind.pinned) {
      extent = pinnedSceneExtent(vh, _scrollLength);
      child?.layout(BoxConstraints.tight(Size(c.crossAxisExtent, vh)));
      _childPosition = pinnedStageOffset(s, vh, _scrollLength);
    } else {
      child?.layout(
        BoxConstraints.tightFor(width: c.crossAxisExtent),
        parentUsesSize: true,
      );
      if (_inWindow && child != null) _measuredExtent = child.size.height;
      extent = _measuredExtent ?? _estimatedExtent;
      _childPosition = -s;
    }

    final paintExtent = calculatePaintOffset(c, from: 0, to: extent);
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: paintExtent,
      cacheExtent: calculateCacheOffset(c, from: 0, to: extent),
      maxPaintExtent: extent,
      hitTestExtent: paintExtent,
      hasVisualOverflow: s > 0 || extent > c.remainingPaintExtent,
    );
    if (child != null) {
      (child.parentData! as SliverPhysicalParentData).paintOffset = Offset(
        0,
        _childPosition,
      );
    }

    final progress = _kind == ir.SceneKind.pinned
        ? pinnedSceneProgress(s, vh, _scrollLength)
        : flowSceneProgress(
            scrollOffset: s,
            remainingPaintExtent: c.remainingPaintExtent,
            viewportExtent: vh,
            extent: extent,
          );
    final visible = paintExtent > 0;
    if (!_published || progress != _lastProgress || visible != _lastVisible) {
      _published = true;
      _lastProgress = progress;
      _lastVisible = visible;
      final cb = _onLayout;
      if (cb != null) {
        invokeLayoutCallback<SliverConstraints>(
          (_) => cb(progress, visible: visible),
        );
      }
    }
  }
}
