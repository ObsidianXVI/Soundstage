// Generates assets/demo/audio/lights_go_low.wav, the T0.7 sound demo clip,
// procedurally from the hand-written lyrics in lights_go_low.lrc: one note
// per timed word (syllable), so the clip and the lyrics are in sync by
// construction. Original work, dedicated to the public domain (CC0).
//
//   dart run tool/gen_sound_audio.dart

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:soundstage_platform/ir/ir.dart';

const _rate = 22050;
const _length = 16.0; // seconds

void main() {
  final lrc = File('assets/demo/audio/lights_go_low.lrc').readAsStringSync();
  final parsed = parseLrc(lrc);
  if (parsed.diagnostics.isNotEmpty) {
    stderr.writeln(parsed.diagnostics.join('\n'));
    exit(1);
  }
  final n = (_rate * _length).round();
  final buf = Float64List(n);

  // A pentatonic melody (A minor pentatonic), one note per word.
  const scale = [57, 60, 62, 64, 67, 69, 72, 74, 76];
  const contour = [
    [4, 3, 2, 3, 4, 5, 4],
    [5, 6, 7, 6, 5, 4, 3, 4],
    [4, 3, 2, 3, 4, 5, 4],
    [5, 6, 7, 8, 7, 6, 5, 4],
  ];
  double hz(int midi) => 440 * math.pow(2, (midi - 69) / 12).toDouble();

  void note(double start, double end, double freq, double amp) {
    final s0 = (start * _rate).round();
    final s1 = math.min(n, (end * _rate).round());
    final len = (s1 - s0) / _rate;
    for (var i = s0; i < s1; i++) {
      final t = (i - s0) / _rate;
      final attack = math.min(1.0, t / 0.015);
      final release = math.min(1.0, (len - t) / 0.06);
      final env = attack * release * math.exp(-t * 2.2);
      final ph = 2 * math.pi * freq * t;
      buf[i] +=
          amp *
          env *
          (math.sin(ph) + 0.35 * math.sin(2 * ph) + 0.12 * math.sin(3 * ph));
    }
  }

  final lines = parsed.doc.lines;
  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    final lineEnd = lyricLineEnd(parsed.doc, li);
    final melody = contour[li % contour.length];
    for (var wi = 0; wi < line.words.length; wi++) {
      final w = line.words[wi];
      final end = lyricWordEnd(line, wi, lineEnd);
      final degree = melody[wi % melody.length];
      note(w.start, end, hz(scale[degree]), 0.22);
    }
    // A soft bass note under each line (root, then the fourth).
    note(line.start, lineEnd, hz(li.isEven ? 45 : 50), 0.16);
  }
  // A closing chord.
  for (final m in [57, 64, 69]) {
    note(13.5, 15.8, hz(m), 0.12);
  }

  var peak = 0.0;
  for (final v in buf) {
    peak = math.max(peak, v.abs());
  }
  final gain = peak > 0 ? 0.85 / peak : 1;
  final pcm = ByteData(44 + n * 2);
  void ascii(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      pcm.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  pcm.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  pcm
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, _rate, Endian.little)
    ..setUint32(28, _rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  pcm.setUint32(40, n * 2, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (buf[i] * gain * 32767).round().clamp(-32768, 32767);
    pcm.setInt16(44 + i * 2, v, Endian.little);
  }
  File(
    'assets/demo/audio/lights_go_low.wav',
  ).writeAsBytesSync(pcm.buffer.asUint8List());
  stdout.writeln('wrote ${n * 2 + 44} bytes');
}
