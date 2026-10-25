@Tags(['bench'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/preview/preview_stage.dart';
import 'package:soundstage_platform/editor/preview/preview_state.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/ir/ir.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

import 'bench_document.dart';

/// A committed edit on the 5,000-node bench document: how long the live
/// preview takes to follow (T2.6 budget: one or two frames, not counting
/// the 150 ms debounce).
///
/// The edit and the editor's own frame come first; the measured span is the
/// frame in which the debounce fires: `setState`, the player's incremental
/// re-resolve, the animator reload, the sliver rebuild, layout and paint
/// recording. Then the frames that follow are counted until the player is
/// idle.
///
///   flutter test --tags bench test/bench/preview_bench.dart
///   flutter test --tags bench --platform chrome --wasm test/bench/preview_bench.dart
double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

double _pct(List<double> xs, double p) {
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()];
}

StageDocument _doc() {
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

  return StageDocument.fromJson(
    solid(jsonDecode(jsonEncode(doc.toJson()))) as Map<String, dynamic>,
  );
}

void main() {
  testWidgets('a committed edit rebuilds the preview within a frame or two', (
    tester,
  ) async {
    final doc = _doc();
    final nodes = resolveDocument(doc).nodeIndex.length;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
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
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EditorCanvas)),
    );
    container.read(previewProvider.notifier).setOpen(true);
    await tester.pump();
    await tester.pump();
    final ctl = container.read(editorControllerProvider.notifier);
    final target = doc.scenes.single.root.children.first.id;
    StageDocument shown() =>
        tester.widget<StagePlayer>(find.byType(StagePlayer)).document;

    var lastCounts = '';
    Future<(double, int)> commit(int i) async {
      ctl.execute(
        SetProperty([target], 'opacity', IrValue.number(i.isEven ? 0.5 : 0.9)),
      );
      // The editor's own frame; the preview's debounce is still running.
      await tester.pump(const Duration(milliseconds: 20));
      expect(identical(shown(), ctl.state.document), isFalse);
      final l0 = RenderStageBox.debugLayoutCount;
      final p0 = RenderStageBox.debugPaintCount;
      var rb = 0;
      debugOnRebuildDirtyWidget = (e, _) => rb++;
      final w = Stopwatch()..start();
      await tester.pump(kPreviewDebounce);
      debugOnRebuildDirtyWidget = null;
      lastCounts =
          'layouts ${RenderStageBox.debugLayoutCount - l0} paints ${RenderStageBox.debugPaintCount - p0} rebuilt widgets $rb';
      final first = _ms(w);
      expect(identical(shown(), ctl.state.document), isTrue);
      // Frames needed until nothing is scheduled any more.
      var frames = 1;
      while (tester.binding.hasScheduledFrame && frames < 10) {
        await tester.pump();
        frames++;
      }
      return (first, frames);
    }

    for (var i = 0; i < 8; i++) {
      await commit(i); // warm-up
    }
    final times = <double>[];
    var maxFrames = 0;
    for (var i = 0; i < 40; i++) {
      final (t, frames) = await commit(i);
      times.add(t);
      if (frames > maxFrames) maxFrames = frames;
    }
    // ignore: avoid_print
    print(
      'preview rebuild after a committed edit ($nodes nodes), debounce not '
      'counted: median ${_pct(times, 0.5).toStringAsFixed(2)} ms, p95 '
      '${_pct(times, 0.95).toStringAsFixed(2)} ms, max '
      '${_pct(times, 1).toStringAsFixed(2)} ms; frames until idle (max over '
      'runs) $maxFrames; last: $lastCounts',
    );
  });
}
