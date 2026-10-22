import 'dart:math' as math;

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../clocks/smoothing.dart';

/// How one wheel event is treated by [WheelClassifier].
enum WheelKind {
  /// One notch of a mouse wheel: coarse, discrete. Smoothed.
  notch,

  /// Trackpad, touch-wheel, precision device: small, fractional or
  /// high-frequency deltas. Left to the browser's own smoothing.
  precise,
}

/// Opt-in smoothing of mouse-wheel scrolling (T0.8).
///
/// Mouse wheels deliver coarse notches (about 100 px); a flow scene then
/// jumps in steps, while pinned scenes hide it behind their clocks. With
/// smoothing on, a notch moves a *target* offset and the scroll position
/// follows it like a critically damped spring ([StageSmoother]); further
/// notches mid-flight move the target and keep the velocity. Trackpad and
/// other precise deltas are untouched.
@immutable
class StageWheelSmoothing {
  const StageWheelSmoothing({
    this.smoothing = 0.06,
    this.minNotch = 40,
    this.streamGap = const Duration(milliseconds: 20),
    this.preciseLatch = const Duration(milliseconds: 150),
  });

  /// The follower's time constant in seconds (see [StageSmoother]): 9% of a
  /// notch remains after 2× this (120 ms at the default), about 2% after
  /// 3× (180 ms).
  final double smoothing;

  /// Events smaller than this (in logical px) are never a wheel notch.
  final double minNotch;

  /// Events closer together than this belong to a dense stream (a
  /// trackpad, or a free-spinning wheel).
  final Duration streamGap;

  /// After a precise event, everything within this window stays precise
  /// (a trackpad flick's first delta can be large; its momentum is dense).
  final Duration preciseLatch;
}

/// Tells a mouse-wheel notch from a trackpad delta on the web.
///
/// Flutter web turns every DOM `wheel` event into a `PointerScrollEvent`
/// whose `scrollDelta` is in CSS pixels, with no device flag (`kind` is
/// `mouse` for both) and no `deltaMode` or `wheelDelta`. All that is left
/// is the delta and the timing, so the heuristic is:
///
/// 1. `|delta| < minNotch` → precise (trackpads produce 1–40 px events).
/// 2. A non-integer delta → precise (wheels report whole pixels; precision
///    touchpads and some DPR scalings report fractions).
/// 3. Within [StageWheelSmoothing.preciseLatch] of a precise event →
///    precise.
/// 4. In a dense stream (gap < [StageWheelSmoothing.streamGap]) → a notch
///    only if its size equals the previous notch (a fast-spinning wheel
///    repeats the same ±100/±120); otherwise precise.
/// 5. Otherwise → notch.
///
/// Failure modes (documented in `_dev/spike_report.md`): the first event of
/// a hard trackpad flick (≥ 40 px, integer, after a pause) is taken for a
/// notch and smoothed for ~150 ms (harmless); a wheel with a software
/// acceleration curve or tiny per-notch deltas (some Mac mice, Logitech
/// "smooth scrolling") looks like a trackpad and stays native; Windows
/// "scroll N lines" or a browser zoom changes notch sizes but not the
/// classification; free-spin wheels with varying magnitudes fall back to
/// native after the first notches.
class WheelClassifier {
  WheelClassifier([this.config = const StageWheelSmoothing()]);

  final StageWheelSmoothing config;

  Duration? _last;
  double _lastNotch = 0;
  Duration _preciseUntil = Duration.zero;

  /// Classifies the event with [delta] (one axis) arriving at [now].
  WheelKind classify(double delta, Duration now) {
    final gap = _last == null ? null : now - _last!;
    _last = now;
    final mag = delta.abs();
    WheelKind kind;
    if (mag < config.minNotch || mag != mag.roundToDouble()) {
      kind = WheelKind.precise;
    } else if (now < _preciseUntil) {
      kind = WheelKind.precise;
    } else if (gap != null && gap < config.streamGap) {
      kind = mag == _lastNotch ? WheelKind.notch : WheelKind.precise;
    } else {
      kind = WheelKind.notch;
    }
    if (kind == WheelKind.notch) {
      _lastNotch = mag;
    } else {
      _lastNotch = 0;
      _preciseUntil = now + config.preciseLatch;
    }
    return kind;
  }
}

/// A [ScrollController] whose positions can smooth mouse-wheel notches
/// (see [StageWheelSmoothing]). With [smoothing] null it behaves exactly
/// like a [ScrollController].
///
/// The hook is `ScrollPosition.pointerScroll`: `Scrollable` registers the
/// `PointerScrollEvent` with the pointer-signal resolver and calls it with
/// the axis delta (after modifier-key axis flipping), so overriding it in
/// the position catches exactly the wheel and trackpad scrolls the
/// scrollable accepted, and nothing from keyboard, touch or the scrollbar.
class StageScrollController extends ScrollController {
  StageScrollController({
    this._smoothing,
    this.clock,
    super.initialScrollOffset,
  });

