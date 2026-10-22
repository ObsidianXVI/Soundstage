import 'dart:math' as math;

import '../nodes/effect.dart';
import '../nodes/layout.dart';
import '../nodes/paint.dart';
import '../nodes/stroke.dart';
import '../nodes/text.dart';
import '../values/geometry.dart';
import '../values/ir_value.dart';
import '../values/stage_color.dart';

/// Linear interpolation; [t] may leave 0–1 (overshooting easings).
double lerpDouble(double a, double b, double t) {
  if (t == 0) return a;
  if (t == 1) return b;
  return a + (b - a) * t;
}

// ---- OKLab (Björn Ottosson, https://bottosson.github.io/posts/oklab/) --------

/// A colour in OKLab: perceptual lightness `l` and the `a`/`b` opponent axes.
typedef OkLab = ({double l, double a, double b});

/// The sRGB transfer function, decoded: sRGB-encoded 0–1 → linear light.
double srgbToLinear(double c) =>
    c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

/// Linear light → sRGB-encoded 0–1.
double linearToSrgb(double c) => c <= 0.0031308
    ? 12.92 * c
    : 1.055 * math.pow(c, 1 / 2.4).toDouble() - 0.055;

double _cbrt(double x) =>
    x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();

/// sRGB → OKLab (alpha ignored).
OkLab srgbToOkLab(StageColor c) {
  final r = srgbToLinear(c.r), g = srgbToLinear(c.g), b = srgbToLinear(c.b);
  final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return (
    l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  );
}

/// OKLab → sRGB, clamped to the sRGB gamut (component-wise).
StageColor okLabToSrgb(OkLab lab, [double alpha = 1]) {
  final l_ = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b;
  final m_ = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b;
  final s_ = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b;
  final l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
  double enc(double v) => linearToSrgb(v.clamp(0.0, 1.0)).clamp(0.0, 1.0);
  return StageColor(
    r: enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    g: enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    b: enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
    a: alpha.clamp(0.0, 1.0),
  );
}

/// Interpolates colours in OKLab, with alpha interpolated linearly
/// (straight, not premultiplied). The endpoints are returned exactly.
StageColor lerpColor(StageColor a, StageColor b, double t) {
  if (t == 0 || a == b) return a;
  if (t == 1) return b;
  final x = srgbToOkLab(a), y = srgbToOkLab(b);
  return okLabToSrgb((
    l: lerpDouble(x.l, y.l, t),
    a: lerpDouble(x.a, y.a, t),
    b: lerpDouble(x.b, y.b, t),
  ), lerpDouble(a.a, b.a, t));
}

// ---- Value types -------------------------------------------------------------

StagePoint lerpPoint(StagePoint a, StagePoint b, double t) =>
    StagePoint(x: lerpDouble(a.x, b.x, t), y: lerpDouble(a.y, b.y, t));

StageSize lerpSize(StageSize a, StageSize b, double t) => StageSize(
  width: lerpDouble(a.width, b.width, t),
  height: lerpDouble(a.height, b.height, t),
);

StageRect lerpRect(StageRect a, StageRect b, double t) => StageRect(
  x: lerpDouble(a.x, b.x, t),
  y: lerpDouble(a.y, b.y, t),
  width: lerpDouble(a.width, b.width, t),
  height: lerpDouble(a.height, b.height, t),
);

EdgeInsetsValue lerpInsets(EdgeInsetsValue a, EdgeInsetsValue b, double t) =>
    EdgeInsetsValue(
      top: lerpDouble(a.top, b.top, t),
      right: lerpDouble(a.right, b.right, t),
      bottom: lerpDouble(a.bottom, b.bottom, t),
      left: lerpDouble(a.left, b.left, t),
    );

CornerRadii _corners(CornerRadius r) => switch (r) {
  CornerRadii() => r,
  UniformCornerRadius(:final radius) => CornerRadii(
    tl: radius,
    tr: radius,
    br: radius,
    bl: radius,
  ),
};

/// Uniform↔uniform stays uniform; otherwise per corner.
CornerRadius lerpCornerRadius(CornerRadius a, CornerRadius b, double t) {
  if (a is UniformCornerRadius && b is UniformCornerRadius) {
    return CornerRadius.uniform(lerpDouble(a.radius, b.radius, t));
  }
  final x = _corners(a), y = _corners(b);
  return CornerRadius.perCorner(
    tl: lerpDouble(x.tl, y.tl, t),
    tr: lerpDouble(x.tr, y.tr, t),
    br: lerpDouble(x.br, y.br, t),
    bl: lerpDouble(x.bl, y.bl, t),
  );
}

