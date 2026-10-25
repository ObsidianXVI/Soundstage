import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_frame.dart';

// Interactive frame behaviours in play mode (architecture §9; m3.md T3.3).
// The frame's children stay ordinary nodes laid out by the frame; a
// behaviour only moves them as a whole (`RenderStageFrame.contentOffset`) or
// shows one of them full-screen. In edit mode frames render as authored.
//
// - Carousel: drag (or arrow keys) between slides. A slide is a visible
//   child; it rests with its start `peek` px from the frame's start. `paged`
//   moves one slide per swipe, `free` coasts and then snaps (when `snap`).
//   `autoplay` > 0 advances every that many seconds while not touched;
//   `loop` wraps from the last slide to the first (and back).
// - Marquee: the content runs past at `speed` px/s in `direction`, entering
//   from one edge once it has fully left the other.
// - Lightbox: tapping a child opens it alone over the page, fitted to the
//   screen; tap, Escape or the close button closes, arrows step through.
// Reduced motion: carousels jump instead of gliding and do not autoplay;
// marquees stand still.

bool _reduced(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

/// Wraps the frame widget [child] (whose render object is reached through
/// [frameKey]) with its play-mode [behavior]; other behaviours pass through.
Widget wrapStageBehavior({
  required ir.Behavior? behavior,
  required GlobalKey frameKey,
  required Widget child,
  required Widget Function(int index) buildMember,
  required int memberCount,
}) => switch (behavior) {
  final ir.CarouselBehavior b => StageCarousel(
    behavior: b,
    frameKey: frameKey,
    child: child,
  ),
  final ir.MarqueeBehavior b => StageMarquee(
    behavior: b,
    frameKey: frameKey,
    child: child,
  ),
  ir.LightboxBehavior() => StageLightbox(
    frameKey: frameKey,
    buildMember: buildMember,
    memberCount: memberCount,
    child: child,
  ),
  _ => child,
};

RenderStageFrame? _frameOf(GlobalKey key) {
  final r = key.currentContext?.findRenderObject();
  return r is RenderStageFrame && r.hasSize ? r : null;
}

// ---- Carousel ------------------------------------------------------------------

/// The slide geometry of a carousel along its axis.
@visibleForTesting
class CarouselGeometry {
  CarouselGeometry({
    required List<(double, double)> slides,
    required this.extent,
    required double peek,
  }) {
    final start = slides.isEmpty
        ? 0.0
        : slides.map((s) => s.$1).reduce(math.min);
    final end = slides.isEmpty ? 0.0 : slides.map((s) => s.$2).reduce(math.max);
    // The content's trailing inset mirrors its leading one (padding).
    maxOffset = math.max(0, end + start - extent);
    final stops = <double>[];
    for (final s in slides) {
      final o = (s.$1 - peek).clamp(0.0, maxOffset);
      if (stops.isEmpty || (o - stops.last).abs() > 0.5) stops.add(o);
    }
    this.stops = stops.isEmpty ? const [0] : stops;
  }

  final double extent;
  late final double maxOffset;

  /// The resting offsets, one per slide (slides that would rest past the
  /// end share the last one).
  late final List<double> stops;

  /// The index of the stop nearest [offset].
  int nearest(double offset) {
    var best = 0;
    for (var i = 1; i < stops.length; i++) {
      if ((stops[i] - offset).abs() < (stops[best] - offset).abs()) best = i;
    }
    return best;
  }
}

class StageCarousel extends StatefulWidget {
  const StageCarousel({
    required this.behavior,
    required this.frameKey,
    required this.child,
    super.key,
  });

  final ir.CarouselBehavior behavior;
  final GlobalKey frameKey;
  final Widget child;

  @override
  State<StageCarousel> createState() => StageCarouselState();
}

@visibleForTesting
class StageCarouselState extends State<StageCarousel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController.unbounded(
    vsync: this,
  )..addListener(_apply);
  late final DragGestureRecognizer _drag =
      (_horizontal
            ? HorizontalDragGestureRecognizer(debugOwner: this)
            : VerticalDragGestureRecognizer(debugOwner: this))
        ..onStart = _dragStart
        ..onUpdate = _dragUpdate
        ..onEnd = _dragEnd;
  final FocusNode _focus = FocusNode(debugLabel: 'Carousel');
  Timer? _autoplay;
  Timer? _wheelSettle;
  bool _dragging = false;
  int _index = 0;

  bool get _horizontal => widget.behavior.axis == ir.LayoutDirection.horizontal;

  /// The current slide (for tests and semantics).
  int get index => _index;

  double get _offset => _anim.value;

  @override
  void initState() {
    super.initState();
    _restartAutoplay();
  }

  @override
  void didUpdateWidget(StageCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.behavior != widget.behavior) _restartAutoplay();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restartAutoplay();
  }

  @override
  void dispose() {
    _autoplay?.cancel();
    _wheelSettle?.cancel();
    _drag.dispose();
    _focus.dispose();
    _anim.dispose();
    super.dispose();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      _focus.requestFocus();
      _drag.addPointer(e);
    } else if (e is PointerScrollEvent) {
      final along = _horizontal ? e.scrollDelta.dx : e.scrollDelta.dy;
      final across = _horizontal ? e.scrollDelta.dy : e.scrollDelta.dx;
      // A sideways trackpad or wheel scroll pans; page scrolling passes.
      if (along.abs() <= across.abs()) return;
      GestureBinding.instance.pointerSignalResolver.register(e, (_) {
        final g = _geometry();
        if (g == null) return;
        _anim.stop();
        _anim.value = (_offset + along).clamp(0.0, g.maxOffset);
        _wheelSettle?.cancel();
        _wheelSettle = Timer(const Duration(milliseconds: 140), () {
          if (mounted && widget.behavior.snap) _goTo(g, g.nearest(_offset));
        });
      });
    }
  }

  void _attach() {
    final f = _frameOf(widget.frameKey);
    if (f != null && f.onBehaviorPointer != _onPointer) {
      f.onBehaviorPointer = _onPointer;
    }
  }

  CarouselGeometry? _geometry() {
    final f = _frameOf(widget.frameKey);
    if (f == null) return null;
    return CarouselGeometry(
      slides: [
        for (final b in f.childBoxes)
          _horizontal ? (b.left, b.right) : (b.top, b.bottom),
      ],
      extent: _horizontal ? f.size.width : f.size.height,
      peek: widget.behavior.peek,
    );
  }

  void _apply() {
    final f = _frameOf(widget.frameKey);
    if (f == null) return;
    f.contentOffset = _horizontal ? Offset(-_offset, 0) : Offset(0, -_offset);
  }

  void _restartAutoplay() {
    _autoplay?.cancel();
    _autoplay = null;
    final s = widget.behavior.autoplay;
    if (s <= 0 || !mounted || _reduced(context)) return;
    _autoplay = Timer.periodic(Duration(milliseconds: (s * 1000).round()), (_) {
      if (!_dragging) step(1, wrap: true);
    });
  }

  /// Moves [delta] slides; past either end wraps when looping (or when
  /// [wrap], for autoplay) and stops otherwise.
  void step(int delta, {bool wrap = false}) {
    final g = _geometry();
    if (g == null) return;
    var i = g.nearest(_offset) + delta;
    final n = g.stops.length;
    if (i < 0 || i >= n) {
      if (!(widget.behavior.loop || wrap)) return;
      i = (i % n + n) % n;
    }
    _goTo(g, i);
  }

  void _goTo(CarouselGeometry g, int i) {
    _index = i;
    final target = g.stops[i];
    if (_reduced(context)) {
      _anim.value = target;
    } else {
      _anim.animateTo(
        target,
        duration: const Duration(milliseconds: 380),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _dragStart(DragStartDetails _) {
    _dragging = true;
    _anim.stop();
  }

  void _dragUpdate(DragUpdateDetails d) {
    final g = _geometry();
    if (g == null) return;
    final delta = _horizontal ? d.delta.dx : d.delta.dy;
    var next = _offset - delta;
    // Resist past the ends.
    if (next < 0 || next > g.maxOffset) {
      next = _offset - delta / 3;
    }
    _anim.value = next;
  }

  void _dragEnd(DragEndDetails d) {
    _dragging = false;
    final g = _geometry();
    if (g == null) return;
    final v = _horizontal
        ? d.velocity.pixelsPerSecond.dx
        : d.velocity.pixelsPerSecond.dy;
    final b = widget.behavior;
    int target;
    if (b.physics == ir.CarouselPhysics.paged) {
      final here = g.nearest(_offset);
      final from = g.stops[here];
      if (v.abs() > 300) {
        // A flick goes one slide in its direction from where it started.
        target = v < 0
            ? (_offset >= from ? here + 1 : here)
            : (_offset <= from ? here - 1 : here);
      } else {
        target = here;
      }
    } else {
      // Coast (friction), then snap to the nearest slide when snapping.
      final coast = (_offset - v * 0.35).clamp(0.0, g.maxOffset);
      if (!b.snap) {
        _reduced(context)
            ? _anim.value = coast
            : _anim.animateTo(
                coast,
                duration: const Duration(milliseconds: 500),
                curve: Curves.decelerate,
              );
        _restartAutoplay();
        return;
      }
      target = g.nearest(coast);
    }
    final n = g.stops.length;
    if (target < 0 || target >= n) {
      target = b.loop ? (target % n + n) % n : target.clamp(0, n - 1);
    }
    _goTo(g, target);
    _restartAutoplay();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final next = _horizontal
        ? LogicalKeyboardKey.arrowRight
        : LogicalKeyboardKey.arrowDown;
    final prev = _horizontal
        ? LogicalKeyboardKey.arrowLeft
        : LogicalKeyboardKey.arrowUp;
    if (k == next) {
      step(1);
    } else if (k == prev) {
      step(-1);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    // The frame's render object may be new after a rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attach();
    });
    // No render objects of its own (see RenderStageFrame.onBehaviorPointer).
    return Focus(
      focusNode: _focus,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: widget.child,
    );
  }
}

// ---- Marquee -------------------------------------------------------------------

/// The content offset of a marquee [elapsed] seconds in: the content
/// ([start]–[end] along the axis) enters from the far edge of a frame of
/// [extent] and leaves fully before it enters again.
@visibleForTesting
double marqueeOffset({
  required double elapsed,
  required double speed,
  required double extent,
  required double start,
  required double end,
  required bool forward,
}) {
  final period = (end - start) + extent;
  if (period <= 0 || speed <= 0) return 0;
  final run = (elapsed * speed) % period;
  // forward (left/up): from just past the far edge towards the start.
  return forward ? extent - start - run : run - end;
}

class StageMarquee extends StatefulWidget {
  const StageMarquee({
    required this.behavior,
    required this.frameKey,
    required this.child,
    super.key,
  });

  final ir.MarqueeBehavior behavior;
  final GlobalKey frameKey;
  final Widget child;

  @override
  State<StageMarquee> createState() => _StageMarqueeState();
}

class _StageMarqueeState extends State<StageMarquee>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduced(context)) {
      _ticker.stop();
      _frameOf(widget.frameKey)?.contentOffset = Offset.zero;
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final f = _frameOf(widget.frameKey);
    if (f == null) return;
    final d = widget.behavior.direction;
    final horizontal =
        d == ir.MarqueeDirection.left || d == ir.MarqueeDirection.right;
    final boxes = f.childBoxes;
    if (boxes.isEmpty) return;
    final start = boxes
        .map((b) => horizontal ? b.left : b.top)
        .reduce(math.min);
    final end = boxes
        .map((b) => horizontal ? b.right : b.bottom)
        .reduce(math.max);
    final o = marqueeOffset(
      elapsed: elapsed.inMicroseconds / 1e6,
      speed: widget.behavior.speed,
      extent: horizontal ? f.size.width : f.size.height,
      start: start,
      end: end,
      forward: d == ir.MarqueeDirection.left || d == ir.MarqueeDirection.up,
    );
    f.contentOffset = horizontal ? Offset(o, 0) : Offset(0, o);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// ---- Lightbox ------------------------------------------------------------------

class StageLightbox extends StatefulWidget {
  const StageLightbox({
    required this.frameKey,
    required this.buildMember,
    required this.memberCount,
    required this.child,
    super.key,
  });

