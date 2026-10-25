@Tags(['bench'])
@TestOn('vm')
library;

import 'dart:developer';
import 'dart:isolate' as iso;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/runtime/runtime.dart' show StageRenderMode;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'animator_fixture.dart';

/// Measures heap allocations of the per-frame animator path with the VM
/// service's allocation profile (architecture §17.1: zero allocations per
/// frame). The VM service is off in a plain `flutter test`; run:
///
///   flutter test --enable-vmservice --tags bench test/bench/animator_alloc_bench.dart
///
/// Code is warmed up first so the JIT has optimised it (unoptimised code
/// boxes doubles). The profile is then read around N and 2N frames, and
/// the per-class difference divided by N is the allocation rate per frame:
/// this cancels the constant noise of the measurement itself (decoding the
/// profile response allocates in this isolate after the reset).
const int _frames = 100000;

/// Anything allocated per frame shows up at ≥ 1 per frame. Below 0.1 is the
/// measurement's own residue (a few hundred VM-service strings over 20,000
/// frames), not the frame path.
const double _maxPerFrame = 0.1;

Future<VmService?> _connect() async {
  final info = await Service.getInfo();
  final ws = info.serverWebSocketUri;
  if (ws == null) return null;
  return vmServiceConnectUri(ws.toString());
}

Future<Map<String, int>> _counts(
  VmService s,
  String isolate,
  void Function(int frames) body,
  int frames,
) async {
  await s.getAllocationProfile(isolate, reset: true, gc: true);
  body(frames);
  final p = await s.getAllocationProfile(isolate);
  return {
    for (final m in p.members ?? const <ClassHeapStats>[])
      if ((m.instancesAccumulated ?? 0) > 0)
        m.classRef?.name ?? '?': m.instancesAccumulated!,
  };
}

/// Instances allocated per frame, per class (classes above 0.001/frame).
Future<Map<String, double>> _perFrame(
  VmService s,
  String isolate,
  void Function(int frames) body,
) async {
  final base = await _counts(s, isolate, body, _frames);
  final twice = await _counts(s, isolate, body, 2 * _frames);
  final out = <String, double>{};
  for (final MapEntry(:key, :value) in twice.entries) {
    final rate = (value - (base[key] ?? 0)) / _frames;
    if (rate > 0.001) out[key] = rate;
  }
  return out;
}

double _report(String what, Map<String, double> rates) {
  final total = rates.values.fold(0.0, (a, b) => a + b);
  final top =
      (rates.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .take(6)
          .map((e) => '${e.key} ${e.value.toStringAsFixed(4)}')
          .join(', ');
  // ignore: avoid_print
  print(
    '$what: ${total.toStringAsFixed(4)} allocations per frame '
    '(differential over $_frames vs ${2 * _frames} frames)'
    '${top.isEmpty ? '' : ': $top'}',
  );
  return total;
}

/// The clock values of one back-and-forth sweep, precomputed so the
/// harness itself does not box a double per frame.
Float64List _sweepValues() =>
    Float64List.fromList([for (var f = 0; f < 480; f++) sweep(f, 240)]);

void main() {
  late VmService? service;
  late String isolate;

  setUpAll(() async {
    service = await _connect();
    isolate = Service.getIsolateId(iso.Isolate.current)!;
  });
  tearDownAll(() async => service?.dispose());

  test(
    'compiled evaluators (numeric and colour) allocate nothing per frame',
    () async {
      final s = service;
      if (s == null) {
        markTestSkipped('run with --enable-vmservice to measure allocations');
        return;
      }
      final tracks = mixedCompiledTracks();
      final clock = _sweepValues();
      void run(int frames) {
        for (var f = 0; f < frames; f++) {
          final v = clock[f % clock.length];
          for (var i = 0; i < tracks.length; i++) {
            tracks[i].evaluate(v);
          }
        }
      }

      run(10 * _frames); // warm up: let the optimising JIT settle
      final rates = await _perFrame(s, isolate, run);
      final total = _report('evaluators, ${tracks.length} tracks', rates);
      expect(total, lessThan(_maxPerFrame), reason: '$rates');
    },
  );

  test(
    'animator push of 200 slot tracks allocates within the animator budget',
    () async {
      final s = service;
      if (s == null) {
        markTestSkipped('run with --enable-vmservice to measure allocations');
        return;
      }
      final (:animator, boxes: _) = boundAnimator();
      final clock = _sweepValues();
      void run(int frames) {
        for (var f = 0; f < frames; f++) {
          animator.sceneScrolled(
            's',
            progress: clock[f % clock.length],
            visible: true,
          );
        }
      }

      run(10 * _frames); // warm up: let the optimising JIT settle
      final rates = await _perFrame(s, isolate, run);
      final total = _report('animator, 200 slot tracks', rates);
      // DECISIONS 26/10/26 (T2.0 open points): relaxed from "nothing" to
      // the T0.6b budget of up to 4 boxed doubles per frame (VM JIT
      // dependent).
      expect(total, lessThanOrEqualTo(4), reason: '$rates');
      animator.dispose();
    },
  );

  test('animator push of 200 mixed paint/opacity/motion tracks allocates '
      'nothing per frame', () async {
    final s = service;
    if (s == null) {
      markTestSkipped('run with --enable-vmservice to measure allocations');
      return;
    }
    final (:animator, :boxes) = boundMixedAnimator();
    expect(animator.boundTrackCount, 200);
    final clock = _sweepValues();
    void run(int frames) {
      for (var f = 0; f < frames; f++) {
        animator.sceneScrolled(
          's',
          progress: clock[f % clock.length],
          visible: true,
        );
      }
    }

    run(10 * _frames); // warm up: let the optimising JIT settle
    final rates = await _perFrame(s, isolate, run);
    final total = _report('animator, 200 mixed tracks', rates);
    expect(total, lessThan(_maxPerFrame), reason: '$rates');
    for (final b in boxes) {
      expect(identical(b.node, b.baseNode), isTrue);
    }
    animator.dispose();
  });

  test('editor scrub of 200 mixed tracks (edit mode, playheads) allocates '
      'within the animator budget', () async {
    final s = service;
    if (s == null) {
      markTestSkipped('run with --enable-vmservice to measure allocations');
      return;
    }
    final (:animator, boxes: _) = boundMixedAnimator(
      mode: StageRenderMode.edit,
    );
    expect(animator.boundTrackCount, 200);
    // The editor hands the animator one playhead map per scrub step; these
    // are built ahead, as the editor state builds them outside the
    // animator.
    final steps = [
      for (final v in _sweepValues()) <String, double>{'c': v},
    ];
    void run(int frames) {
      for (var f = 0; f < frames; f++) {
        animator.clockOverrides = steps[f % steps.length];
      }
    }

    run(10 * _frames); // warm up: let the optimising JIT settle
    final rates = await _perFrame(s, isolate, run);
    final total = _report('editor scrub, 200 mixed tracks', rates);
    // The mixed push budget (DECISIONS 23/10/26 T0.6b): up to 4 boxed
    // doubles per frame on the VM JIT.
    expect(total, lessThanOrEqualTo(4), reason: '$rates');
    animator.dispose();
  });
}