PerSideStrokeWeight _sides(StrokeWeight w) => switch (w) {
  PerSideStrokeWeight() => w,
  UniformStrokeWeight(:final weight) => PerSideStrokeWeight(
    top: weight,
    right: weight,
    bottom: weight,
    left: weight,
  ),
};

/// Uniform↔uniform stays uniform; otherwise per side.
StrokeWeight lerpStrokeWeight(StrokeWeight a, StrokeWeight b, double t) {
  if (a is UniformStrokeWeight && b is UniformStrokeWeight) {
    return StrokeWeight.uniform(lerpDouble(a.weight, b.weight, t));
  }
  final x = _sides(a), y = _sides(b);
  return StrokeWeight.perSide(
    top: lerpDouble(x.top, y.top, t),
    right: lerpDouble(x.right, y.right, t),
    bottom: lerpDouble(x.bottom, y.bottom, t),
    left: lerpDouble(x.left, y.left, t),
  );
}

// ---- Paints and effects ------------------------------------------------------

/// Interpolates two paints with the same structure (same kind and id; for
/// gradients the same geometry kind and stop count; for images the same
/// asset, scale mode and rotation). Discrete fields (visibility, blend
/// mode) keep [a]'s value for the whole segment. Null when the structures
/// differ.
Paint? lerpPaint(Paint a, Paint b, double t) {
  if (a.id != b.id) return null;
  switch ((a, b)) {
    case (final SolidPaint x, final SolidPaint y):
      return x.copyWith(
        color: lerpColor(x.color, y.color, t),
        opacity: lerpDouble(x.opacity, y.opacity, t),
      );
    case (final GradientPaint x, final GradientPaint y):
      if (x.kind != y.kind || x.stops.length != y.stops.length) return null;
      return x.copyWith(
        stops: [
          for (var i = 0; i < x.stops.length; i++)
            ColorStop(
              position: lerpDouble(x.stops[i].position, y.stops[i].position, t),
              color: lerpColor(x.stops[i].color, y.stops[i].color, t),
            ),
        ],
        handles: GradientHandles(
          start: lerpPoint(x.handles.start, y.handles.start, t),
          end: lerpPoint(x.handles.end, y.handles.end, t),
          width: lerpPoint(x.handles.width, y.handles.width, t),
        ),
        opacity: lerpDouble(x.opacity, y.opacity, t),
      );
    case (final ImagePaint x, final ImagePaint y):
      if (x.assetId != y.assetId ||
          x.scaleMode != y.scaleMode ||
          x.rotation != y.rotation) {
        return null;
      }
      final fx = x.filters, fy = y.filters;
      final xc = x.cropRect, yc = y.cropRect;
      return x.copyWith(
        focalPoint: lerpPoint(x.focalPoint, y.focalPoint, t),
        cropRect: xc != null && yc != null ? lerpRect(xc, yc, t) : xc,
        tileScale: lerpDouble(x.tileScale, y.tileScale, t),
        opacity: lerpDouble(x.opacity, y.opacity, t),
        filters: ImageFilters(
          exposure: lerpDouble(fx.exposure, fy.exposure, t),
          contrast: lerpDouble(fx.contrast, fy.contrast, t),
          saturation: lerpDouble(fx.saturation, fy.saturation, t),
          temperature: lerpDouble(fx.temperature, fy.temperature, t),
          tint: lerpDouble(fx.tint, fy.tint, t),
          highlights: lerpDouble(fx.highlights, fy.highlights, t),
          shadows: lerpDouble(fx.shadows, fy.shadows, t),
        ),
      );
    default:
      return null;
  }
}

/// Stop-wise interpolation of paint stacks; null unless both stacks have
/// the same length and every pair has the same structure ([lerpPaint]).
List<Paint>? lerpPaints(List<Paint> a, List<Paint> b, double t) {
  if (a.length != b.length) return null;
  final out = <Paint>[];
  for (var i = 0; i < a.length; i++) {
    final p = lerpPaint(a[i], b[i], t);
    if (p == null) return null;
    out.add(p);
  }
  return out;
}

/// Field-wise interpolation of two effects of the same kind and id
/// (colour in OKLab, offset, blur, spread, radius); null otherwise.
Effect? lerpEffect(Effect a, Effect b, double t) {
  if (a.id != b.id) return null;
  return switch ((a, b)) {
    (final DropShadow x, final DropShadow y) => x.copyWith(
      color: lerpColor(x.color, y.color, t),
      offset: lerpPoint(x.offset, y.offset, t),
      blur: lerpDouble(x.blur, y.blur, t),
      spread: lerpDouble(x.spread, y.spread, t),
    ),
    (final InnerShadow x, final InnerShadow y) => x.copyWith(
      color: lerpColor(x.color, y.color, t),
      offset: lerpPoint(x.offset, y.offset, t),
      blur: lerpDouble(x.blur, y.blur, t),
      spread: lerpDouble(x.spread, y.spread, t),
    ),
    (final LayerBlur x, final LayerBlur y) => x.copyWith(
      radius: lerpDouble(x.radius, y.radius, t),
    ),
    (final BackgroundBlur x, final BackgroundBlur y) => x.copyWith(
      radius: lerpDouble(x.radius, y.radius, t),
    ),
    _ => null,
  };
}

