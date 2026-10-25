@Tags(['bench'])
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/artboard.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/shell/editor_layout.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/editor/timeline/timeline_model.dart';
import 'package:soundstage_platform/editor/timeline/timeline_panel.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'scrub_fixture.dart';

/// The timeline driven through its UI on the 5,000-node bench scene with
/// 200 tracks, inside the docked editor (both artboards, inspector,
/// timeline open):
///
/// - **Scrub by pointer** (m2.md: ≤ 8 ms per step excluding raster): a
///   mouse drag along the ruler. Per step: the pointer move (hit test,
///   ruler → `setPlayhead`, the artboards' animators writing render
///   objects), then layout and paint recording, then the whole frame.
///   Widget rebuilds per step are counted (only the playhead readout
///   should rebuild).
/// - **Keyframe drag by pointer** (≤ 4 ms per step): a diamond dragged in
///   the lanes; per step the pointer move (snapping, the `GestureStep`
///   with `moveKeyframes`) plus re-resolving both artboards, and with the
///   frame. One undo step.
/// - **1,000 tracks of lanes scrolling** (60 fps): the lane list scrolled
///   three rows per frame; per frame build, layout and paint.
///
///   flutter test --tags bench test/bench/timeline_bench.dart
///   flutter test --tags bench --platform chrome --wasm test/bench/timeline_bench.dart
double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

double _pct(List<double> xs, double p) {
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()];
}

String _stat(List<double> xs) =>
    'median ${_pct(xs, 0.5).toStringAsFixed(2)} ms, '
    'p95 ${_pct(xs, 0.95).toStringAsFixed(2)} ms';

Future<ProviderContainer> _pumpEditor(
  WidgetTester tester,
  StageDocument doc,
) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final root = ProviderContainer();
  addTearDown(root.dispose);
  root.read(editorLayoutProvider.notifier)
    ..toggleTimeline()
    ..setTimelineHeight(320);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: root,
      child: MaterialApp(
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: Scaffold(
          body: EditorShell(document: doc, onBack: () {}, onPreview: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(TimelinePanel)));
}

/// [doc] with [n] extra opacity/motion tracks on the scroll clock, spread
/// over its nodes (so the lanes have about [n] rows plus groups).
StageDocument _withTracks(StageDocument doc, int n) {
  final scene = doc.scenes.single;
  final ids = <String>[];
  void walk(Node node) {
    if (!identical(node, scene.root)) ids.add(node.id);
    if (node is FrameNode) node.children.forEach(walk);
  }

  walk(scene.root);
  final scroll = scene.clocks.whereType<SceneScrollClock>().first.id;
  const paths = ['opacity', 'motion.translateX', 'motion.translateY'];
  return doc.copyWith(
    scenes: [
      scene.copyWith(
        tracks: [
          for (var i = 0; i < n; i++)
            Track(
              id: 'l$i',
              target: ids[(i ~/ 3 * 7) % ids.length],
              property: paths[i % 3],
              clockId: scroll,
              keyframes: [
                Keyframe(
                  id: 'a',
                  t: (i % 10) / 20,
                  value: IrValue.number(i % 3 == 0 ? 1 : 0),
                ),
                Keyframe(
                  id: 'b',
                  t: 0.5 + (i % 10) / 20,
                  value: IrValue.number(i % 3 == 0 ? 0.5 : 20),
                ),
              ],
            ),
        ],
      ),
    ],
  );
}

