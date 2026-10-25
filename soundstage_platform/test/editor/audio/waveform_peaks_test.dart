import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/audio/waveform_peaks.dart';

Float32List _pcm(int n, double Function(int) f) =>
    Float32List.fromList([for (var i = 0; i < n; i++) f(i)]);

void main() {
  group('computeWaveformPeaks', () {
    test('one bucket per 10 ms; silence is 0', () {
      final p = computeWaveformPeaks([_pcm(1000, (_) => 0)], 1000);
      // 1 s at 1 kHz = 100 buckets of 10 samples.
      expect(p.length, 100);
      expect(p.data.every((v) => v == 0), isTrue);
      expect(p.duration, 1.0);
    });

    test('takes the max absolute sample of each bucket', () {
      // 10 samples per bucket at 1 kHz. Bucket 0 peaks at -0.5 (index 3),
      // bucket 1 at 1.0 (index 19), bucket 2 is flat 0.2.
      final pcm = _pcm(30, (i) {
        if (i == 3) return -0.5;
        if (i == 19) return 1;
        if (i >= 20) return 0.2;
        return 0.1;
      });
      final p = computeWaveformPeaks([pcm], 1000);
      expect(p.length, 3);
      expect(p.data[0], (0.5 * 255).round());
      expect(p.data[1], 255);
      expect(p.data[2], (0.2 * 255).round());
    });

    test('combines channels by max', () {
      final l = _pcm(20, (i) => i == 2 ? 0.25 : 0);
      final r = _pcm(20, (i) => i == 15 ? -0.75 : 0.5 * (i == 3 ? 1 : 0));
      final p = computeWaveformPeaks([l, r], 1000);
      expect(p.data[0], (0.5 * 255).round());
      expect(p.data[1], (0.75 * 255).round());
    });

    test('clamps over-full-scale samples and ignores non-finite ones', () {
      final p = computeWaveformPeaks([
        _pcm(20, (i) => i == 0 ? 3 : (i == 10 ? double.nan : 0.1)),
      ], 1000);
      expect(p.data[0], 255);
      expect(p.data[1], (0.1 * 255).round());
    });

    test('a rate that is not a multiple of 100 does not drift', () {
      // 44.1 kHz: 441 samples per bucket exactly; a sine of 1 s.
      final pcm = _pcm(
        44100,
        (i) => 0.8 * math.sin(2 * math.pi * 440 * i / 44100),
      );
      final p = computeWaveformPeaks([pcm], 44100);
      expect(p.length, 100);
      expect(p.duration, closeTo(1, 1e-9));
      for (final v in p.data) {
        expect(v, closeTo(0.8 * 255, 6));
      }
      // 22.05 kHz is 220.5 samples per bucket: the total still covers the
      // whole signal with 100 buckets.
      final q = computeWaveformPeaks([_pcm(22050, (_) => 0.5)], 22050);
      expect(q.length, 100);
      expect(q.data.every((v) => v == (0.5 * 255).round()), isTrue);
    });

    test('a short tail gets its own bucket', () {
      final p = computeWaveformPeaks([_pcm(25, (i) => i == 24 ? 1 : 0)], 1000);
      expect(p.length, 3);
      expect(p.data, [0, 0, 255]);
      expect(p.duration, 0.025);
    });

    test('empty input gives empty peaks', () {
      expect(computeWaveformPeaks(const [], 44100).length, 0);
      expect(computeWaveformPeaks([Float32List(0)], 44100).length, 0);
    });
  });

  group('WaveformPeaks.peakIn', () {
    final p = WaveformPeaks(Uint8List.fromList([0, 51, 255, 102, 0]), 0.05);

    test('reduces a time range to its largest bucket', () {
      expect(p.peakIn(0, 0.01), 0);
      expect(p.peakIn(0.01, 0.02), closeTo(0.2, 1e-9));
      expect(p.peakIn(0, 0.05), 1);
      expect(p.peakIn(0.03, 0.05), closeTo(0.4, 1e-9));
    });

    test('is 0 outside the file', () {
      expect(p.peakIn(1, 2), 0);
      expect(p.peakIn(0.04, 0.03), 0);
    });
  });
}
