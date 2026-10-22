// Generates the T0.8 spike demo's procedural images in assets/demo/images/.
//
//   dart run tool/gen_spike_images.dart
//
// Pure Dart (dart:io's zlib), no packages. Files:
//   spike_sky.png         1600x1000 RGB   dusk sky, low sun at (0.62, 0.40), stars
//   spike_ridge_far.png   1600x700  RGBA  hazy far ridge, transparent above
//   spike_ridge_mid.png   1600x700  RGBA  middle ridge
//   spike_ridge_near.png  1600x700  RGBA  near ridge, darkest
//   spike_cove.png        2400x1200 RGB   panorama, a lighthouse on an island;
//                                         the lamp is at (0.70, 0.41), the focal
//                                         point of the zoom scene
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

typedef Rgba = (double, double, double, double);

void main() {
  final out = Directory('assets/demo/images')..createSync(recursive: true);
  _write('${out.path}/spike_sky.png', 1600, 1000, _sky, alpha: false);
  _write(
    '${out.path}/spike_ridge_far.png',
    1600,
    700,
    (u, v, a) => _ridgeLayer(u, v, 1.7, 0.30, 0.05, 0xA0709A, 0x7C5486, 0.85),
    alpha: true,
  );
  _write(
    '${out.path}/spike_ridge_mid.png',
    1600,
    700,
    (u, v, a) => _ridgeLayer(u, v, 4.2, 0.26, 0.07, 0x6A4570, 0x432A58, 1),
    alpha: true,
  );
  _write(
    '${out.path}/spike_ridge_near.png',
    1600,
    700,
    (u, v, a) => _ridgeLayer(u, v, 6.9, 0.22, 0.08, 0x3A2548, 0x1A1024, 1),
    alpha: true,
  );
  _write('${out.path}/spike_cove.png', 2400, 1200, _cove, alpha: false);
}

// ---- Helpers ---------------------------------------------------------------------

typedef Rgb = (double, double, double);

Rgb _mix(Rgb a, Rgb b, double t) {
  final k = t.clamp(0.0, 1.0);
  return (
    a.$1 + (b.$1 - a.$1) * k,
    a.$2 + (b.$2 - a.$2) * k,
    a.$3 + (b.$3 - a.$3) * k,
  );
}

Rgb _hex(int v) =>
    (((v >> 16) & 255) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255);