void main() {
  testWidgets('timeline UI: pointer scrub and keyframe drag, 5,000 nodes, '
      '200 tracks', (tester) async {
    final doc = scrubBenchScene();
    final c = await _pumpEditor(tester, doc);
    final ctl = c.read(editorControllerProvider.notifier);
    final tl = c.read(timelineControllerProvider);
    final owner = tester.binding.rootPipelineOwner;
    final ruler = find.byKey(const ValueKey<String>('timeline-ruler'));
    final r0 = tester.getTopLeft(ruler);
    final width = tester.getSize(ruler).width;

    // ---- Scrub by pointer ----------------------------------------------------
    Offset rulerAt(double f) =>
        r0 + Offset(12 + (width - 24) * f, kTimelineRulerHeight / 2);
    Future<(List<double>, List<double>, List<double>)> scrub(int steps) async {
      final move = <double>[], pipeline = <double>[], frame = <double>[];
      final g = await tester.startGesture(
        rulerAt(0),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
      );
      await tester.pump();
      for (var i = 1; i <= steps; i++) {
        final p = i % 120;
        final w = Stopwatch()..start();
        await g.moveTo(rulerAt((p <= 60 ? p : 120 - p) / 60));
        move.add(_ms(w));
        owner
          ..flushLayout()
          ..flushCompositingBits()
          ..flushPaint();
        pipeline.add(_ms(w));
        await tester.pump();
        frame.add(_ms(w));
      }
      await g.up();
      await tester.pump();
      return (move, pipeline, frame);
    }

    await scrub(60); // warm-up
    final rebuilt = <String, int>{};
    debugOnRebuildDirtyWidget = (e, _) {
      final name = e.widget.runtimeType.toString();
      if (!name.contains('ProviderScope')) {
        rebuilt[name] = (rebuilt[name] ?? 0) + 1;
      }
    };
    final builds = Artboard.debugBuildCount;
    final docBefore = c.read(editorControllerProvider).document;
    const steps = 240;
    final (move, pipeline, frame) = await scrub(steps);
    debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print(
      'timeline pointer scrub: pointer move (ruler → playhead → animators) '
      '${_stat(move)}; + layout and paint ${_stat(pipeline)}; whole frame '
      '${_stat(frame)}; rebuilds per step '
      '${{for (final e in rebuilt.entries) e.key: (e.value / steps).toStringAsFixed(2)}}; '
      'artboard builds ${Artboard.debugBuildCount - builds}',
    );
    expect(Artboard.debugBuildCount, builds);
    expect(
      identical(c.read(editorControllerProvider).document, docBefore),
      isTrue,
    );
    // Nothing but the playhead readout (and its text) rebuilds.
    expect(
      rebuilt.keys.toSet().difference({'_PlayheadReadout', 'Text'}),
      isEmpty,
    );
    expect(rebuilt['_PlayheadReadout'] ?? 0, lessThanOrEqualTo(steps + 1));

    // ---- Keyframe drag by pointer -----------------------------------------------
    // The first lane's first keyframe.
    final st = c.read(editorControllerProvider);
    final rows = buildTimelineRows(
      st.document,
      st.activeScene!,
      st.activeClockId!,
    );
    final laneIndex = rows.indexWhere((r) => r is LaneRow);
    final lane = rows[laneIndex] as LaneRow;
    final k = lane.track.keyframes[1];
    final view =
        tl.views.value[TimelineController.viewKey(
          st.activeSceneId!,
          st.activeClockId!,
        )]!;
    final lanes = tester.getTopLeft(
      find.byKey(const ValueKey<String>('timeline-lanes')),
    );
    final at =
        lanes +
        Offset(
          view.xOf(k.t),
          laneIndex * kTimelineRowHeight + kTimelineRowHeight / 2,
        );
    Future<(List<double>, List<double>)> drag(int n) async {
      final step = <double>[], withFrame = <double>[];
      final g = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryButton,
      );
      await tester.pump();
      for (var i = 1; i <= n; i++) {
        final w = Stopwatch()..start();
        await g.moveTo(at + Offset(10.0 + (i % 20) * 3, 0));
        c.read(resolvedForProvider('desktop'));
        c.read(resolvedForProvider('mobile'));
        step.add(_ms(w));
        await tester.pump();
        withFrame.add(_ms(w));
      }
      await g.up();
      await tester.pump();
      return (step, withFrame);
    }

    final depth = ctl.history.undoDepth;
    await drag(30); // warm-up
    ctl.undo();
    await tester.pump();
    final dragRebuilt = <String, int>{};
    debugOnRebuildDirtyWidget = (e, _) {
      final name = e.widget.runtimeType.toString();
      dragRebuilt[name] = (dragRebuilt[name] ?? 0) + 1;
    };
    final (step, withFrame) = await drag(120);
    debugOnRebuildDirtyWidget = null;
    expect(ctl.history.undoDepth, depth + 1);
    final top = dragRebuilt.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // ignore: avoid_print
    print(
      'keyframe drag rebuilds per step: '
      '${(dragRebuilt.values.fold(0, (a, b) => a + b) / 120).toStringAsFixed(0)} '
      '(${[for (final e in top) if (e.value >= 60) '${e.key} ${(e.value / 120).toStringAsFixed(1)}'].join(', ')})',
    );

    // ignore: avoid_print
    print(
      'timeline keyframe drag by pointer (snap + GestureStep + resolve both '
      'artboards): ${_stat(step)}; with the frame ${_stat(withFrame)}',
    );
  });

  testWidgets('timeline UI: 1,000 tracks of lanes scrolling', (tester) async {
    final doc = _withTracks(scrubBenchScene(), 1000);
    final c = await _pumpEditor(tester, doc);
    final st = c.read(editorControllerProvider);
    final rows = buildTimelineRows(
      st.document,
      st.activeScene!,
      st.activeClockId!,
    );
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey<String>('timeline-rows')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    Future<List<double>> run(int frames) async {
      final out = <double>[];
      for (var i = 0; i < frames; i++) {
        final w = Stopwatch()..start();
        final next = scroll.pixels + 3 * kTimelineRowHeight;
        scroll.jumpTo(next > scroll.maxScrollExtent ? 0 : next);
        await tester.pump();
        out.add(_ms(w));
      }
      return out;
    }

    await run(30); // warm-up
    final frames = await run(240);
    // ignore: avoid_print
    print(
      'lanes scrolling, ${rows.length} rows (1,000 tracks), 3 rows per '
      'frame: frame ${_stat(frames)} (60 fps budget 16.7 ms)',
    );
    expect(_pct(frames, 0.95), lessThan(16.7));
  });
}
