import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

// The timeline's pure math (m2.md "Timeline lanes"): clock ranges and units,
// the time ↔ pixel mapping, ruler ticks, snapping and nudge steps. No
// widgets, so it is unit-tested on its own.

/// How a clock's values read on the ruler.
enum ClockUnit {
  /// 0–1 scene progress, shown as 0–100 %.
  progress,

  /// Seconds (timeline and audio clocks).
  seconds,

  /// −1…1 (pointer clocks).
  signed,

  /// A behaviour-defined value.
  value,
}

/// The span of clock values the ruler shows by default, and that keyframe
/// drags are kept inside ([clamp]). [max] is open-ended for seconds (a
/// keyframe may sit past a timeline's duration, as in the IR).
@immutable
class ClockSpan {
  const ClockSpan(this.min, this.max, this.unit, {this.openEnded = false});

  final double min, max;
  final ClockUnit unit;

  /// Keyframes may move past [max] (seconds).
  final bool openEnded;

  double get span => max - min;

  /// [t] kept inside the range ([max] ignored when [openEnded]).
  double clamp(double t) {
    if (t < min) return min;
    if (!openEnded && t > max) return max;
    return t;
  }

  /// Whether transport (play/pause, loop) applies: timeline and audio
  /// clocks only (m2.md).
  bool get playable => unit == ClockUnit.seconds;

  @override
  bool operator ==(Object other) =>
      other is ClockSpan &&
      other.min == min &&
      other.max == max &&
      other.unit == unit &&
      other.openEnded == openEnded;

  @override
  int get hashCode => Object.hash(min, max, unit, openEnded);
}

/// The latest keyframe time of [scene]'s tracks on [clockId], or null.
double? lastKeyframeTime(ir.Scene scene, String clockId) {
  double? last;
  for (final t in scene.tracks) {
    if (t.clockId != clockId || t.keyframes.isEmpty) continue;
    final k = t.keyframes.last.t;
    if (last == null || k > last) last = k;
  }
  return last;
}

/// The default range of [clock] in [scene] (architecture §10.1 units):
/// 0–1 for scene scroll, 0–duration for a timeline, 0 to the asset's
/// duration (else the last keyframe, else 10 s) for audio, −1…1 for a
/// pointer, and 0 to the last keyframe (at least 1) for a behaviour clock.
ClockSpan clockSpan(ir.StageDocument doc, ir.Scene scene, ir.Clock clock) {
  final last = lastKeyframeTime(scene, clock.id);
  switch (clock) {
    case ir.SceneScrollClock():
      return const ClockSpan(0, 1, ClockUnit.progress);
    case ir.TimelineClock(:final duration):
      return ClockSpan(
        0,
        duration > 0 ? duration : 1,
        ClockUnit.seconds,
        openEnded: true,
      );
    case ir.AudioClock(:final audioTrackId):
      double? d;
      for (final a in doc.audioTracks) {
        if (a.id == audioTrackId) d = doc.assets[a.assetId]?.duration;
      }
      final end = d ?? last ?? 10;
      return ClockSpan(
        0,
        end > 0 ? end : 10,
        ClockUnit.seconds,
        openEnded: true,
      );
    case ir.PointerClock():
      return const ClockSpan(-1, 1, ClockUnit.signed);
    case ir.BehaviorClock():
      return ClockSpan(
        0,
        math.max(1, last ?? 1),
        ClockUnit.value,
        openEnded: true,
      );
  }
}

/// [t] as the ruler and readouts show it: "42%", "1.25 s", "−0.50", "3".
String formatClockValue(double t, ClockUnit unit, {double? step}) {
  int digits(double scaledStep) {
    if (scaledStep >= 1 || scaledStep <= 0) return 0;
    return math.min(3, (-math.log(scaledStep) / math.ln10).ceil());
  }

  switch (unit) {
    case ClockUnit.progress:
      final p = t * 100;
      final d = step == null ? 1 : digits(step * 100);
      return '${_trim(p, d)}%';
    case ClockUnit.seconds:
      final d = step == null ? 2 : digits(step);
      return '${_trim(t, d)} s';
    case ClockUnit.signed:
      final d = step == null ? 2 : digits(step);
      return _trim(t, d).replaceFirst('-', '−');
    case ClockUnit.value:
      final d = step == null ? 2 : digits(step);
      return _trim(t, d);
  }
}

String _trim(double v, int digits) {
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s == '-0' ? '0' : s;
}

// ---- Time ↔ pixels ------------------------------------------------------------

/// The horizontal mapping of the lanes and ruler: [start] is the clock
/// value at x = 0 and [pxPerUnit] the zoom.
@immutable
class TimelineView {
  const TimelineView({required this.start, required this.pxPerUnit});

