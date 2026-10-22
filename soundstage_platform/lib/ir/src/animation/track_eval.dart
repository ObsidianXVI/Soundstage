import '../motion.dart';
import '../registry/property_registry.dart';
import '../values/ir_value.dart';
import 'easing.dart';

/// Evaluates [track] at clock value [t] (architecture §10.2).
///
/// - Before the first keyframe: the first keyframe's value. After the last:
///   the last's.
/// - Between keyframes `i` and `i+1`: progress is eased by keyframe `i`'s
///   easing, then interpolated by the property's interpolator from
///   [registry] (by `track.property`).
/// - Step properties, `hold` easing, values that cannot interpolate (e.g.
///   paint stacks of different structure) and unknown properties hold
///   keyframe `i`'s value until keyframe `i+1`'s time.
///
/// Keyframes need not be sorted (ties keep their order). Null only when the
/// track has no keyframes.
IrValue? evaluateTrack(Track track, double t, {PropertyRegistry? registry}) {
  final kfs = _sorted(track.keyframes);
  if (kfs.isEmpty) return null;
  if (t.isNaN || t <= kfs.first.t) return kfs.first.value;
  if (t >= kfs.last.t) return kfs.last.value;

  // Last keyframe with kf.t <= t.
  var lo = 0, hi = kfs.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (kfs[mid].t <= t) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  final a = kfs[lo], b = kfs[lo + 1];
  final span = b.t - a.t;
  if (span <= 0) return b.value;
  if (a.easing is HoldEasing) return a.value;
  final e = applyEasing(a.easing, (t - a.t) / span);
  final match = (registry ?? PropertyRegistry.standard).lookup(track.property);
  final v = match?.interpolate(a.value, b.value, e);
  return v ?? a.value;
}

List<Keyframe> _sorted(List<Keyframe> kfs) {
  for (var i = 1; i < kfs.length; i++) {
    if (kfs[i].t < kfs[i - 1].t) {
      final copy = [for (var j = 0; j < kfs.length; j++) (j, kfs[j])]
        ..sort((x, y) {
          final c = x.$2.t.compareTo(y.$2.t);
          return c != 0 ? c : x.$1.compareTo(y.$1);
        });
      return [for (final (_, k) in copy) k];
    }
  }
  return kfs;
}
