// Pre-solved easing for compiled tracks (architecture §10.2, §17.1).
//
// Pure Dart: no Flutter imports, so the per-frame evaluators can be
// benchmarked and allocation-profiled on their own.
//
// Every curve is evaluated with the *same arithmetic, in the same order* as
// the IR's reference implementation (`lib/ir/src/animation/easing.dart`), so
// compiled output equals the oracle bit for bit (the equivalence test uses a
// 1e-9 tolerance only to stay robust to future refactors). Nothing here
// allocates per call: no closures, no records, no map lookups. The only
// per-segment state (bezier polynomial coefficients, a spring's settle time
// and end value) is solved once at compile time and stored in a
// `Float64List`.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:soundstage_platform/ir/ir.dart' as ir;

/// Easing kinds, as stored in [CompiledEasing.kinds].
abstract final class EaseKind {
  static const int linear = 0;
  static const int bezier = 1;
  static const int spring = 2;
  static const int steps = 3;
  static const int hold = 4;

  /// A spring with invalid parameters: the oracle falls back to linear.
  static const int springLinear = 5;
}

/// Parameters stored per segment.
const int kEaseParamStride = 6;

/// The pre-solved easings of a track's segments.
final class CompiledEasing {
  CompiledEasing._(this.kinds, this.params);

  /// Compiles [easings] (one per segment).
  factory CompiledEasing.of(List<ir.Easing> easings) {
    final kinds = Int32List(easings.length);
    final params = Float64List(easings.length * kEaseParamStride);
    for (var i = 0; i < easings.length; i++) {
      final o = i * kEaseParamStride;
      switch (easings[i]) {
        case ir.LinearEasing():
          kinds[i] = EaseKind.linear;
        case ir.CubicBezierEasing(:final x1, :final y1, :final x2, :final y2):
          kinds[i] = EaseKind.bezier;
          _bezierCoefficients(params, o, x1, y1, x2, y2);
        case ir.PresetEasing(:final preset):
          final (x1, y1, x2, y2) = ir.kEasingPresets[preset]!;
          kinds[i] = EaseKind.bezier;
          _bezierCoefficients(params, o, x1, y1, x2, y2);
        case ir.SpringEasing(:final mass, :final stiffness, :final damping):
          if (!(mass > 0) ||
              !(stiffness > 0) ||
              !mass.isFinite ||
              !stiffness.isFinite) {
            kinds[i] = EaseKind.springLinear;
          } else {
            kinds[i] = EaseKind.spring;
            _springParams(
              params,
              o,
              mass,
              stiffness,
              damping.isFinite ? damping : 0,
            );
          }
        case ir.StepsEasing(:final count, :final position):
          kinds[i] = EaseKind.steps;
          params[o] = (count < 1 ? 1 : count).toDouble();
          params[o + 1] = position == ir.StepPosition.jumpStart ? 1 : 0;
        case ir.HoldEasing():
          kinds[i] = EaseKind.hold;
      }
    }
    return CompiledEasing._(kinds, params);
  }

  final Int32List kinds;
  final Float64List params;

  /// Segment [seg]'s easing at progress [x] (the oracle's `applyEasing`).
  @pragma('vm:prefer-inline')
  double ease(int seg, double x) {
    if (x.isNaN) return 0;
    final u = x < 0 ? 0.0 : (x > 1 ? 1.0 : x);
    final o = seg * kEaseParamStride;
    final p = params;
    switch (kinds[seg]) {
      case EaseKind.linear:
      case EaseKind.springLinear:
        return u;
      case EaseKind.bezier:
        return _bezier(
          p[o],
          p[o + 1],
          p[o + 2],
          p[o + 3],
          p[o + 4],
          p[o + 5],
          u,
        );
      case EaseKind.spring:
        if (u <= 0) return 0;
        if (u >= 1) return 1;
        return _springResponse(p[o], p[o + 1], u * p[o + 2]) / p[o + 3];
      case EaseKind.steps:
        final n = p[o].toInt();
        var step = (u * n).floor();
        if (p[o + 1] == 1) step += 1;
        if (step < 0) step = 0;
        if (step > n) step = n;
        return step / n;
      case EaseKind.hold:
        return u < 1 ? 0 : 1;
    }
    return u;
  }
}

// ---- Cubic bezier ------------------------------------------------------------

void _bezierCoefficients(
  Float64List p,
  int o,
  double x1,
  double y1,
  double x2,
  double y2,
) {
  final cx1 = x1.clamp(0.0, 1.0), cx2 = x2.clamp(0.0, 1.0);
  final cx = 3 * cx1, bx = 3 * (cx2 - cx1) - cx, ax = 1 - cx - bx;
  final cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by;
  p[o] = ax;
  p[o + 1] = bx;
  p[o + 2] = cx;
  p[o + 3] = ay;
  p[o + 4] = by;
  p[o + 5] = cy;
}

/// The oracle's Newton–Raphson + bisection solver, inlined (no closures).
@pragma('vm:prefer-inline')
double _bezier(
  double ax,
  double bx,
  double cx,
  double ay,
  double by,
  double cy,
  double x,
) {
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  const eps = 1e-7;
  var t = x;
  for (var i = 0; i < 8; i++) {
    final err = ((ax * t + bx) * t + cx) * t - x;
    if (err.abs() < eps) return ((ay * t + by) * t + cy) * t;
    final d = (3 * ax * t + 2 * bx) * t + cx;
    if (d.abs() < 1e-6) break;
    t -= err / d;
  }
  var lo = 0.0, hi = 1.0;
  t = x;
  for (var i = 0; i < 64; i++) {
    final v = ((ax * t + bx) * t + cx) * t;
    if ((v - x).abs() < eps) break;
    if (v < x) {
      lo = t;
    } else {
      hi = t;
    }
    t = (lo + hi) / 2;
  }
  return ((ay * t + by) * t + cy) * t;
}

// ---- Spring ------------------------------------------------------------------
//
// Params: [w0, zeta, settleTime, endValue].

void _springParams(Float64List p, int o, double m, double k, double c) {
  final w0 = math.sqrt(k / m);
  final zeta = math.max(c / (2 * math.sqrt(k * m)), ir.kSpringMinDampingRatio);
  // Settle time: the first τ after which the decay envelope stays within
  // kSpringRestThreshold (the oracle's bisection, verbatim).
  var hi = 1 / w0;
  var guard = 0;
  while (_envelope(w0, zeta, hi) > ir.kSpringRestThreshold && guard++ < 200) {
    hi *= 2;
  }
  var lo = 0.0;
  for (var i = 0; i < 80; i++) {
    final mid = (lo + hi) / 2;
    if (_envelope(w0, zeta, mid) > ir.kSpringRestThreshold) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  p[o] = w0;
  p[o + 1] = zeta;
  p[o + 2] = hi;
  p[o + 3] = _springResponse(w0, zeta, hi);
}

@pragma('vm:prefer-inline')
bool _critical(double zeta) => (zeta - 1).abs() < 1e-6;

@pragma('vm:prefer-inline')
double _springResponse(double w0, double zeta, double tau) {
  if (_critical(zeta)) return 1 - math.exp(-w0 * tau) * (1 + w0 * tau);
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

double _envelope(double w0, double zeta, double tau) {
  if (_critical(zeta)) return math.exp(-w0 * tau) * (1 + w0 * tau);
  if (zeta < 1) {
    return math.exp(-zeta * w0 * tau) / math.sqrt(1 - zeta * zeta);
  }
  return 1 - _springResponse(w0, zeta, tau);
}