double _smooth(double e0, double e1, double x) {
  final t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

double _hash(int x, int y) {
  var h = x * 374761393 + y * 668265263;
  h = (h ^ (h >> 13)) * 1274126177;
  h = h ^ (h >> 16);
  return (h & 0xFFFFFF) / 0xFFFFFF;
}

double _ridge(double u, double seed, double base, double amp) =>
    base +
    amp *
        (0.55 * math.sin(u * 5.0 + seed) +
            0.3 * math.sin(u * 13.0 + seed * 2.3) +
            0.15 * math.sin(u * 31.0 + seed * 5.1));

// ---- Images ----------------------------------------------------------------------

Rgba _sky(double u, double v, double aspect) {
  var c = _mix(
    _mix(_hex(0x141A3A), _hex(0x5A3E6B), _smooth(0, 0.35, v)),
    _hex(0xF4A55F),
    math.pow(_smooth(0.25, 0.85, v), 1.5).toDouble(),
  );
  final dx = (u - 0.62) * aspect, dy = v - 0.40;
  final d = math.sqrt(dx * dx + dy * dy);
  c = _mix(c, _hex(0xFFD9A0), 0.6 * (1 - _smooth(0.0, 0.42, d)));
  c = _mix(c, _hex(0xFFF1D6), 1 - _smooth(0.064, 0.068, d));
  // Stars in the upper sky, fading towards the horizon.
  final sx = (u * 1600).floor(), sy = (v * 1000).floor();
  final s = _hash(sx, sy);
  if (s > 0.9975 && v < 0.45) {
    c = _mix(c, _hex(0xFFFFFF), (1 - v / 0.45) * (0.5 + 0.5 * _hash(sy, sx)));
  }
  return (c.$1, c.$2, c.$3, 1);
}

/// A ridge silhouette: transparent above the edge, [top]→[bottom] colour
/// below it, with a 1.5 px soft edge. The vertical gradient fades the haze.
Rgba _ridgeLayer(
  double u,
  double v,
  double seed,
  double base,
  double amp,
  int top,
  int bottom,
  double maxAlpha,
) {
  final edge = _ridge(u, seed, base, amp);
  final a = _smooth(edge - 0.002, edge + 0.002, v) * maxAlpha;
  final c = _mix(_hex(top), _hex(bottom), (v - edge) / 0.5);
  return (c.$1, c.$2, c.$3, a);
}

Rgba _cove(double u, double v, double aspect) {
  const w = 2400.0, h = 1200.0;
  final x = u * w, y = v * h;
  const horizon = 0.62;
  Rgb c;
  if (v < horizon) {
    c = _mix(
      _mix(_hex(0x18204A), _hex(0x6A4A78), _smooth(0, 0.35, v)),
      _hex(0xF6A860),
      math.pow(_smooth(0.3, horizon, v), 1.4).toDouble(),
    );
    // The low sun just above the horizon, left of centre.
    final dx = (u - 0.24) * aspect, dy = v - 0.575;
    final d = math.sqrt(dx * dx + dy * dy);
    c = _mix(c, _hex(0xFFD9A0), 0.6 * (1 - _smooth(0, 0.45, d)));
    c = _mix(c, _hex(0xFFF1D6), 1 - _smooth(0.05, 0.054, d));
    final sx = (x).floor(), sy = (y).floor();
    if (_hash(sx, sy) > 0.9985 && v < 0.35) {
      c = _mix(c, _hex(0xFFFFFF), 1 - v / 0.35);
    }
  } else {
    final t = (v - horizon) / (1 - horizon);
    c = _mix(_hex(0xE9A36B), _hex(0x14274A), math.pow(t, 0.55).toDouble());
    // Waves and the sun's glitter column below the sun.
    final wave = math.sin(x * 0.018 + math.sin(y * 0.03 + x * 0.004) * 2 + y * 0.11 * (1 + t));
    final col = 1 - _smooth(0, 0.22 + t * 0.2, (u - 0.24).abs());
    c = _mix(c, _hex(0xFFE2B0), col * _smooth(0.3, 1.0, wave) * (1 - t * .5) * 0.7);
    c = _mix(c, _hex(0x0B1830), 0.1 * _smooth(0.3, 1.0, -wave));
  }

  // The island and lighthouse, from the lamp (1680, 495) down.
  const cx = 1680.0, baseY = 840.0;
  final dxr = (x - cx).abs();
  // Island: a mound whose top rises from the waterline.
  final ex = (x - cx) / 330, ey = (y - baseY) / 64;
  final ed = math.sqrt(ex * ex + ey * ey);
  if (ed < 1.0 && y > baseY - 40) {
    final k = _smooth(1.0, 0.985, ed);
    final rock = _mix(_hex(0x3B2A3C), _hex(0x1B1222), (y - (baseY - 40)) / 100);
    c = _mix(c, rock, k);
  }
  // Tower: a tapered column on the island.
  const towerTop = 520.0;
  if (y >= towerTop && y <= baseY) {
    final t = (y - towerTop) / (baseY - towerTop);
    final half = 20 + 16 * t;
    final edge = _smooth(half + 1, half - 1, dxr);
    if (edge > 0) {
      final band = (((y - towerTop) / 46).floor() % 2 == 0)
          ? _hex(0xE9DCCB)
          : _hex(0xB04A42);
      // Lit from the left (the sun), shaded on the right.
      final shade = 0.62 + 0.38 * _smooth(half, -half, x - cx);
      c = _mix(c, (band.$1 * shade, band.$2 * shade, band.$3 * shade), edge);
    }
  }
  // Gallery, lamp room and roof.
  if (y >= 506 && y < 522 && dxr < 34) c = _mix(c, _hex(0x2A1D30), 0.95);
  if (y >= 470 && y < 506 && dxr < 17) {
    final lit = 1 - _smooth(0, 17, dxr) * 0.2;
    c = _mix(c, _hex(0xFFF3C8), lit);
  }
  if (y >= 446 && y < 470) {
    final half = 22 * (y - 446) / 24;
    if (dxr < half) c = _hex(0x2A1D30);
  }
  // Lamp glow and a faint beam to the left, over everything.
  final lampDx = x - cx, lampDy = y - 490;
  final ld = math.sqrt(lampDx * lampDx + lampDy * lampDy);
  c = _mix(c, _hex(0xFFE9B0), 0.8 * (1 - _smooth(0, 150, ld)) * 0.7);
  final beam =
      (lampDx < 0 && lampDx > -1500)
      ? (1 - _smooth(0, 90 + (-lampDx) * 0.14, lampDy.abs())) *
            (1 - _smooth(0, 1500, -lampDx)) *
            0.16
      : 0.0;
  c = _mix(c, _hex(0xFFE9B0), beam);
  return (c.$1, c.$2, c.$3, 1);
}

// ---- PNG encoding ----------------------------------------------------------------

void _write(
  String path,
  int w,
  int h,
  Rgba Function(double u, double v, double aspect) shade, {
  required bool alpha,
}) {
  final bpp = alpha ? 4 : 3;
  final raw = BytesBuilder();
  final row = Uint8List(w * bpp);
  final prev = Uint8List(w * bpp);
  final filtered = Uint8List(w * bpp);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (r, g, b, a) = shade(x / (w - 1), y / (h - 1), w / h);
      row[x * bpp] = (r.clamp(0.0, 1.0) * 255).round();
      row[x * bpp + 1] = (g.clamp(0.0, 1.0) * 255).round();
      row[x * bpp + 2] = (b.clamp(0.0, 1.0) * 255).round();
      if (alpha) row[x * bpp + 3] = (a.clamp(0.0, 1.0) * 255).round();
    }
    for (var i = 0; i < row.length; i++) {
      filtered[i] = (row[i] - prev[i]) & 0xFF;
    }
    raw
      ..addByte(2)
      ..add(filtered);
    prev.setAll(0, row);
  }
  final png = BytesBuilder()
    ..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(
      _chunk(
        'IHDR',
        (ByteData(13)
              ..setUint32(0, w)
              ..setUint32(4, h)
              ..setUint8(8, 8)
              ..setUint8(9, alpha ? 6 : 2))
            .buffer
            .asUint8List(),
      ),
    )
    ..add(_chunk('IDAT', ZLibCodec(level: 9).encode(raw.takeBytes())))
    ..add(_chunk('IEND', const []));
  File(path).writeAsBytesSync(png.takeBytes());
  stdout.writeln('wrote $path');
}

List<int> _chunk(String type, List<int> data) {
  final typeBytes = type.codeUnits;
  final len = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32([...typeBytes, ...data]));
  return [
    ...len.buffer.asUint8List(),
    ...typeBytes,
    ...data,
    ...crc.buffer.asUint8List(),
  ];
}

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
