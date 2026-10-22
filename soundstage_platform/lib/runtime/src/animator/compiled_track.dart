// Compiled tracks (architecture §10.2, §17.1): a resolved `ir.Track` turned
// into a typed evaluator that runs every frame without touching `IrValue`,
// `PropertyPath` strings or the registry, and without allocating.
//
// Pure Dart (no Flutter imports), so it can be benchmarked and
// allocation-profiled on its own (`test/bench/animator_bench.dart`).

import 'dart:typed_data';

import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'compiled_easing.dart';

/// How a compiled track stores and produces its value.
enum TrackValueKind {
  /// One number: `number`, `gap` (fixed), `lineHeight`, `letterSpacing`.
  scalar,

  /// Several numbers: `size`, `point`, `insets`, `cornerRadius`,
  /// `strokeWeight`, `numbers`.
  vector,

  /// A colour, interpolated in OKLab with straight alpha.
  color,

  /// A discrete value (enum, bool, string, asset id, …): steps at keyframes.
  step,

  /// Structured values (paints, effects, `any`): interpolated through the
  /// registry's interpolator. These allocate per evaluation by design.
  boxed,
}

/// Segment modes.
const int _interpolate = 0;
const int _holdStart = 1;

/// A segment whose keyframe values do not have the property's value type
/// (a malformed track): interpolated through the registry like the oracle,
/// which interpolates by the values' own type. Allocates.
const int _boxedSegment = 2;

/// A track compiled for per-frame evaluation.
///
/// Call [evaluate] with the clock value; it returns whether the output
/// changed. The output is then read without allocation through [scalar] /
/// [component] / [heldIndex], or boxed into an `IrValue` with [value] (which
/// allocates for interpolated values and is meant for slow paths and tests).
///
/// Output always equals `ir.evaluateTrack` (the reference oracle) for the
/// same track and clock value.
final class CompiledTrack {
  CompiledTrack._({
    required this.track,
    required this.match,
    required this.kind,
    required this.valueType,
    required this.stride,
    required this.keyframes,
    required this.times,
    required this.values,
    required this.lab,
    required this.variants,
    required this.segModes,
    required this.easing,
  }) : out = Float64List(stride < 1 ? 1 : stride);

  /// Compiles [track] (keyframes need not be sorted; ties keep their order).
  /// [registry] supplies the property's value type and interpolation; an
  /// unknown property compiles to a step track (the oracle holds too).
  factory CompiledTrack.compile(
    ir.Track track, {
    ir.PropertyRegistry? registry,
  }) {
    final match = (registry ?? ir.PropertyRegistry.standard).lookup(
      track.property,
    );
    final kfs = _sorted(track.keyframes);
    final n = kfs.length;
    final d = match?.descriptor;
    final valueType = d?.valueType ?? ir.IrValueType.any;
    final kind = d == null || d.interpolation == ir.Interpolation.step
        ? TrackValueKind.step
        : _kindOf(valueType);
    var stride = switch (kind) {
      TrackValueKind.scalar => 1,
      TrackValueKind.color => 4,
      TrackValueKind.vector => switch (valueType) {
        ir.IrValueType.size || ir.IrValueType.point => 2,
        _ => 4,
      },
      TrackValueKind.step || TrackValueKind.boxed => 0,
    };
    if (valueType == ir.IrValueType.numbers) {
      stride = 0;
      for (final k in kfs) {
        if (k.value case ir.NumbersValue(:final value)) {
          if (value.length > stride) stride = value.length;
        }
      }
    }

    final times = Float64List(n);
    final values = Float64List(n * stride);
    final lab = Float64List(kind == TrackValueKind.color ? n * 3 : 0);
    final variants = Int32List(n);
    for (var i = 0; i < n; i++) {
      times[i] = kfs[i].t;
      variants[i] = _unpack(
        kind,
        valueType,
        kfs[i].value,
        values,
        i * stride,
        stride,
        lab,
        i * 3,
      );
    }

    final segs = n > 1 ? n - 1 : 0;
    final segModes = Int32List(segs);
    for (var i = 0; i < segs; i++) {
      final a = kfs[i], b = kfs[i + 1];
      final typed =
          kind == TrackValueKind.step ||
          kind == TrackValueKind.boxed ||
          (variants[i] >= 0 && variants[i + 1] >= 0) ||
          (_validVariant(valueType, a.value) &&
              _validVariant(valueType, b.value));
      final compatible = switch (kind) {
        TrackValueKind.step => false,
        TrackValueKind.boxed => true,
        _ =>
          variants[i] >= 0 &&
              variants[i + 1] >= 0 &&
              _compatible(valueType, variants[i], variants[i + 1]),
      };
      segModes[i] = a.easing is ir.HoldEasing || a.value == b.value
          ? _holdStart
          : !typed
          ? _boxedSegment
          : compatible
          ? _interpolate
          : _holdStart;
    }

    return CompiledTrack._(
      track: track,
      match: match,
      kind: kind,
      valueType: valueType,
      stride: stride,
      keyframes: kfs,
      times: times,
      values: values,
      lab: lab,
      variants: variants,
      segModes: segModes,
      easing: CompiledEasing.of([for (var i = 0; i < segs; i++) kfs[i].easing]),
    );
  }