  /// A view showing [range] across [width] pixels with [margin] pixels on
  /// both sides.
  factory TimelineView.fit(
    ClockSpan range,
    double width, {
    double margin = 12,
  }) {
    final usable = math.max(1.0, width - 2 * margin);
    final px = usable / (range.span > 0 ? range.span : 1);
    return TimelineView(start: range.min - margin / px, pxPerUnit: px);
  }

  final double start;
  final double pxPerUnit;

  double xOf(double t) => (t - start) * pxPerUnit;
  double tOf(double x) => start + x / pxPerUnit;

  /// Pans by [dx] pixels (positive: the content moves right).
  TimelineView panBy(double dx) =>
      TimelineView(start: start - dx / pxPerUnit, pxPerUnit: pxPerUnit);

  /// Zooms by [factor] about pixel [x] (the value under [x] stays put),
  /// keeping [pxPerUnit] inside [minPx]…[maxPx].
  TimelineView zoomAbout(
    double x,
    double factor, {
    double minPx = 1e-3,
    double maxPx = 1e7,
  }) {
    final px = (pxPerUnit * factor).clamp(minPx, maxPx);
    final anchor = tOf(x);
    return TimelineView(start: anchor - x / px, pxPerUnit: px);
  }

  @override
  bool operator ==(Object other) =>
      other is TimelineView &&
      other.start == start &&
      other.pxPerUnit == pxPerUnit;

  @override
  int get hashCode => Object.hash(start, pxPerUnit);
}

// ---- Ruler ticks ----------------------------------------------------------------

/// One ruler tick at clock value [t]; [major] ticks carry a label.
typedef RulerTick = ({double t, bool major});

/// The tick spacing for [view] in clock units: the smallest "nice" step
/// (1, 2 or 5 × 10ⁿ in display units: percent for progress) whose major
/// ticks are at least [minMajorPx] apart. Minor ticks divide a major step
/// into [RulerSteps.minorPerMajor].
@immutable
class RulerSteps {
  const RulerSteps(this.major, this.minorPerMajor);

  final double major;
  final int minorPerMajor;

  double get minor => major / minorPerMajor;
}

RulerSteps rulerSteps(
  TimelineView view,
  ClockUnit unit, {
  double minMajorPx = 72,
}) {
  final scale = unit == ClockUnit.progress ? 100.0 : 1.0; // display units
  final minMajor = minMajorPx / view.pxPerUnit * scale;
  final exp = (math.log(minMajor) / math.ln10).floor();
  final base = math.pow(10, exp).toDouble();
  for (final (m, minor) in const [(1, 5), (2, 4), (5, 5), (10, 5)]) {
    final step = m * base;
    if (step >= minMajor * (1 - 1e-9)) return RulerSteps(step / scale, minor);
  }
  return RulerSteps(10 * base / scale, 5);
}

/// The ticks between pixels 0 and [width] of [view].
List<RulerTick> rulerTicks(
  TimelineView view,
  double width,
  ClockUnit unit, {
  double minMajorPx = 72,
}) {
  final steps = rulerSteps(view, unit, minMajorPx: minMajorPx);
  final minor = steps.minor;
  final first = (view.tOf(0) / minor).ceil();
  final last = (view.tOf(width) / minor).floor();
  final out = <RulerTick>[];
  for (var i = first; i <= last && out.length < 2000; i++) {
    out.add((t: i * minor, major: i % steps.minorPerMajor == 0));
  }
  return out;
}

// ---- Snapping -------------------------------------------------------------------

/// The result of [snapTime]: the snapped value and the target it snapped
/// to (null when nothing was close enough).
typedef SnapResult = ({double t, double? target});

/// Snaps [t] to the nearest of [candidates] within [threshold] (clock
/// units); ties keep the first candidate. Without one in reach, [t].
SnapResult snapTime(double t, Iterable<double> candidates, double threshold) {
  double? best;
  var bestD = double.infinity;
  for (final c in candidates) {
    final d = (c - t).abs();
    if (d <= threshold * (1 + 1e-9) && d < bestD) {
      best = c;
      bestD = d;
    }
  }
  return best == null ? (t: t, target: null) : (t: best, target: best);
}

/// The snap candidates of a keyframe drag (m2.md): the playhead, the
/// keyframes not being dragged ([others]) and the ruler's minor ticks in
/// view between pixels 0 and [width].
List<double> dragSnapCandidates({
  required double playhead,
  required Iterable<double> others,
  required TimelineView view,
  required double width,
  required ClockUnit unit,
}) => [
  playhead,
  ...others,
  for (final tick in rulerTicks(view, width, unit)) tick.t,
];

