import 'dart:math' as math;

import 'package:soundstage_platform/ir/ir.dart' as ir;

// What the easing editor draws (m2.md "Easing editor"): every curve is the
// IR's own `applyEasing` sampled at evenly spaced progress values, so the
// curve on screen is the curve the runtime evaluates (the runtime compiles
// the same arithmetic; see `compiled_easing.dart`).

/// How many samples a smooth curve is drawn with.
const int kCurveSamples = 96;

/// Steps and hold are discontinuous; they get enough samples that their
/// jumps draw as near-vertical segments.
const int kStepCurveSamples = 480;

/// The number of samples [easing] is drawn with.
int sampleCountFor(ir.Easing easing) =>
    easing is ir.StepsEasing || easing is ir.HoldEasing
    ? kStepCurveSamples
    : kCurveSamples;

/// `applyEasing(easing, i / (n - 1))` for i in 0 until n.
List<double> sampleEasing(ir.Easing easing, [int? count]) {
  final n = count ?? sampleCountFor(easing);
  return [for (var i = 0; i < n; i++) ir.applyEasing(easing, i / (n - 1))];
}

/// The smallest and largest of [samples] and of 0 and 1 (the curve's
/// endpoints), so the plot always shows the 0–1 band.
(double, double) sampleRange(Iterable<double> samples) {
  var lo = 0.0, hi = 1.0;
  for (final v in samples) {
    lo = math.min(lo, v);
    hi = math.max(hi, v);
  }
  return (lo, hi);
}

/// `cubic-bezier(x1, y1, x2, y2)` as CSS writes it.
String cubicBezierCss(double x1, double y1, double x2, double y2) =>
    'cubic-bezier(${_num(x1)}, ${_num(y1)}, ${_num(x2)}, ${_num(y2)})';

String _num(double v) {
  final r = (v * 1000).round() / 1000;
  var s = r.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s == '-0' ? '0' : s;
}

/// The control points of [easing] when it is a bezier or a named preset
/// (the editor's bezier mode starts from them), else null.
(double, double, double, double)? controlPointsOf(ir.Easing easing) =>
    switch (easing) {
      ir.CubicBezierEasing(:final x1, :final y1, :final x2, :final y2) => (
        x1,
        y1,
        x2,
        y2,
      ),
      ir.PresetEasing(:final preset) => ir.kEasingPresets[preset],
      ir.LinearEasing() => (0, 0, 1, 1),
      _ => null,
    };

final RegExp _bezierPattern = RegExp(
  r'^\s*(?:cubic-bezier\s*\()?\s*'
  r'(-?\d*\.?\d+)\s*[, ]\s*(-?\d*\.?\d+)\s*[, ]\s*'
  r'(-?\d*\.?\d+)\s*[, ]\s*(-?\d*\.?\d+)\s*\)?\s*$',
  caseSensitive: false,
);

/// Reads `cubic-bezier(x1, y1, x2, y2)` (also the bare four numbers, comma
/// or space separated). x1 and x2 must lie in 0–1, as in CSS; null
/// otherwise or when the text is not a bezier.
ir.CubicBezierEasing? parseCubicBezier(String text) {
  final m = _bezierPattern.firstMatch(text);
  if (m == null) return null;
  final v = [for (var i = 1; i <= 4; i++) double.tryParse(m.group(i)!)];
  if (v.any((e) => e == null || !e.isFinite)) return null;
  final x1 = v[0]!, y1 = v[1]!, x2 = v[2]!, y2 = v[3]!;
  if (x1 < 0 || x1 > 1 || x2 < 0 || x2 > 1) return null;
  return ir.CubicBezierEasing(x1, y1, x2, y2);
}

/// The CSS keyword or Back name of [preset] for the preset grid.
String presetLabel(ir.EasingPreset preset) => switch (preset) {
  ir.EasingPreset.ease => 'Ease',
  ir.EasingPreset.easeIn => 'Ease in',
  ir.EasingPreset.easeOut => 'Ease out',
  ir.EasingPreset.easeInOut => 'Ease in out',
  ir.EasingPreset.easeInBack => 'In back',
  ir.EasingPreset.easeOutBack => 'Out back',
  ir.EasingPreset.easeInOutBack => 'In-out back',
};

/// The mode tab an easing belongs to.
enum EasingMode { preset, bezier, spring, steps, hold }

EasingMode modeOf(ir.Easing easing) => switch (easing) {
  ir.LinearEasing() || ir.PresetEasing() => EasingMode.preset,
  ir.CubicBezierEasing() => EasingMode.bezier,
  ir.SpringEasing() => EasingMode.spring,
  ir.StepsEasing() => EasingMode.steps,
  ir.HoldEasing() => EasingMode.hold,
};