  final GlobalKey frameKey;
  final Widget Function(int index) buildMember;
  final int memberCount;
  final Widget child;

  @override
  State<StageLightbox> createState() => _StageLightboxState();
}

class _StageLightboxState extends State<StageLightbox> {
  late final TapGestureRecognizer _tap = TapGestureRecognizer(debugOwner: this)
    ..onTapUp = (d) => _open(d.globalPosition);

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) _tap.addPointer(e);
  }

  void _open(Offset global) {
    final f = _frameOf(widget.frameKey);
    if (f == null || !mounted) return;
    final local = f.globalToLocal(global) - f.contentOffset;
    final boxes = f.childBoxes;
    for (var i = boxes.length - 1; i >= 0; i--) {
      if (boxes[i].contains(local)) {
        showStageLightbox(
          context,
          index: i,
          count: widget.memberCount,
          buildMember: widget.buildMember,
          sizes: [for (final b in boxes) b.size],
        );
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final f = _frameOf(widget.frameKey);
      if (mounted && f != null) f.onBehaviorPointer = _onPointer;
    });
    return widget.child;
  }
}

/// Shows member [index] of a lightbox over the page (see [StageLightbox]).
Future<void> showStageLightbox(
  BuildContext context, {
  required int index,
  required int count,
  required List<Size> sizes,
  required Widget Function(int index) buildMember,
}) => Navigator.of(context, rootNavigator: true).push(
  PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierLabel: 'Close',
    transitionDuration: _reduced(context)
        ? Duration.zero
        : const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => _LightboxView(
      index: index,
      count: count,
      sizes: sizes,
      buildMember: buildMember,
    ),
    transitionsBuilder: (_, a, _, c) => FadeTransition(opacity: a, child: c),
  ),
);

