@Tags(['bench'])
library;

import 'dart:convert';

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

import 'bench_document.dart';

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

const List<String> _slotPaths = [
  'opacity',
  'motion.translateX',
  'motion.translateY',
  'motion.rotate',
  'motion.scaleX',
];

/// The 5,000-node bench scene (solid fills; see `canvas_drag_bench.dart`)
/// with a timeline clock and 200 mixed tracks: 100 slot (opacity,
/// motion.*), 50 fill colour, 25 corner radius, 25 layout (`x` of the free
/// layer's absolute nodes, else `width`). 150 run on the scroll clock, 50 on
/// the timeline.
StageDocument _scene() {
  final doc = documentOfNodes(5000, scenes: 1, freeLayer: true);
  Object? solid(Object? j) {
    if (j is Map<String, dynamic>) {
      if (j['type'] == 'image' && j.containsKey('assetId')) {
        return {
          'type': 'solid',
          'id': j['id'],
          'color': {'r': 0.8, 'g': 0.8, 'b': 0.8, 'a': 1.0},
        };
      }
      return {for (final e in j.entries) e.key: solid(e.value)};
    }
    if (j is List) return [for (final e in j) solid(e)];
    return j;
  }

  final plain = StageDocument.fromJson(
    solid(jsonDecode(jsonEncode(doc.toJson()))) as Map<String, dynamic>,
  );
  final scene = plain.scenes.single;
  final scroll = scene.clocks.whereType<SceneScrollClock>().first.id;

  // Authored scene-level nodes (no instances' insides), by role.
  final any = <Node>[];
  final filled = <(Node, String)>[];
  final cornered = <Node>[];
  final free = <Node>[];
  void walk(Node n, {required bool inFree}) {
    if (!identical(n, scene.root)) any.add(n);
    final app = switch (n) {
      FrameNode(:final appearance) ||
      ShapeNode(:final appearance) => appearance,
      _ => null,
    };
    if (app != null) {
      cornered.add(n);
      final solidFill = app.fills.whereType<SolidPaint>().firstOrNull;
      if (solidFill != null) filled.add((n, solidFill.id));
    }
    if (inFree && n is ShapeNode) free.add(n);
    if (n is FrameNode) {
      final isFree = n.id.startsWith('free');
      for (final c in n.children) {
        walk(c, inFree: inFree || isFree);
      }
    }
  }

  walk(scene.root, inFree: false);
  Track track(int i, String target, String path, List<IrValue> values) => Track(
    id: 'b$i',
    target: target,
    property: path,
    clockId: i % 4 == 3 ? 'tl' : scroll,
    keyframes: [
      for (final (k, v) in values.indexed)
        Keyframe(
          id: 'b$i-$k',
          t: i % 4 == 3 ? k * 2.0 : k / (values.length - 1),
          value: v,
          easing: k.isEven
              ? const Easing.preset(EasingPreset.easeInOut)
              : const Easing.cubicBezier(0.2, 0.8, 0.3, 1.2),
        ),
    ],
  );
  IrValue n(double v) => IrValue.number(v);
  final tracks = <Track>[
    for (var i = 0; i < 100; i++)
      track(i, any[(i * 37) % any.length].id, _slotPaths[i % 5], [
        for (var k = 0; k < 4; k++)
          n(
            _slotPaths[i % 5] == 'opacity'
                ? (k.isEven ? 0.3 : 1)
                : _slotPaths[i % 5] == 'motion.scaleX'
                ? 1 + k * 0.1
                : k * 12.0,
          ),
      ]),
    for (var i = 0; i < 50; i++)
      track(
        100 + i,
        filled[(i * 53) % filled.length].$1.id,
        'fills.${filled[(i * 53) % filled.length].$2}.color',
        [
          for (var k = 0; k < 3; k++)
            IrValue.color(StageColor(r: k / 2, g: (i % 5) / 5, b: 1 - k / 2)),
        ],
      ),
    for (var i = 0; i < 25; i++)
      track(150 + i, cornered[(i * 71) % cornered.length].id, 'cornerRadius', [
        for (var k = 0; k < 3; k++)
          IrValue.cornerRadius(CornerRadius.uniform(k * 6.0)),
      ]),
    for (var i = 0; i < 25; i++)
      free.length > i
          ? track(175 + i, free[i].id, 'x', [
              for (var k = 0; k < 3; k++) n(free[i].common.x + k * 30),
            ])
          : track(175 + i, any[(i * 91) % any.length].id, 'opacity', [
              n(1),
              n(0.5),
            ]),
  ];
  return plain.copyWith(
    scenes: [
      scene.copyWith(
        clocks: [
          ...scene.clocks,
          const Clock.timeline(id: 'tl', duration: 6),
        ],
        tracks: tracks,
      ),
    ],
  );
}

void main() {
  testWidgets('scrub and keyframe drag on a 5,000-node scene, 200 tracks', (
    tester,
  ) async {
    final doc = _scene();
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
