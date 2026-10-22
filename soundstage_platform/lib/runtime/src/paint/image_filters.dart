import 'dart:math' as math;
import 'dart:ui' show ColorFilter;

import 'package:soundstage_platform/ir/ir.dart' as ir;

/// The identity 4x5 colour matrix (row-major, offsets in 0–1).
const List<double> kIdentityColorMatrix = [
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0,
  0, 0, 1, 0, 0,
  0, 0, 0, 1, 0,
];

/// Rec. 709 luma weights.
const double _lr = 0.2126, _lg = 0.7152, _lb = 0.0722;

/// `a` applied after `b`: out = a(b(x)).
List<double> multiplyColorMatrices(List<double> a, List<double> b) {
  final out = List<double>.filled(20, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 5; col++) {
      var sum = 0.0;
      for (var k = 0; k < 4; k++) {
        sum += a[row * 5 + k] * b[k * 5 + col];
      }
      if (col == 4) sum += a[row * 5 + 4];
      out[row * 5 + col] = sum;
    }
  }
  return out;
}

/// The 4x5 colour matrix (row-major, offsets in 0–1) for [f], or null when
/// every adjustment is zero.
///
/// Each adjustment is in −1…1 (Figma's ranges). Order of application:
/// exposure, contrast, highlights/shadows, saturation, temperature, tint.
///
/// - **exposure**: gain `2^e` on RGB.
/// - **contrast**: `(x − 0.5) · (1 + c) + 0.5`.
/// - **saturation**: blend with Rec. 709 luma by `1 + s` (−1 = greyscale).
/// - **temperature**: red gain `1 + 0.2t`, blue gain `1 − 0.2t` (+ = warmer).
/// - **tint**: green gain `1 − 0.2t` (+ = towards magenta).
/// - **highlights / shadows** are a tone curve in Figma and cannot be a
///   matrix. Approximation: shadows lift or crush the black point
///   (`x · (1 − 0.25s) + 0.25s`, which keeps white), and highlights scale
///   the white point (`x · (1 + 0.25h)`, which keeps black). Unlike the
///   real curves they act on all tones, not just the dark or bright ones.
List<double>? imageFilterMatrix(ir.ImageFilters f) {
  if (f.exposure == 0 &&
      f.contrast == 0 &&
      f.saturation == 0 &&
      f.temperature == 0 &&
      f.tint == 0 &&
      f.highlights == 0 &&
      f.shadows == 0) {
    return null;
  }
  List<double> gain(double r, double g, double b) => [
    r, 0, 0, 0, 0, //
    0, g, 0, 0, 0,
    0, 0, b, 0, 0,
    0, 0, 0, 1, 0,
  ];
  List<double> linear(double scale, double offset) => [
    scale, 0, 0, 0, offset, //
    0, scale, 0, 0, offset,
    0, 0, scale, 0, offset,
    0, 0, 0, 1, 0,
  ];

  var m = kIdentityColorMatrix;
  void then(List<double> next) => m = multiplyColorMatrices(next, m);

  if (f.exposure != 0) {
    final g = math.pow(2, f.exposure).toDouble();
    then(gain(g, g, g));
  }
  if (f.contrast != 0) {
    final c = 1 + f.contrast;
    then(linear(c, 0.5 - 0.5 * c));
  }
  if (f.highlights != 0) then(linear(1 + 0.25 * f.highlights, 0));
  if (f.shadows != 0) {
    then(linear(1 - 0.25 * f.shadows, 0.25 * f.shadows));
  }
  if (f.saturation != 0) {
    final k = 1 + f.saturation;
    final i = 1 - k;
    then([
      i * _lr + k, i * _lg, i * _lb, 0, 0, //
      i * _lr, i * _lg + k, i * _lb, 0, 0,
      i * _lr, i * _lg, i * _lb + k, 0, 0,
      0, 0, 0, 1, 0,
    ]);
  }
  if (f.temperature != 0) {
    then(gain(1 + 0.2 * f.temperature, 1, 1 - 0.2 * f.temperature));
  }
  if (f.tint != 0) then(gain(1, 1 - 0.2 * f.tint, 1));
  return m;
}

/// [imageFilterMatrix] as a Flutter [ColorFilter] (whose offsets are in
/// 0–255), or null for no adjustments.
ColorFilter? imageColorFilter(ir.ImageFilters f) {
  final m = imageFilterMatrix(f);
  if (m == null) return null;
  return ColorFilter.matrix([
    for (var i = 0; i < 20; i++) i % 5 == 4 ? m[i] * 255 : m[i],
  ]);
}
