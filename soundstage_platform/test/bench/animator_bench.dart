@Tags(['bench'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

import 'animator_fixture.dart';

/// Budget from architecture §18: animator work per frame with 200 active
/// tracks < 2 ms.
///
///   flutter test --tags bench test/bench/animator_bench.dart
///   flutter test --platform chrome --tags bench test/bench/animator_bench.dart
///
/// Zero allocations is measured by `animator_alloc_bench.dart` (VM only).
const double _budgetMs = 2.0;

double _median(List<double> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

void main() {
  test('compiled evaluators: 200 tracks per frame', () {
    final tracks = mixedCompiledTracks();
    const frames = 2000;
    var sink = 0.0;
    void run(int offset) {
      for (var f = 0; f < frames; f++) {
        final v = sweep(f + offset, 240);
        for (var i = 0; i < tracks.length; i++) {
          final t = tracks[i];
          if (t.evaluate(v)) sink += t.out[0];
        }
      }
    }

    for (var w = 0; w < 5; w++) {
      run(w);
    }
    final perFrameMs = <double>[];
    for (var r = 0; r < 15; r++) {
      final sw = Stopwatch()..start();
      run(r * 7);
      perFrameMs.add(sw.elapsedMicroseconds / 1000 / frames);
    }
    final ms = _median(perFrameMs);
    final nsPerTrack = ms * 1e6 / tracks.length;
    // ignore: avoid_print
    print(
      'evaluators: ${tracks.length} tracks (150 numeric, 50 colour): '
      '${ms.toStringAsFixed(4)} ms/frame, ${nsPerTrack.toStringAsFixed(1)} '
      'ns/track/frame (budget $_budgetMs ms) [sink $sink]',
    );
    expect(ms, lessThan(_budgetMs));
  });

  test('animator: 200 slot tracks evaluated and pushed per frame', () {
    final (:animator, :boxes) = boundAnimator();
    expect(animator.boundTrackCount, 200);
    const frames = 2000;
    void run(int offset) {
      for (var f = 0; f < frames; f++) {
        animator.sceneScrolled(
          's',
          progress: sweep(f + offset, 240),
          visible: true,
        );
      }
    }

    for (var w = 0; w < 5; w++) {
      run(w);
    }
    final perFrameMs = <double>[];
    for (var r = 0; r < 15; r++) {
      final sw = Stopwatch()..start();
      run(r * 7);
      perFrameMs.add(sw.elapsedMicroseconds / 1000 / frames);
    }
    final ms = _median(perFrameMs);
    // ignore: avoid_print
    print(
      'animator: 200 slot tracks on 40 nodes: ${ms.toStringAsFixed(4)} '
      'ms/frame, ${(ms * 1e6 / 200).toStringAsFixed(1)} ns/track/frame '
      '(budget $_budgetMs ms)',
    );
    expect(ms, lessThan(_budgetMs));
    expect(
      boxes.first.animatedSlot(RenderStageBox.slotTranslateX).isFinite,
      isTrue,
    );
    animator.dispose();
  });
}