  final ir.Track track;

  /// The property, or null when the registry does not know it.
  final ir.PropertyMatch? match;
  final TrackValueKind kind;
  final ir.IrValueType valueType;

  /// Components per value.
  final int stride;

  /// The keyframes, sorted by `t`.
  final List<ir.Keyframe> keyframes;

  final Float64List times;

  /// `stride` components per keyframe (colours: sRGB r, g, b, a).
  final Float64List values;

  /// Colours: OKLab l, a, b per keyframe.
  final Float64List lab;

  /// Per keyframe: which variant of the value type it holds (e.g. px vs
  /// percent line height, uniform vs per-corner radius, a number list's
  /// length); −1 when it cannot interpolate at all.
  final Int32List variants;

  /// Per segment: interpolate, or hold the start value.
  final Int32List segModes;
  final CompiledEasing easing;

  /// The current output components (valid after [evaluate]).
  final Float64List out;

  int _held = -2; // -2: never evaluated; -1: interpolated; else keyframe index
  int _seg = 0;
  int _outSeg = -1;
  ir.IrValue? _boxed;

  /// The keyframe whose value is the output exactly, or −1 when the output
  /// is interpolated (read it from [out]).
  int get heldIndex => _held;

  /// Whether [evaluate] has run.
  bool get evaluated => _held != -2;

  /// The value-type variant of the current output (e.g. 0 = px, 1 =
  /// percent for line height and letter spacing); −1 when the output is a
  /// value that cannot interpolate (read [value]) or before [evaluate].
  int get currentVariant {
    final h = _held;
    if (h == -2) return -1;
    if (h >= 0) return variants[h];
    if (_boxed != null || _outSeg < 0) return -1;
    return variants[_outSeg];
  }

  /// The first output component (the value of a scalar track).
  double get scalar => out[0];

  /// Output component [i].
  double component(int i) => out[i];

  /// Evaluates at clock value [t] and returns whether the output changed.
  /// Allocation-free for scalar, vector, colour and step tracks.
  bool evaluate(double t) {
    final ts = times;
    final n = ts.length;
    if (n == 0) return false;
    if (t.isNaN || t <= ts[0]) return _hold(0);
    if (t >= ts[n - 1]) return _hold(n - 1);
    var lo = _seg;
    if (lo > n - 2) lo = n - 2;
    while (lo > 0 && ts[lo] > t) {
      lo--;
    }
    while (ts[lo + 1] <= t) {
      lo++;
    }
    _seg = lo;
    final span = ts[lo + 1] - ts[lo];
    if (span <= 0) return _hold(lo + 1);
    final mode = segModes[lo];
    if (mode == _holdStart) return _hold(lo);
    final e = easing.ease(lo, (t - ts[lo]) / span);
    if (mode == _boxedSegment) return _lerpBoxed(lo, e);
    return switch (kind) {
      TrackValueKind.scalar || TrackValueKind.vector => _lerpVector(lo, e),
      TrackValueKind.color => _lerpColor(lo, e),
      TrackValueKind.boxed => _lerpBoxed(lo, e),
      TrackValueKind.step => _hold(lo),
    };
  }