/// Element-wise [lerpEffect]; null unless the lists match in structure.
List<Effect>? lerpEffects(List<Effect> a, List<Effect> b, double t) {
  if (a.length != b.length) return null;
  final out = <Effect>[];
  for (var i = 0; i < a.length; i++) {
    final e = lerpEffect(a[i], b[i], t);
    if (e == null) return null;
    out.add(e);
  }
  return out;
}

// ---- IrValue -----------------------------------------------------------------

/// Interpolates two property values by their type (architecture §10.2).
/// Null means "cannot interpolate; step": different value types, discrete
/// types (bool, string, enum, token refs, none), or paint/effect stacks
/// whose structure differs. Equal values interpolate to themselves.
IrValue? lerpIrValue(IrValue a, IrValue b, double t) {
  if (a == b) return a;
  return switch ((a, b)) {
    (NumberValue(value: final x), NumberValue(value: final y)) =>
      IrValue.number(lerpDouble(x, y, t)),
    (ColorValue(value: final x), ColorValue(value: final y)) => IrValue.color(
      lerpColor(x, y, t),
    ),
    (SizeValue(value: final x), SizeValue(value: final y)) => IrValue.size(
      lerpSize(x, y, t),
    ),
    (PointValue(value: final x), PointValue(value: final y)) => IrValue.point(
      lerpPoint(x, y, t),
    ),
    (InsetsValue(value: final x), InsetsValue(value: final y)) =>
      IrValue.insets(lerpInsets(x, y, t)),
    (CornerRadiusValue(value: final x), CornerRadiusValue(value: final y)) =>
      IrValue.cornerRadius(lerpCornerRadius(x, y, t)),
    (StrokeWeightValue(value: final x), StrokeWeightValue(value: final y)) =>
      IrValue.strokeWeight(lerpStrokeWeight(x, y, t)),
    (
      GapValue(value: FixedGap(value: final x)),
      GapValue(value: FixedGap(value: final y)),
    ) =>
      IrValue.gap(Gap.fixed(lerpDouble(x, y, t))),
    (
      LineHeightValue(value: PxLineHeight(value: final x)),
      LineHeightValue(value: PxLineHeight(value: final y)),
    ) =>
      IrValue.lineHeight(LineHeight.px(lerpDouble(x, y, t))),
    (
      LineHeightValue(value: PercentLineHeight(value: final x)),
      LineHeightValue(value: PercentLineHeight(value: final y)),
    ) =>
      IrValue.lineHeight(LineHeight.percent(lerpDouble(x, y, t))),
    (
      LetterSpacingValue(value: PxLetterSpacing(value: final x)),
      LetterSpacingValue(value: PxLetterSpacing(value: final y)),
    ) =>
      IrValue.letterSpacing(LetterSpacing.px(lerpDouble(x, y, t))),
    (
      LetterSpacingValue(value: PercentLetterSpacing(value: final x)),
      LetterSpacingValue(value: PercentLetterSpacing(value: final y)),
    ) =>
      IrValue.letterSpacing(LetterSpacing.percent(lerpDouble(x, y, t))),
    (NumbersValue(value: final x), NumbersValue(value: final y))
        when x.length == y.length =>
      IrValue.numbers([
        for (var i = 0; i < x.length; i++) lerpDouble(x[i], y[i], t),
      ]),
    (PaintValue(value: final x), PaintValue(value: final y)) => _wrap(
      lerpPaint(x, y, t),
      IrValue.paint,
    ),
    (PaintsValue(value: final x), PaintsValue(value: final y)) => _wrap(
      lerpPaints(x, y, t),
      IrValue.paints,
    ),
    (EffectValue(value: final x), EffectValue(value: final y)) => _wrap(
      lerpEffect(x, y, t),
      IrValue.effect,
    ),
    (EffectsValue(value: final x), EffectsValue(value: final y)) => _wrap(
      lerpEffects(x, y, t),
      IrValue.effects,
    ),
    _ => null,
  };
}

IrValue? _wrap<T>(T? v, IrValue Function(T) f) => v == null ? null : f(v);