/// The time delta of a keyframe drag: the grabbed keyframe (at
/// [grabbedT]) follows the pointer by [rawDelta] and snaps to [candidates]
/// within [thresholdPx] pixels unless [snap] is off (Shift). The delta is
/// then limited so every dragged keyframe ([dragged] times) stays inside
/// [range].
({double delta, double? target}) keyframeDragDelta({
  required double grabbedT,
  required double rawDelta,
  required Iterable<double> dragged,
  required ClockSpan range,
  required TimelineView view,
  required Iterable<double> candidates,
  bool snap = true,
  double thresholdPx = 6,
}) {
  var target = grabbedT + rawDelta;
  double? snappedTo;
  if (snap) {
    final s = snapTime(target, candidates, thresholdPx / view.pxPerUnit);
    target = s.t;
    snappedTo = s.target;
  }
  var delta = target - grabbedT;
  final limited = limitDelta(delta, dragged, range);
  if (limited != delta) snappedTo = null;
  delta = limited;
  return (delta: delta, target: snappedTo);
}

/// [delta] limited so that every time of [times] plus it stays in [range].
double limitDelta(double delta, Iterable<double> times, ClockSpan range) {
  if (times.isEmpty) return delta;
  final lo = times.reduce(math.min);
  final hi = times.reduce(math.max);
  if (lo + delta < range.min) delta = range.min - lo;
  if (!range.openEnded && hi + delta > range.max) delta = range.max - hi;
  return delta;
}

/// The arrow-key nudge of keyframes in [unit] (Shift: [big]): 1 % of the
/// scene (10 %), 1/10 s (1 s), 0.05 (0.5) for pointer and behaviour clocks.
double nudgeStep(ClockUnit unit, {bool big = false}) {
  final s = switch (unit) {
    ClockUnit.progress => 0.01,
    ClockUnit.seconds => 0.1,
    ClockUnit.signed || ClockUnit.value => 0.05,
  };
  return big ? s * 10 : s;
}

// ---- Labels ----------------------------------------------------------------------

/// The name of [easing] as the timeline and the Motion section show it.
String easingName(ir.Easing easing) => switch (easing) {
  ir.LinearEasing() => 'Linear',
  ir.CubicBezierEasing(:final x1, :final y1, :final x2, :final y2) =>
    'Cubic bezier (${_trim(x1, 2)}, ${_trim(y1, 2)}, ${_trim(x2, 2)}, ${_trim(y2, 2)})',
  ir.PresetEasing(:final preset) => switch (preset) {
    ir.EasingPreset.ease => 'Ease',
    ir.EasingPreset.easeIn => 'Ease in',
    ir.EasingPreset.easeOut => 'Ease out',
    ir.EasingPreset.easeInOut => 'Ease in out',
    ir.EasingPreset.easeInBack => 'Ease in back',
    ir.EasingPreset.easeOutBack => 'Ease out back',
    ir.EasingPreset.easeInOutBack => 'Ease in out back',
  },
  ir.SpringEasing() => 'Spring',
  ir.StepsEasing(:final count) => 'Steps ($count)',
  ir.HoldEasing() => 'Hold',
};

/// A one-line summary of [track]'s segment easings: the shared name, else
/// "Mixed"; "—" for a track with one keyframe (no segment).
String easingSummary(ir.Track track) {
  final kfs = track.keyframes;
  if (kfs.length < 2) return '—';
  final first = easingName(kfs.first.easing);
  for (var i = 1; i < kfs.length - 1; i++) {
    if (easingName(kfs[i].easing) != first) return 'Mixed';
  }
  return first;
}

/// The clock picker's name for [clock]: its name when it has one (T2.4),
/// else one derived from its kind and target. (A behaviour clock's `name`
/// names the behaviour's value, not the clock, so it is always derived.)
String clockLabel(ir.StageDocument doc, ir.Clock clock) {
  final own = switch (clock) {
    ir.SceneScrollClock(:final name) ||
    ir.TimelineClock(:final name) ||
    ir.AudioClock(:final name) ||
    ir.PointerClock(:final name) => name,
    ir.BehaviorClock() => '',
  };
  if (own.isNotEmpty) return own;
  String nodeName(String id) {
    final n = ir.DocumentIndex.of(doc).node(id);
    final name = n?.common.name ?? '';
    return name.isEmpty ? id : name;
  }

  return switch (clock) {
    ir.SceneScrollClock() => 'Scene scroll',
    ir.TimelineClock(:final duration) => 'Timeline · ${_trim(duration, 2)} s',
    ir.AudioClock(:final audioTrackId) => () {
      for (final a in doc.audioTracks) {
        if (a.id == audioTrackId) {
          final asset = doc.assets[a.assetId];
          final n = asset?.name ?? '';
          return 'Audio · ${n.isEmpty ? a.id : n}';
        }
      }
      return 'Audio';
    }(),
    ir.PointerClock(:final frameId, :final axis) =>
      'Pointer ${axis.name.toUpperCase()} · ${nodeName(frameId)}',
    ir.BehaviorClock(:final nodeId, :final name) =>
      'Behaviour $name · ${nodeName(nodeId)}',
  };
}
