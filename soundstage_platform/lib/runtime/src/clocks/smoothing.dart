import 'dart:math' as math;

/// A critically damped follower (architecture §10.1, clock `smoothing`).
///
/// The output follows a target like a critically damped spring with angular
/// frequency `ω = 2 / smoothing` (so `smoothing` seconds is roughly the time
/// to arrive, the convention of Unity's `SmoothDamp`): from rest, 59% of a
/// step remains after `smoothing / 2` seconds, 41% after `smoothing`, 9%
/// after `2 · smoothing`.
///
/// [step] integrates the spring **exactly** for a target held constant over
/// `dt` (the closed-form solution, not an Euler step), so the trajectory does
/// not depend on the frame rate: 30, 60 and 120 Hz land on the same values
/// at the same times. Allocation-free.
class StageSmoother {
  StageSmoother({required this.smoothing, double initial = 0})
    : value = initial;

  /// The time constant in seconds; ≤ 0 disables smoothing.
  double smoothing;

  /// The smoothed value.
  double value;

  /// Its rate of change per second.
  double velocity = 0;

  /// Below this distance (and speed × time constant), the follower snaps
  /// to the target and stops.
  static const double restEpsilon = 1e-5;

  /// Whether the follower is at rest on [target].
  bool settledOn(double target) => value == target && velocity == 0;

  /// Jumps to [v] at rest.
  void reset(double v) {
    value = v;
    velocity = 0;
  }

  /// Advances by [dt] seconds towards [target]. Returns whether [value]
  /// changed.
  bool step(double target, double dt) {
    if (smoothing <= 0 || !target.isFinite) {
      final changed = value != target;
      value = target;
      velocity = 0;
      return changed;
    }
    if (dt <= 0) return false;
    final w = 2 / smoothing;
    final e0 = value - target;
    final v0 = velocity;
    final f = math.exp(-w * dt);
    final k = (v0 + w * e0) * dt;
    final e = (e0 + k) * f;
    final v = (v0 - w * k) * f;
    final old = value;
    if (e.abs() < restEpsilon && (v * smoothing).abs() < restEpsilon) {
      value = target;
      velocity = 0;
    } else {
      value = target + e;
      velocity = v;
    }
    return value != old;
  }
}