  bool _hold(int k) {
    if (_held == k) return false;
    _held = k;
    _outSeg = -1;
    _boxed = null;
    _boxedE = double.nan;
    final s = stride;
    final o = k * s;
    for (var i = 0; i < s; i++) {
      out[i] = values[o + i];
    }
    return true;
  }

  bool _lerpVector(int seg, double e) {
    var changed = _held != -1 || _outSeg != seg || _boxed != null;
    _boxed = null;
    _held = -1;
    _outSeg = seg;
    final s = stride;
    final oa = seg * s, ob = oa + s;
    for (var i = 0; i < s; i++) {
      final a = values[oa + i], b = values[ob + i];
      final v = e == 0 ? a : (e == 1 ? b : a + (b - a) * e);
      if (v != out[i]) {
        out[i] = v;
        changed = true;
      }
    }
    return changed;
  }

  bool _lerpColor(int seg, double e) {
    // The oracle's lerpColor: endpoints exactly, else OKLab with straight
    // alpha, converted back with a component-wise gamut clamp.
    if (e == 0) return _hold(seg);
    if (e == 1) return _hold(seg + 1);
    var changed = _held != -1 || _boxed != null;
    _boxed = null;
    _held = -1;
    _outSeg = seg;
    final la = seg * 3, lb = la + 3;
    final l0 = lab[la], a0 = lab[la + 1], b0 = lab[la + 2];
    final ll = l0 + (lab[lb] - l0) * e;
    final aa = a0 + (lab[lb + 1] - a0) * e;
    final bb = b0 + (lab[lb + 2] - b0) * e;
    final alphaA = values[seg * 4 + 3], alphaB = values[seg * 4 + 7];
    final alpha = alphaA + (alphaB - alphaA) * e;

    final l_ = ll + 0.3963377774 * aa + 0.2158037573 * bb;
    final m_ = ll - 0.1055613458 * aa - 0.0638541728 * bb;
    final s_ = ll - 0.0894841775 * aa - 1.2914855480 * bb;
    final l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    final r = _enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s);
    final g = _enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s);
    final b = _enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
    final al = alpha < 0 ? 0.0 : (alpha > 1 ? 1.0 : alpha);
    if (out[0] != r) changed = true;
    if (out[1] != g) changed = true;
    if (out[2] != b) changed = true;
    if (out[3] != al) changed = true;
    out[0] = r;
    out[1] = g;
    out[2] = b;
    out[3] = al;
    return changed;
  }

  static double _enc(double v) {
    final c = ir.linearToSrgb(v < 0 ? 0.0 : (v > 1 ? 1.0 : v));
    return c < 0 ? 0.0 : (c > 1 ? 1.0 : c);
  }

  double _boxedE = double.nan;

  bool _lerpBoxed(int seg, double e) {
    if (_held == -1 && _outSeg == seg && _boxedE == e) return false;
    _held = -1;
    _outSeg = seg;
    _boxedE = e;
    final a = keyframes[seg].value, b = keyframes[seg + 1].value;
    _boxed = match?.interpolate(a, b, e) ?? a;
    return true;
  }

  /// The current output as an `IrValue`. Allocates for interpolated
  /// scalar/vector/colour output; held output returns the keyframe's own
  /// value. Null before the first [evaluate] (or without keyframes).
  ir.IrValue? get value {
    final h = _held;
    if (h == -2) return null;
    if (h >= 0) return keyframes[h].value;
    final boxed = _boxed;
    if (boxed != null) return boxed;
    final seg = _outSeg;
    final va = variants[seg], vb = variants[seg + 1];
    final o = out;
    switch (valueType) {
      case ir.IrValueType.number:
        return ir.IrValue.number(o[0]);
      case ir.IrValueType.gap:
        return ir.IrValue.gap(ir.Gap.fixed(o[0]));
      case ir.IrValueType.lineHeight:
        return ir.IrValue.lineHeight(
          va == 0 ? ir.LineHeight.px(o[0]) : ir.LineHeight.percent(o[0]),
        );
      case ir.IrValueType.letterSpacing:
        return ir.IrValue.letterSpacing(
          va == 0 ? ir.LetterSpacing.px(o[0]) : ir.LetterSpacing.percent(o[0]),
        );
      case ir.IrValueType.color:
        return ir.IrValue.color(
          ir.StageColor(r: o[0], g: o[1], b: o[2], a: o[3]),
        );
      case ir.IrValueType.size:
        return ir.IrValue.size(ir.StageSize(width: o[0], height: o[1]));
      case ir.IrValueType.point:
        return ir.IrValue.point(ir.StagePoint(x: o[0], y: o[1]));
      case ir.IrValueType.insets:
        return ir.IrValue.insets(
          ir.EdgeInsetsValue(top: o[0], right: o[1], bottom: o[2], left: o[3]),
        );
      case ir.IrValueType.cornerRadius:
        return ir.IrValue.cornerRadius(
          va == 0 && vb == 0
              ? ir.CornerRadius.uniform(o[0])
              : ir.CornerRadius.perCorner(
                  tl: o[0],
                  tr: o[1],
                  br: o[2],
                  bl: o[3],
                ),
        );
      case ir.IrValueType.strokeWeight:
        return ir.IrValue.strokeWeight(
          va == 0 && vb == 0
              ? ir.StrokeWeight.uniform(o[0])
              : ir.StrokeWeight.perSide(
                  top: o[0],
                  right: o[1],
                  bottom: o[2],
                  left: o[3],
                ),
        );
      case ir.IrValueType.numbers:
        return ir.IrValue.numbers([for (var i = 0; i < va; i++) o[i]]);
      default:
        return keyframes[seg].value;
    }
  }
}

