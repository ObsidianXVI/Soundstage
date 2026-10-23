import 'dart:math' as math;
import 'dart:ui';

/// An 8-bit sRGB colour with alpha, as components.
Color rgbaColor(int r, int g, int b, [double a = 1]) => Color.fromARGB(
  (a.clamp(0.0, 1.0) * 255).round(),
  r.clamp(0, 255),
  g.clamp(0, 255),
  b.clamp(0, 255),
);

int _r(Color c) => (c.toARGB32() >> 16) & 0xFF;
int _g(Color c) => (c.toARGB32() >> 8) & 0xFF;
int _b(Color c) => c.toARGB32() & 0xFF;
double _a(Color c) => ((c.toARGB32() >> 24) & 0xFF) / 255;

/// Hue (0-360), saturation and value (0-1), alpha (0-1).
class SsHsv {
  const SsHsv(this.h, this.s, this.v, [this.a = 1]);

  factory SsHsv.fromColor(Color color) {
    final r = _r(color) / 255;
    final g = _g(color) / 255;
    final b = _b(color) / 255;
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    final d = mx - mn;
    double h;
    if (d == 0) {
      h = 0;
    } else if (mx == r) {
      h = 60 * (((g - b) / d) % 6);
    } else if (mx == g) {
      h = 60 * ((b - r) / d + 2);
    } else {
      h = 60 * ((r - g) / d + 4);
    }
    return SsHsv(h < 0 ? h + 360 : h, mx == 0 ? 0 : d / mx, mx, _a(color));
  }

  final double h;
  final double s;
  final double v;
  final double a;

  Color toColor() {
    final c = v * s;
    final hp = (h % 360) / 60;
    final x = c * (1 - ((hp % 2) - 1).abs());
    final m = v - c;
    double r;
    double g;
    double b;
    if (hp < 1) {
      (r, g, b) = (c, x, 0);
    } else if (hp < 2) {
      (r, g, b) = (x, c, 0);
    } else if (hp < 3) {
      (r, g, b) = (0, c, x);
    } else if (hp < 4) {
      (r, g, b) = (0, x, c);
    } else if (hp < 5) {
      (r, g, b) = (x, 0, c);
    } else {
      (r, g, b) = (c, 0, x);
    }
    return rgbaColor(
      ((r + m) * 255).round(),
      ((g + m) * 255).round(),
      ((b + m) * 255).round(),
      a,
    );
  }

  SsHsv copyWith({double? h, double? s, double? v, double? a}) =>
      SsHsv(h ?? this.h, s ?? this.s, v ?? this.v, a ?? this.a);

  /// The same colour with full saturation and value: the hue strip colour.
  Color get pureHue => SsHsv(h, 1, 1).toColor();
}

/// Hue (0-360), saturation and lightness (0-1), alpha (0-1).
class SsHsl {
  const SsHsl(this.h, this.s, this.l, [this.a = 1]);

  factory SsHsl.fromColor(Color color) {
    final hsv = SsHsv.fromColor(color);
    final l = hsv.v * (1 - hsv.s / 2);
    final s = (l == 0 || l == 1) ? 0.0 : (hsv.v - l) / math.min(l, 1 - l);
    return SsHsl(hsv.h, s, l, hsv.a);
  }

  final double h;
  final double s;
  final double l;
  final double a;

  Color toColor() {
    final v = l + s * math.min(l, 1 - l);
    final sv = v == 0 ? 0.0 : 2 * (1 - l / v);
    return SsHsv(h, sv, v, a).toColor();
  }
}

/// Parses `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA` (the `#` is optional,
/// case-insensitive). Returns null if invalid.
Color? parseHexColor(String input) {
  var s = input.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) return null;
  if (s.length == 3 || s.length == 4) {
    s = s.split('').map((c) => '$c$c').join();
  }
  if (s.length == 6) s = '${s}FF';
  if (s.length != 8) return null;
  final rgb = int.parse(s.substring(0, 6), radix: 16);
  final a = int.parse(s.substring(6), radix: 16);
  return Color((a << 24) | rgb);
}

/// `#RRGGBB`, or `#RRGGBBAA` when [withAlpha] (or the colour is translucent
/// and [withAlpha] is null).
String formatHexColor(Color c, {bool? withAlpha}) {
  String two(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();
  final alpha = ((c.toARGB32() >> 24) & 0xFF);
  final a = withAlpha ?? alpha != 255;
  return '#${two(_r(c))}${two(_g(c))}${two(_b(c))}${a ? two(alpha) : ''}';
}

/// Component accessors used by the picker's inputs.
extension SsColorParts on Color {
  int get red8 => _r(this);
  int get green8 => _g(this);
  int get blue8 => _b(this);
  double get alpha01 => _a(this);
}
