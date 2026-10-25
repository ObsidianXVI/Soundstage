import 'dart:math' as math;

import '../motion.dart';

/// Control points of the named presets.
///
/// The first four are CSS's keywords (CSS Easing Functions Level 1). The
/// `…Back` variants are the easings.net "back" curves (`easeInBack`
/// `cubic-bezier(0.36, 0, 0.66, -0.56)`, `easeOutBack`
/// `cubic-bezier(0.34, 1.56, 0.64, 1)`, `easeInOutBack`
/// `cubic-bezier(0.68, -0.6, 0.32, 1.6)`), which overshoot below 0 / above
/// 1.
const Map<EasingPreset, (double, double, double, double)> kEasingPresets = {
  EasingPreset.ease: (0.25, 0.1, 0.25, 1),
  EasingPreset.easeIn: (0.42, 0, 1, 1),
  EasingPreset.easeOut: (0, 0, 0.58, 1),
  EasingPreset.easeInOut: (0.42, 0, 0.58, 1),
  EasingPreset.easeInBack: (0.36, 0, 0.66, -0.56),
  EasingPreset.easeOutBack: (0.34, 1.56, 0.64, 1),
  EasingPreset.easeInOutBack: (0.68, -0.6, 0.32, 1.6),
};

/// Maps segment progress [x] (0–1) through [easing] (architecture §10.2).
/// The result is 0 at 0 and 1 at 1, and may leave 0–1 in between for
/// overshooting curves (Back presets, under-damped springs).
double applyEasing(Easing easing, double x) {
  if (x.isNaN) return 0;
  final u = x.clamp(0.0, 1.0);
  return switch (easing) {
    LinearEasing() => u,
    CubicBezierEasing(:final x1, :final y1, :final x2, :final y2) =>
      cubicBezier(x1, y1, x2, y2, u),
    PresetEasing(:final preset) => _preset(preset, u),
    SpringEasing(:final mass, :final stiffness, :final damping) => springEase(
      mass,
      stiffness,
      damping,
      u,
    ),
    StepsEasing(:final count, :final position) => stepsEase(count, position, u),
    HoldEasing() => u < 1 ? 0 : 1,
  };
}

double _preset(EasingPreset p, double x) {
  final (x1, y1, x2, y2) = kEasingPresets[p]!;
  return cubicBezier(x1, y1, x2, y2, x);
}

/// CSS `cubic-bezier(x1, y1, x2, y2)` at progress [x]: solves the curve's
/// x(t) = [x] for t with Newton–Raphson, falling back to bisection, to
/// within 1e-7, then returns y(t). `x1`/`x2` are clamped to 0–1 as CSS
/// requires (so x(t) is monotonic).
double cubicBezier(double x1, double y1, double x2, double y2, double x) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  final cx1 = x1.clamp(0.0, 1.0), cx2 = x2.clamp(0.0, 1.0);
  // Polynomial coefficients: f(t) = ((a t + b) t + c) t.
  final cx = 3 * cx1, bx = 3 * (cx2 - cx1) - cx, ax = 1 - cx - bx;
  final cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  double sx(double t) => ((ax * t + bx) * t + cx) * t;
  double dx(double t) => (3 * ax * t + 2 * bx) * t + cx;
  double sy(double t) => ((ay * t + by) * t + cy) * t;

  const eps = 1e-7;
  var t = x;
  for (var i = 0; i < 8; i++) {
    final err = sx(t) - x;
    if (err.abs() < eps) return sy(t);
    final d = dx(t);
    if (d.abs() < 1e-6) break;
    t -= err / d;
  }
  var lo = 0.0, hi = 1.0;
  t = x;
  for (var i = 0; i < 64; i++) {
    final v = sx(t);
    if ((v - x).abs() < eps) break;
    if (v < x) {
      lo = t;
    } else {
      hi = t;
    }
    t = (lo + hi) / 2;
  }
  return sy(t);
}

/// CSS `steps(count, jump-start | jump-end)` at progress [x].
double stepsEase(int count, StepPosition position, double x) {
  final n = count < 1 ? 1 : count;
  var step = (x * n).floor();
  if (position == StepPosition.jumpStart) step += 1;
  if (step < 0) step = 0;
  if (step > n) step = n;
  return step / n;
}

