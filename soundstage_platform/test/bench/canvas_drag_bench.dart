@Tags(['bench'])
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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

/// Canvas drag on a 5,000-node scene (architecture §18 "Editor drag on a
/// 5,000-node document: 60 fps"; T1.4/T1.5): a real pointer drag through
/// `CanvasInteraction` of an absolute node, each move followed by a frame
/// (resolve both artboards, rebuild, relayout, overlay paint). Reports the
/// per-move cost split into the interaction (hit test, snapping, command)
/// and the frame.
///
///   flutter test --tags bench test/bench/canvas_drag_bench.dart
///
/// The widget test binding runs on the VM in debug mode, so the numbers are
/// an upper bound for a release build; the budget is checked in Chrome with
/// a performance trace (see `_dev/test_status.md`).
double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

double _pct(List<double> xs, double p) {
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()];
}

/// The 5,000-node bench story as one scene, its free layer first so it
/// sits at the top of the artboard.
StageDocument _scene5k() {
  final doc = documentOfNodes(5000, scenes: 1, freeLayer: true);
  final s = doc.scenes.single;
  final kids = [...s.root.children];
  final free = kids.removeLast();
  final moved = doc.copyWith(
    scenes: [
      s.copyWith(root: s.root.copyWith(children: [free, ...kids])),
    ],
  );
  // The bench story's image fills point at an asset the test bundle lacks;
  // solid fills keep the frame cost about layout and paint, not failed
  // loads.
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

  return StageDocument.fromJson(
    solid(jsonDecode(jsonEncode(moved.toJson()))) as Map<String, dynamic>,
  );
}

void main() {
  testWidgets('drag a node in a 5,000-node scene', (tester) async {
    final doc = _scene5k();
    final count = resolveDocument(doc).nodeIndex.length;
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
    const target = 'free0_3';
    ctl.select({target});
    await tester.pump();
    final r = canvas.overlay.worldRectFor(target, 'desktop')!;
    final start = canvas.camera.value.toScreen(r.center);

    Future<List<(double, double)>> drag(int steps) async {
      final out = <(double, double)>[];
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.down(start);
      await tester.pump();
      for (var i = 1; i <= steps; i++) {
        final w = Stopwatch()..start();
        await g.moveTo(start + Offset(i * 1.7, i * 0.6));
        final input = _ms(w);
        await tester.pump();
        out.add((input, _ms(w)));
      }
      await g.up();
      await tester.pump();
      return out;
    }

    await drag(30); // warm-up
    ctl.undo();
    await tester.pump();
    final times = await drag(120);
    final input = [for (final t in times) t.$1];
    final total = [for (final t in times) t.$2];
    // ignore: avoid_print
    print(
      'canvas drag ($count nodes, one scene, both artboards): per move '
      'median ${_pct(total, 0.5).toStringAsFixed(2)} ms, p95 '
      '${_pct(total, 0.95).toStringAsFixed(2)} ms; of which pointer handling '
      '(hit test, snapping, command, resolve) median '
      '${_pct(input, 0.5).toStringAsFixed(2)} ms, p95 '
      '${_pct(input, 0.95).toStringAsFixed(2)} ms (VM debug)',
    );
    // The same edits without the pointer: the canvas frame alone.
    final direct = <double>[];
    final l0 = RenderStageBox.debugLayoutCount,
        p0 = RenderStageBox.debugPaintCount,
        b0 = Artboard.debugBuildCount;
    var resolveMs = 0.0;
    ctl.beginGesture();
    for (var i = 1; i <= 40; i++) {
      final w = Stopwatch()..start();
      ctl.execute(
        SetProperty.values({
          target: {
            'x': IrValue.number(520.0 + i),
            'y': const IrValue.number(180),
          },
        }),
      );
      final rw = Stopwatch()..start();
      container.read(resolvedForProvider('desktop'));
      container.read(resolvedForProvider('mobile'));
      resolveMs += _ms(rw);
      await tester.pump();
      direct.add(_ms(w));
    }
    ctl.endGesture();
    final phases = {
      'layouts/frame': (RenderStageBox.debugLayoutCount - l0) / 40,
      'paints/frame': (RenderStageBox.debugPaintCount - p0) / 40,
      'artboard builds/frame': (Artboard.debugBuildCount - b0) / 40,
      'resolve ms/frame': resolveMs / 40,
    };
    // ignore: avoid_print
    print(
      'same edit via the controller + frame: median '
      '${_pct(direct, 0.5).toStringAsFixed(2)} ms $phases',
    );
  });
}