  StageWheelSmoothing? _smoothing;

  /// A monotonic clock for event timing (tests); default a stopwatch.
  final Duration Function()? clock;

  StageWheelSmoothing? get smoothing => _smoothing;
  set smoothing(StageWheelSmoothing? v) {
    if (identical(v, _smoothing)) return;
    _smoothing = v;
    for (final p in positions) {
      if (p is StageScrollPosition) p.configure(v);
    }
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => StageScrollPosition(
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
    smoothing: _smoothing,
    clock: clock,
  );
}

/// The position behind [StageScrollController].
class StageScrollPosition extends ScrollPositionWithSingleContext {
  StageScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
    StageWheelSmoothing? smoothing,
    Duration Function()? clock,
  }) : _clock = clock ?? _stopwatchClock(),
       _smoother = StageSmoother(smoothing: smoothing?.smoothing ?? 0) {
    configure(smoothing);
  }

  static Duration Function() _stopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  final Duration Function() _clock;
  final StageSmoother _smoother;
  StageWheelSmoothing? _config;
  WheelClassifier? _classifier;
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  double _target = 0;
  bool _animating = false;
  bool _ownTransition = false;

  /// Whether a smoothed wheel scroll is in flight.
  bool get isWheelAnimating => _animating;

  /// The offset the in-flight wheel scroll is heading to.
  double get wheelTarget => _target;

  /// (Re)configures smoothing; null turns it off.
  void configure(StageWheelSmoothing? config) {
    _config = config;
    _classifier = config == null ? null : WheelClassifier(config);
    _smoother.smoothing = config?.smoothing ?? 0;
    if (config == null) _stopAnimation();
  }

  @override
  void pointerScroll(double delta) {
    final config = _config;
    final classifier = _classifier;
    if (config == null || classifier == null) {
      super.pointerScroll(delta);
      return;
    }
    if (delta == 0) {
      // Inertia cancel: nothing to smooth; a running animation continues.
      if (!_animating) super.pointerScroll(delta);
      return;
    }
    if (classifier.classify(delta, _clock()) == WheelKind.precise) {
      _stopAnimation();
      super.pointerScroll(delta);
      return;
    }
    _addNotch(delta);
  }

  void _addNotch(double delta) {
    final from = _animating ? _target : pixels;
    final target = (from + delta).clamp(minScrollExtent, maxScrollExtent);
    if (target == from && !_animating) return;
    _target = target;
    if (_animating) return;
    _ownTransition = true;
    goIdle();
    _ownTransition = false;
    updateUserScrollDirection(
      delta < 0 ? ScrollDirection.forward : ScrollDirection.reverse,
    );
    _animating = true;
    _smoother.reset(pixels);
    isScrollingNotifier.value = true;
    didStartScroll();
    _ticker ??= context.vsync.createTicker(_tick);
    _lastTick = Duration.zero;
    _ticker!.start();
  }

  void _tick(Duration elapsed) {
    if (!_animating) return;
    final dt = math.min(
      (elapsed - _lastTick).inMicroseconds / 1e6,
      0.05, // a stalled frame must not overshoot the ease
    );
    _lastTick = elapsed;
    _target = _target.clamp(minScrollExtent, maxScrollExtent);
    _smoother.step(_target, dt);
    // Sub-0.05 px: snap, so the scroll ends exactly on the target (the
    // exponential tail would otherwise take another half second).
    if ((_smoother.value - _target).abs() < 0.05 &&
        _smoother.velocity.abs() < 2) {
      _smoother
        ..value = _target
        ..velocity = 0;
    }
    final next = _smoother.value;
    final old = pixels;
    if (next != old) {
      forcePixels(next);
      didUpdateScrollPositionBy(pixels - old);
    }
    // Pinned against an edge by the content: nothing more to do.
    if (_smoother.settledOn(_target) || (pixels - old == 0 && dt > 0.2)) {
      _stopAnimation();
    }
  }

  void _stopAnimation() {
    if (!_animating) return;
    _animating = false;
    _ticker?.stop();
    _smoother.velocity = 0;
    didEndScroll();
    isScrollingNotifier.value = false;
  }

  /// Any other scroll activity (touch drag, keyboard, scrollbar, jumpTo,
  /// animateTo) takes over from a smoothed wheel scroll.
  @override
  void beginActivity(ScrollActivity? newActivity) {
    if (_animating && !_ownTransition) {
      _animating = false;
      _ticker?.stop();
      _smoother.velocity = 0;
      didEndScroll();
    }
    super.beginActivity(newActivity);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }
}