/// Whether [v] has [t]'s type, even if it cannot interpolate (an `auto`
/// gap or line height): such segments hold, like the oracle.
bool _validVariant(ir.IrValueType t, ir.IrValue v) => switch ((t, v)) {
  (ir.IrValueType.gap, ir.GapValue()) ||
  (ir.IrValueType.lineHeight, ir.LineHeightValue()) ||
  (ir.IrValueType.letterSpacing, ir.LetterSpacingValue()) => true,
  _ => false,
};

TrackValueKind _kindOf(ir.IrValueType t) => switch (t) {
  ir.IrValueType.number ||
  ir.IrValueType.gap ||
  ir.IrValueType.lineHeight ||
  ir.IrValueType.letterSpacing => TrackValueKind.scalar,
  ir.IrValueType.size ||
  ir.IrValueType.point ||
  ir.IrValueType.insets ||
  ir.IrValueType.cornerRadius ||
  ir.IrValueType.strokeWeight ||
  ir.IrValueType.numbers => TrackValueKind.vector,
  ir.IrValueType.color => TrackValueKind.color,
  ir.IrValueType.paint ||
  ir.IrValueType.paints ||
  ir.IrValueType.effect ||
  ir.IrValueType.effects ||
  ir.IrValueType.any => TrackValueKind.boxed,
  ir.IrValueType.boolean ||
  ir.IrValueType.string ||
  ir.IrValueType.enumValue => TrackValueKind.step,
};

