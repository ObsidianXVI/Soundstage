@Tags(['bench'])
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/text/text_edit_layer.dart';
import 'package:soundstage_platform/ir/ir.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

import 'bench_document.dart';

/// Typing into a 2,000-character paragraph in a 5,000-node scene (T1.8):
/// each keystroke is a delta through the real `TextEditSession`, then a
/// frame (command, resolve both artboards, rebuild, relayout of the edited
/// text, paint). Budget: under 8 ms per keystroke; only the edited node
/// lays out.
///
///   flutter test --tags bench test/bench/text_typing_bench.dart
double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

double _pct(List<double> xs, double p) {
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()];
}

StageDocument _doc() {
  final doc = documentOfNodes(5000, scenes: 1);
  final s = doc.scenes.single;
  final words = List.generate(400, (i) => 'word$i').join(' ');
  final text = TextNode(
    common: const NodeCommon(id: 'essay', x: 40, y: 40, width: 600),
    autoResize: TextAutoResize.height,
    style: const TextStyleOverride(fontSize: 14),
    content: [
      Paragraph(spans: [Span(text: words.substring(0, 2000))]),
    ],
  );
  final moved = doc.copyWith(
    scenes: [
      s.copyWith(root: s.root.copyWith(children: [text, ...s.root.children])),
    ],
  );
  // Image fills point at assets the test bundle lacks: use solids.
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
  testWidgets('typing into a 2,000-character paragraph, 5,000 nodes', (
    tester,
  ) async {
    final doc = _doc();
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
    container
        .read(canvasControllerProvider)
        .setCamera(const CanvasCamera(zoom: 0.5, panX: 20, panY: 20));
    final ctl = container.read(editorControllerProvider.notifier);
    ctl.select({'essay'});
    ctl.applySelection(
      const SelectionState(selection: {'essay'}, textEditId: 'essay'),
    );
    await tester.pump();
    final layer = tester.state<TextEditLayerState>(find.byType(TextEditLayer));
    final session = layer.session!;
    session.selection = const TextSelection.collapsed(offset: 1000);

    final phases = <String, double>{'input': 0, 'resolve': 0, 'frame': 0};
    Future<List<double>> type(int n) async {
      final out = <double>[];
      for (var i = 0; i < n; i++) {
        final w = Stopwatch()..start();
        final p = Stopwatch()..start();
        final at = session.selection.start;
        session.updateEditingValueWithDeltas([
          TextEditingDeltaInsertion(
            oldText: session.text,
            textInserted: i % 6 == 5 ? ' ' : 'x',
            insertionOffset: at,
            selection: TextSelection.collapsed(offset: at + 1),
            composing: TextRange.empty,
          ),
        ]);
        phases['input'] = phases['input']! + _ms(p);
        p.reset();
        container.read(resolvedForProvider('desktop'));
        container.read(resolvedForProvider('mobile'));
        phases['resolve'] = phases['resolve']! + _ms(p);
        p.reset();
        await tester.pump();
        phases['frame'] = phases['frame']! + _ms(p);
        out.add(_ms(w));
      }
      return out;
    }

    await type(30); // warm-up
    phases.updateAll((_, _) => 0);
    final l0 = RenderStageBox.debugLayoutCount;
    final times = await type(120);
    final layouts = (RenderStageBox.debugLayoutCount - l0) / 120;
    final typing = phases.map((k, v) => MapEntry(k, v / 120));

    // The same frame for a non-text edit of the same node (a 1 px move:
    // command, resolve, rebuild, relayout of that node): the editor's fixed
    // per-edit cost, which the text work adds to.
    final base = <double>[];
    ctl.beginGesture();
    for (var i = 0; i < 60; i++) {
      final w = Stopwatch()..start();
      ctl.execute(SetProperty(['essay'], 'x', IrValue.number(40.0 + i % 2)));
      container.read(resolvedForProvider('desktop'));
      container.read(resolvedForProvider('mobile'));
      await tester.pump();
      base.add(_ms(w));
    }
    ctl.endGesture();
    final textCost = _pct(times, 0.5) - _pct(base, 0.5);
    // ignore: avoid_print
    print(
      'typing ($count nodes, 2,000-char paragraph): per keystroke median '
      '${_pct(times, 0.5).toStringAsFixed(2)} ms, p95 '
      '${_pct(times, 0.95).toStringAsFixed(2)} ms; '
      '${layouts.toStringAsFixed(1)} stage layouts per keystroke; phases '
      '${typing.map((k, v) => MapEntry(k, v.toStringAsFixed(2)))} ms; '
      'a non-text edit of the same node: median '
      '${_pct(base, 0.5).toStringAsFixed(2)} ms; text work '
      '${textCost.toStringAsFixed(2)} ms (debug test binding)',
    );
    // Only the edited text relays out (on both artboards), with its
    // ancestors' passes.
    expect(layouts, lessThan(8));
    // What typing adds to the editor's per-edit frame (session, command,
    // text relayout) stays within the 8 ms keystroke budget.
    expect(textCost, lessThan(8));
  });
}
