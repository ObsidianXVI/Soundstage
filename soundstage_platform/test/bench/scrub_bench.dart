@Tags(['bench'])
library;

import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/artboard.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

import 'scrub_fixture.dart';

/// Timeline scrubbing and keyframe dragging on the 5,000-node bench scene
/// with 200 mixed tracks (m2.md budgets: ≤ 8 ms per scrub step with zero
/// widget rebuilds; ≤ 4 ms per keyframe-drag step).
///
/// - **Scrub step:** `setPlayhead` on the scene-scroll clock (150 of the
///   200 tracks run on it), then a frame. Reported: the evaluation and
///   render-object writes (the m2.md budget), then with layout and paint
///   recording, then the whole frame including compositing and raster
///   (in Chrome the test binding rasterizes synchronously; on the VM it
///   does not raster). The artboards push the playheads
///   to their animators, which write render objects directly; the frame
///   relayouts the layout-animated nodes and repaints. Widget rebuilds are
///   counted (`debugOnRebuildDirtyWidget`, minus Riverpod's own scope
///   flush, which rebuilds nothing below it) and must be 0; the document
///   must not change (no resolve).
/// - **Keyframe-drag step:** a `MoveKeyframes` inside a gesture (coalesced),
///   plus re-resolving both artboards (the M1 editor drag step measures the
///   same command + resolve span), and separately with the frame.
///
///   flutter test --tags bench test/bench/scrub_bench.dart
///   flutter test --tags bench --platform chrome --wasm test/bench/scrub_bench.dart
double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

double _pct(List<double> xs, double p) {
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()];
}

void main() {
  testWidgets('scrub and keyframe drag on a 5,000-node scene, 200 tracks', (
    tester,
  ) async {
    final doc = scrubBenchScene();
    final resolved = resolveDocument(doc);
    final count = resolved.nodeIndex.length;
    final tracks = resolved.scenes.single.tracks.length;
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [initialDocumentProvider.overrideWithValue(doc)],
        child: MaterialApp(
          builder: (c, child) =>
              SsScope(theme: SsThemeData.dark(), child: child!),
          home: const Scaffold(body: EditorCanvas()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EditorCanvas)),
    );
    final canvas = container.read(canvasControllerProvider);
    final ctl = container.read(editorControllerProvider.notifier);
    canvas.setCamera(const CanvasCamera(zoom: 0.5, panX: 20, panY: 20));
    await tester.pump();
    final sceneId = doc.scenes.single.id;
    final scroll = container.read(editorControllerProvider).activeClockId!;

    // ---- Scrub ------------------------------------------------------------
    final owner = tester.binding.rootPipelineOwner;
    final push = <double>[], pipeline = <double>[];
    Future<List<double>> scrub(int steps) async {
      final out = <double>[];
      push.clear();
      pipeline.clear();
      for (var i = 1; i <= steps; i++) {
        final p = i % 120;
        final w = Stopwatch()..start();
        ctl.setPlayhead(sceneId, scroll, (p <= 60 ? p : 120 - p) / 60);
        push.add(_ms(w));
        owner
          ..flushLayout()
          ..flushCompositingBits()
          ..flushPaint();
        pipeline.add(_ms(w));
        await tester.pump();
        out.add(_ms(w));
      }
      return out;
    }

    await scrub(60); // warm-up
    var rebuilds = 0;
    debugOnRebuildDirtyWidget = (e, _) {
      if (!e.widget.runtimeType.toString().contains('ProviderScope')) {
        rebuilds++;
      }
    };
    final builds = Artboard.debugBuildCount;
    final layouts = RenderStageBox.debugLayoutCount;
    final paints = RenderStageBox.debugPaintCount;
    final docBefore = container.read(editorControllerProvider).document;
    const steps = 240;
    final times = await scrub(steps);
    debugOnRebuildDirtyWidget = null;
    final docAfter = container.read(editorControllerProvider).document;
    // ignore: avoid_print
    print(
      'scrub ($count nodes, $tracks tracks, both artboards), per step: '
      'evaluation + render-object writes median '
      '${_pct(push, 0.5).toStringAsFixed(2)} ms, p95 '
      '${_pct(push, 0.95).toStringAsFixed(2)} ms; + layout and paint '
      'median ${_pct(pipeline, 0.5).toStringAsFixed(2)} ms, p95 '
      '${_pct(pipeline, 0.95).toStringAsFixed(2)} ms; whole frame incl. '
      'compositing/raster median ${_pct(times, 0.5).toStringAsFixed(2)} ms, '
      'p95 ${_pct(times, 0.95).toStringAsFixed(2)} ms; widget rebuilds '
      '$rebuilds, artboard builds ${Artboard.debugBuildCount - builds}, '
      'layouts/step ${((RenderStageBox.debugLayoutCount - layouts) / steps).toStringAsFixed(1)}, '
      'paints/step ${((RenderStageBox.debugPaintCount - paints) / steps).toStringAsFixed(1)}, '
      'document unchanged ${identical(docBefore, docAfter)}',
    );
    expect(rebuilds, 0);
    expect(Artboard.debugBuildCount, builds);
    expect(identical(docBefore, docAfter), isTrue);

    // ---- Keyframe drag ------------------------------------------------------
    const dragged = 'b0';
    final key = '$dragged-1';
    final start = doc.scenes.single.tracks
        .firstWhere((t) => t.id == dragged)
        .keyframes[1]
        .t;
    Future<(List<double>, List<double>)> drag(int n) async {
      final step = <double>[], frame = <double>[];
      ctl.beginGesture();
      for (var i = 1; i <= n; i++) {
        final w = Stopwatch()..start();
        ctl.execute(
          MoveKeyframes(sceneId, {
            dragged: {key: start + (i % 20) * 0.002},
          }),
        );
        container.read(resolvedForProvider('desktop'));
        container.read(resolvedForProvider('mobile'));
        step.add(_ms(w));
        await tester.pump();
        frame.add(_ms(w));
      }
      ctl.endGesture();
      return (step, frame);
    }

    await drag(30); // warm-up
    ctl.undo();
    await tester.pump();
    final (step, frame) = await drag(120);
    expect(ctl.history.undoDepth, 1);
    // ignore: avoid_print
    print(
      'keyframe drag step (MoveKeyframes + resolve both artboards): median '
      '${_pct(step, 0.5).toStringAsFixed(2)} ms, p95 '
      '${_pct(step, 0.95).toStringAsFixed(2)} ms; with the frame (animator '
      'reload of the edited track, relayout, paint): median '
      '${_pct(frame, 0.5).toStringAsFixed(2)} ms, p95 '
      '${_pct(frame, 0.95).toStringAsFixed(2)} ms',
    );
  });
}
