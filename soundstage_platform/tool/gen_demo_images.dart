// Generates the procedural demo images in assets/demo/images/.
//
// Run from soundstage_platform/: `dart run tool/gen_demo_images.dart`.
// Pure Dart (dart:io's zlib); no third-party packages.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

typedef Rgb = (double, double, double);

void main() {
  final out = Directory('assets/demo/images')..createSync(recursive: true);
  _write('${out.path}/hero_dusk.png', 1600, 1000, _dusk);
  _write('${out.path}/card_forest.png', 800, 500, _forest);
  _write('${out.path}/card_sea.png', 800, 500, _sea);
  _write('${out.path}/card_dunes.png', 800, 500, _dunes);
}

// ---- Scenes (u, v in 0–1) --------------------------------------------------------

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

double _ridge(double u, double seed, double base, double amp) =>
    base +
    amp *
        (0.55 * math.sin(u * 7.0 + seed) +
            0.3 * math.sin(u * 17.0 + seed * 2.3) +
            0.15 * math.sin(u * 41.0 + seed * 5.1));

/// Dusk over layered mountains, the sun at (0.68, 0.42): the focal point.
Rgb _dusk(double u, double v, double aspect) {
  var c = v < 0.62
      ? _mix(_hex(0x1B1F3B), _hex(0xF0A35E), math.pow(v / 0.62, 1.6).toDouble())
      : _hex(0xF0A35E);
  final dx = (u - 0.68) * aspect;
  final dy = v - 0.42;
  final d = math.sqrt(dx * dx + dy * dy);
  c = _mix(c, _hex(0xFFE7B3), 0.55 * (1 - _smooth(0.0, 0.35, d)));
  c = _mix(c, _hex(0xFFF4DD), 1 - _smooth(0.068, 0.072, d));
  final layers = [
    (0.58, 0.06, 1.0, 0x8C5A6B),
    (0.66, 0.07, 2.7, 0x5E3A55),
    (0.75, 0.06, 4.1, 0x3A2440),
    (0.86, 0.05, 6.3, 0x1E1328),
  ];
  for (final (base, amp, seed, col) in layers) {
    final edge = _ridge(u, seed, base, amp);
    c = _mix(c, _hex(col), _smooth(edge - 0.002, edge + 0.002, v));
  }
  return c;
}

Rgb _forest(double u, double v, double aspect) {
  var c = _mix(_hex(0xE4EFD9), _hex(0x6E9A6A), v);
  // Three rows of pines, far to near, each a triangle on a trunk.
  for (final (row, base, height, col) in [
    (0, 0.62, 0.38, 0x7FA578),
    (1, 0.80, 0.50, 0x3F6B45),
    (2, 1.02, 0.62, 0x1F3D26),
  ]) {
    for (var i = 0; i < 9; i++) {
      final x = (i + 0.5 + 0.35 * math.sin(i * 2.1 + row)) / 9;
      final h = height * (0.8 + 0.2 * math.sin(i * 1.7 + row * 3));
      final top = base - h;
      final half = (v - top) * 0.32 / aspect;
      final inCrown = v > top && v < base - 0.05 && (u - x).abs() < half;
      final inTrunk = v >= base - 0.06 && v < base && (u - x).abs() < 0.008;
      if (inCrown || inTrunk) c = _hex(col);
    }
  }
  return c;
}

Rgb _sea(double u, double v, double aspect) {
  if (v < 0.45) return _mix(_hex(0xBFD9EA), _hex(0x88B6D3), v / 0.45);
  final c = _mix(_hex(0x3D7EA6), _hex(0x123B5C), (v - 0.45) / 0.55);
  final wave = math.sin(u * 40 + math.sin(v * 30) * 2 + v * 90);
  final crest = _smooth(0.92, 0.98, wave) * (v - 0.45) * 1.4;
  return _mix(c, _hex(0xE8F3FA), crest);
}

Rgb _dunes(double u, double v, double aspect) {
  var c = _mix(_hex(0xF6D8A8), _hex(0xF2B880), v * 0.8);
  for (final (base, amp, seed, col) in [
    (0.45, 0.08, 1.3, 0xE29A5B),
    (0.62, 0.07, 3.9, 0xC97B44),
    (0.8, 0.05, 5.5, 0xA45E33),
  ]) {
    final edge =
        base +
        amp * math.sin(u * 5 + seed) +
        amp * 0.3 * math.sin(u * 13 + seed);
    c = _mix(c, _hex(col), _smooth(edge - 0.003, edge + 0.003, v));
  }
  return c;
}

// ---- PNG encoding ----------------------------------------------------------------

void _write(
  String path,
  int w,
  int h,
  Rgb Function(double u, double v, double aspect) shade,
) {
  final raw = BytesBuilder();
  final row = Uint8List(w * 3);
  final prev = Uint8List(w * 3);
  final filtered = Uint8List(w * 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final (r, g, b) = shade(x / (w - 1), y / (h - 1), w / h);
      row[x * 3] = (r.clamp(0.0, 1.0) * 255).round();
      row[x * 3 + 1] = (g.clamp(0.0, 1.0) * 255).round();
      row[x * 3 + 2] = (b.clamp(0.0, 1.0) * 255).round();
    }
    // Filter 2 (Up): smooth gradients compress well.
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
              ..setUint8(9, 2))
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
