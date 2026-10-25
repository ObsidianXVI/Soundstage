import 'dart:math' as math;
import 'dart:typed_data';

/// Seconds covered by one peak bucket (m2.md "Audio lane": 1 bucket per
/// 10 ms).
const double kPeakBucketSeconds = 0.01;

/// Buckets per second ([kPeakBucketSeconds] is 1/100 s).
const int kPeaksPerSecond = 100;

/// The waveform of an audio file, reduced for drawing: the maximum absolute
/// sample of each 10 ms bucket across all channels, quantised to a byte
/// (0 = silence, 255 = full scale).
///
/// Peaks live in the asset record (IndexedDB), never in the document JSON.
/// [duration] is the decoded length in seconds; the last bucket may cover
/// less than 10 ms.
class WaveformPeaks {
  const WaveformPeaks(this.data, this.duration);

  /// One byte per [kPeakBucketSeconds].
  final Uint8List data;

  /// Seconds.
  final double duration;

  /// The number of buckets.
  int get length => data.length;

  /// Bucket [i] as 0–1.
  double amplitude(int i) => data[i] / 255;

  /// The largest amplitude (0–1) among the buckets overlapping
  /// `[from, to]` seconds; 0 outside the file. Lanes use this to reduce
  /// ten milliseconds per bucket to one pixel column at any zoom.
  double peakIn(double from, double to) {
    if (data.isEmpty || to < from) return 0;
    final a = math.max(0, (from * kPeaksPerSecond).floor());
    final b = math.min(
      data.length - 1,
      math.max(a, (to * kPeaksPerSecond).ceil() - 1),
    );
    var best = 0;
    for (var i = a; i <= b; i++) {
      if (data[i] > best) best = data[i];
    }
    return best / 255;
  }

  @override
  bool operator ==(Object other) =>
      other is WaveformPeaks &&
      other.duration == duration &&
      other.data.length == data.length &&
      _same(other.data, data);

  @override
  int get hashCode => Object.hash(duration, data.length);

  static bool _same(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The peaks of decoded PCM: [channels] hold samples in -1…1 at
/// [sampleRate] Hz (every channel the same length).
///
/// Bucket `i` covers samples `[i * rate / 100, (i + 1) * rate / 100)`,
/// computed with integer arithmetic so buckets never drift on rates that
/// are not a multiple of 100. Its value is the largest absolute sample of
/// any channel, clamped to 1 and rounded to 0–255. A non-finite sample
/// counts as silence.
WaveformPeaks computeWaveformPeaks(
  List<Float32List> channels,
  int sampleRate,
) {
  if (channels.isEmpty || sampleRate <= 0) {
    return WaveformPeaks(Uint8List(0), 0);
  }
  final total = channels.map((c) => c.length).reduce(math.min);
  final buckets = (total * kPeaksPerSecond + sampleRate - 1) ~/ sampleRate;
  final out = Uint8List(buckets);
  for (var b = 0; b < buckets; b++) {
    final start = b * sampleRate ~/ kPeaksPerSecond;
    final end = math.min(total, (b + 1) * sampleRate ~/ kPeaksPerSecond);
    var best = 0.0;
    for (final ch in channels) {
      for (var i = start; i < end; i++) {
        final v = ch[i].abs();
        if (v > best) best = v;
      }
    }
    out[b] = best.isFinite ? (math.min(best, 1.0) * 255).round() : 0;
  }
  return WaveformPeaks(out, total / sampleRate);
}