/// Whether two keyframe variants interpolate (the oracle's `lerpIrValue`).
bool _compatible(ir.IrValueType t, int a, int b) => switch (t) {
  // Uniform and per-corner/per-side values interpolate per component.
  ir.IrValueType.cornerRadius || ir.IrValueType.strokeWeight => true,
  _ => a == b,
};

/// Writes [v]'s components at [values]`[o]` and returns its variant (−1 when
/// it cannot interpolate).
int _unpack(
  TrackValueKind kind,
  ir.IrValueType type,
  ir.IrValue v,
  Float64List values,
  int o,
  int stride,
  Float64List lab,
  int lo,
) {
  void put(List<double> xs) {
    for (var i = 0; i < xs.length && i < stride; i++) {
      values[o + i] = xs[i];
    }
  }

  if (kind == TrackValueKind.step || kind == TrackValueKind.boxed) return 0;
  switch ((type, v)) {
    case (ir.IrValueType.number, ir.NumberValue(:final value)):
      put([value]);
      return 0;
    case (ir.IrValueType.gap, ir.GapValue(value: ir.FixedGap(:final value))):
      put([value]);
      return 0;
    case (
      ir.IrValueType.lineHeight,
      ir.LineHeightValue(value: ir.PxLineHeight(:final value)),
    ):
      put([value]);
      return 0;
    case (
      ir.IrValueType.lineHeight,
      ir.LineHeightValue(value: ir.PercentLineHeight(:final value)),
    ):
      put([value]);
      return 1;
    case (
      ir.IrValueType.letterSpacing,
      ir.LetterSpacingValue(value: ir.PxLetterSpacing(:final value)),
    ):
      put([value]);
      return 0;
    case (
      ir.IrValueType.letterSpacing,
      ir.LetterSpacingValue(value: ir.PercentLetterSpacing(:final value)),
    ):
      put([value]);
      return 1;
    case (ir.IrValueType.color, ir.ColorValue(:final value)):
      put([value.r, value.g, value.b, value.a]);
      final l = ir.srgbToOkLab(value);
      lab[lo] = l.l;
      lab[lo + 1] = l.a;
      lab[lo + 2] = l.b;
      return 0;
    case (ir.IrValueType.size, ir.SizeValue(:final value)):
      put([value.width, value.height]);
      return 0;
    case (ir.IrValueType.point, ir.PointValue(:final value)):
      put([value.x, value.y]);
      return 0;
    case (ir.IrValueType.insets, ir.InsetsValue(:final value)):
      put([value.top, value.right, value.bottom, value.left]);
      return 0;
    case (ir.IrValueType.cornerRadius, ir.CornerRadiusValue(:final value)):
      switch (value) {
        case ir.UniformCornerRadius(:final radius):
          put([radius, radius, radius, radius]);
          return 0;
        case ir.CornerRadii(:final tl, :final tr, :final br, :final bl):
          put([tl, tr, br, bl]);
          return 1;
      }
    case (ir.IrValueType.strokeWeight, ir.StrokeWeightValue(:final value)):
      switch (value) {
        case ir.UniformStrokeWeight(:final weight):
          put([weight, weight, weight, weight]);
          return 0;
        case ir.PerSideStrokeWeight(
          :final top,
          :final right,
          :final bottom,
          :final left,
        ):
          put([top, right, bottom, left]);
          return 1;
      }
    case (ir.IrValueType.numbers, ir.NumbersValue(:final value)):
      put(value);
      return value.length;
    default:
      return -1;
  }
}

List<ir.Keyframe> _sorted(List<ir.Keyframe> kfs) {
  for (var i = 1; i < kfs.length; i++) {
    if (kfs[i].t < kfs[i - 1].t) {
      final indexed = [for (var j = 0; j < kfs.length; j++) (j, kfs[j])]
        ..sort((x, y) {
          final c = x.$2.t.compareTo(y.$2.t);
          return c != 0 ? c : x.$1.compareTo(y.$1);
        });
      return [for (final (_, k) in indexed) k];
    }
  }
  return List.unmodifiable(kfs);
}