/// Below this |1 − x| the spring counts as settled.
const double kSpringRestThreshold = 1e-3;

/// The smallest damping ratio used; a ratio ≤ 0 would never settle.
const double kSpringMinDampingRatio = 0.01;

final Map<(double, double, double), _Spring> _springCache = {};

/// A spring's analytic step response, normalised to a segment.
///
/// The spring (mass `m`, stiffness `k`, damping `c`) starts at 0 with zero
/// velocity and is pulled to 1. Its natural frequency is ω₀ = √(k/m) and its
/// damping ratio ζ = c / (2√(km)). The segment's duration maps to the
/// spring's **settle time** `Tₛ`: the first time after which the response's
/// decay envelope stays within [kSpringRestThreshold] of 1. Progress `u` maps
/// to time `u·Tₛ`, and the response is divided by its value at `Tₛ`, so the
/// segment ends at exactly 1. The spring parameters therefore set the
/// curve's shape (bounce, overshoot), and the keyframe spacing sets its
/// duration.
///
/// Non-positive or non-finite `mass`/`stiffness` fall back to linear.
double springEase(double mass, double stiffness, double damping, double u) {
  if (!(mass > 0) ||
      !(stiffness > 0) ||
      !mass.isFinite ||
      !stiffness.isFinite) {
    return u;
  }
  if (u <= 0) return 0;
  if (u >= 1) return 1;
  final s = _springFor(mass, stiffness, damping);
  return s.response(u * s.settleTime) / s.endValue;
}

/// The spring's natural settle time in seconds: how long the physical
/// spring takes to come within [kSpringRestThreshold] of rest. A segment
/// plays the response over its own duration, so this is the duration at
/// which the spring runs at its real speed (the easing editor shows it).
/// 0 for parameters [springEase] treats as linear.
double springSettleTime(double mass, double stiffness, double damping) {
  if (!(mass > 0) ||
      !(stiffness > 0) ||
      !mass.isFinite ||
      !stiffness.isFinite) {
    return 0;
  }
  return _springFor(mass, stiffness, damping).settleTime;
}

_Spring _springFor(double mass, double stiffness, double damping) {
  final s = _springCache.putIfAbsent((
    mass,
    stiffness,
    damping,
  ), () => _Spring(mass, stiffness, damping.isFinite ? damping : 0));
  if (_springCache.length > 256) _springCache.clear();
  return s;
}

class _Spring {
  _Spring(double m, double k, double c)
    : w0 = math.sqrt(k / m),
      zeta = math.max(c / (2 * math.sqrt(k * m)), kSpringMinDampingRatio) {
    settleTime = _solveSettle();
    endValue = response(settleTime);
  }

  final double w0;
  final double zeta;
  late final double settleTime;
  late final double endValue;

  bool get _critical => (zeta - 1).abs() < 1e-6;

  /// x(τ): 0 at τ = 0, → 1 as τ → ∞.
  double response(double tau) {
    if (_critical) return 1 - math.exp(-w0 * tau) * (1 + w0 * tau);
    if (zeta < 1) {
      final wd = w0 * math.sqrt(1 - zeta * zeta);
      return 1 -
          math.exp(-zeta * w0 * tau) *
              (math.cos(wd * tau) + (zeta * w0 / wd) * math.sin(wd * tau));
    }
    final root = math.sqrt(zeta * zeta - 1);
    final r1 = -w0 * (zeta - root), r2 = -w0 * (zeta + root);
    return 1 - (r2 * math.exp(r1 * tau) - r1 * math.exp(r2 * tau)) / (r2 - r1);
  }

  /// A monotonically decreasing bound on |1 − x(τ)|.
  double _envelope(double tau) {
    if (_critical) return math.exp(-w0 * tau) * (1 + w0 * tau);
    if (zeta < 1) {
      return math.exp(-zeta * w0 * tau) / math.sqrt(1 - zeta * zeta);
    }
    return 1 - response(tau); // over-damped: monotonic approach
  }

  double _solveSettle() {
    var hi = 1 / w0;
    var guard = 0;
    while (_envelope(hi) > kSpringRestThreshold && guard++ < 200) {
      hi *= 2;
    }
    var lo = 0.0;
    for (var i = 0; i < 80; i++) {
      final mid = (lo + hi) / 2;
      if (_envelope(mid) > kSpringRestThreshold) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi;
  }
}
