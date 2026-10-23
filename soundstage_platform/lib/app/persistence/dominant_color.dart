import 'dart:typed_data';

/// The dominant colour of a small RGBA image (row-major, 4 bytes a pixel),
/// as `0xAARRGGBB` with full alpha, or null when no pixel is visible.
///
/// The browser downsamples the image to at most 32 px on a side (its own
/// scaler averages), then this picks a colour with a 3-bit-per-channel
/// histogram: pixels vote with their alpha times `1 + saturation`, so a
/// photo's subject beats a grey background, and the winning bucket's
/// weighted mean is returned (a real colour of the image, not a muddy
/// global average).
int? dominantColorOfRgba(Uint8List rgba) {
  final weight = Float64List(512);
  final sumR = Float64List(512);
  final sumG = Float64List(512);
  final sumB = Float64List(512);
  var any = false;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final a = rgba[i + 3];
    if (a < 32) continue;
    final r = rgba[i];
    final g = rgba[i + 1];
    final b = rgba[i + 2];
    final hi = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final lo = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final saturation = hi == 0 ? 0.0 : (hi - lo) / hi;
    final w = (a / 255) * (1 + saturation);
    final bucket = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5);
    weight[bucket] += w;
    sumR[bucket] += r * w;
    sumG[bucket] += g * w;
    sumB[bucket] += b * w;
    any = true;
  }
  if (!any) return null;
  var best = 0;
  for (var k = 1; k < 512; k++) {
    if (weight[k] > weight[best]) best = k;
  }
  final w = weight[best];
  final r = (sumR[best] / w).round();
  final g = (sumG[best] / w).round();
  final b = (sumB[best] / w).round();
  return 0xFF000000 | (r << 16) | (g << 8) | b;
}