class _LightboxView extends StatefulWidget {
  const _LightboxView({
    required this.index,
    required this.count,
    required this.sizes,
    required this.buildMember,
  });

  final int index;
  final int count;
  final List<Size> sizes;
  final Widget Function(int index) buildMember;

  @override
  State<_LightboxView> createState() => _LightboxViewState();
}

class _LightboxViewState extends State<_LightboxView> {
  late int _i = widget.index;

  void _step(int d) {
    if (widget.count < 2) return;
    setState(() => _i = (_i + d + widget.count) % widget.count);
  }

  @override
  Widget build(BuildContext context) {
    final size = _i < widget.sizes.length ? widget.sizes[_i] : Size.zero;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, e) {
        if (e is! KeyDownEvent) return KeyEventResult.ignored;
        if (e.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
        } else if (e.logicalKey == LogicalKeyboardKey.arrowRight) {
          _step(1);
        } else if (e.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _step(-1);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Semantics(
        scopesRoute: true,
        explicitChildNodes: true,
        label: 'Full screen view',
        child: GestureDetector(
          key: const ValueKey<String>('lightbox'),
          onTap: () => Navigator.of(context).pop(),
          child: ColoredBox(
            color: const Color(0xEB000000),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: size.isEmpty
                      ? const SizedBox.shrink()
                      : FittedBox(
                          child: SizedBox.fromSize(
                            size: size,
                            child: widget.buildMember(_i),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
