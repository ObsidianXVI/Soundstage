import 'dart:math' as math;
import 'dart:ui';

import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'outline.dart';

/// Stroke weights per side.
class SideWeights {
  const SideWeights(this.top, this.right, this.bottom, this.left);
  const SideWeights.uniform(double w) : this(w, w, w, w);

  final double top, right, bottom, left;

  bool get isUniform => top == right && right == bottom && bottom == left;
  double get max => math.max(math.max(top, right), math.max(bottom, left));
  bool get isZero => max <= 0;

  @override
  bool operator ==(Object other) =>
      other is SideWeights &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom &&
      other.left == left;

  @override
  int get hashCode => Object.hash(top, right, bottom, left);

  @override
  String toString() => 'SideWeights($top, $right, $bottom, $left)';
}

SideWeights sideWeights(ir.StrokeWeight w) => switch (w) {
  ir.UniformStrokeWeight(:final weight) => SideWeights.uniform(
    math.max(0, weight),
  ),
  ir.PerSideStrokeWeight(
    :final top,
    :final right,
    :final bottom,
    :final left,
  ) =>
    SideWeights(
      math.max(0, top),
      math.max(0, right),
      math.max(0, bottom),
      math.max(0, left),
    ),
};

/// The inner and outer boundaries of a stroke band on a box [outline]
/// (architecture §5): `inside` grows inwards from the outline, `outside`
/// outwards, and `center` straddles it, each side by its own weight.
///
/// Corner radii stay concentric: the outer boundary of an outside stroke has
/// radius `r + w`, the inner boundary of an inside stroke `r − w`.
({StageOutline outer, StageOutline inner}) strokeBand(
  StageOutline outline,
  ir.StrokeAlign align,
  SideWeights w,
) {
  StageOutline moved(double k) => outline.insetBy(
    left: k * w.left,
    top: k * w.top,
    right: k * w.right,
    bottom: k * w.bottom,
  )!;
  return switch (align) {
    ir.StrokeAlign.inside => (outer: outline, inner: moved(1)),
    ir.StrokeAlign.center => (outer: moved(-0.5), inner: moved(0.5)),
    ir.StrokeAlign.outside => (outer: moved(-1), inner: outline),
  };
}

/// The filled region of [strokeBand]: outer boundary minus inner (even-odd).
Path strokeBandPath(StageOutline outline, ir.StrokeAlign align, SideWeights w) {
  final b = strokeBand(outline, align, w);
  return Path()
    ..fillType = PathFillType.evenOdd
    ..addPath(b.outer.path, Offset.zero)
    ..addPath(b.inner.path, Offset.zero);
}

/// The bounds a stroke of [weight] reaches beyond [bounds].
Rect strokeReach(Rect bounds, ir.StrokeAlign align, double weight) =>
    switch (align) {
      ir.StrokeAlign.inside => bounds,
      ir.StrokeAlign.center => bounds.inflate(weight / 2),
      ir.StrokeAlign.outside => bounds.inflate(weight),
    };

/// [source] cut into dashes: alternating on/off lengths from [pattern],
/// starting [phase] into the pattern. An odd-length pattern repeats to make
/// it even (as in CSS and SVG). Non-positive or empty patterns return
/// [source] unchanged.
Path dashPath(Path source, List<double> pattern, {double phase = 0}) {
  final p = [
    for (final d in pattern)
      if (d.isFinite && d >= 0) d,
  ];
  if (p.isEmpty) return source;
  final cycle = p.length.isOdd ? [...p, ...p] : p;
  final total = cycle.fold<double>(0, (a, b) => a + b);
  if (total <= 0) return source;
  final out = Path();
  for (final metric in source.computeMetrics()) {
    var distance = 0.0;
    var i = 0;
    var offset = phase % total;
    if (offset < 0) offset += total;
    // Skip into the pattern by the phase.
    while (offset >= cycle[i]) {
      offset -= cycle[i];
      i = (i + 1) % cycle.length;
      if (cycle[i] == 0 && offset == 0) break;
    }
    var remaining = cycle[i] - offset;
    var on = i.isEven;
    var guard = 0;
    while (distance < metric.length && guard++ < 100000) {
      final end = math.min(metric.length, distance + remaining);
      if (on && end > distance) {
        out.addPath(metric.extractPath(distance, end), Offset.zero);
      }
      distance = end;
      i = (i + 1) % cycle.length;
      remaining = cycle[i];
      on = i.isEven;
    }
  }
  return out;
}
