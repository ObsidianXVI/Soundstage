@Tags(['bench'])
library;

import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWasm, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'bench_document.dart';

/// Editor budgets (architecture §17, §18; T1.2):
///   a coalesced 120-step drag of one node's position via SetProperty on a
///   5,000-node document, each step followed by an incremental re-resolve
///   of both primary breakpoints: < 4 ms per step;
///   200 history snapshots of that document stay bounded (shared subtrees).
///
///   flutter test --tags bench test/bench/editor_drag_bench.dart
///   flutter test --platform chrome --wasm --tags bench test/bench/editor_drag_bench.dart
///
/// The budget is enforced on the VM and on wasm (dart2wasm, optimised, what
/// ships). A plain `--platform chrome` run compiles with the debug dev
/// compiler (DDC), several times slower than any shipping build, so there
/// the numbers are only reported.
const _stepBudgetMs = 4.0;

/// Whether timings are representative (not the debug JS compiler).
const bool _enforce = !kIsWeb || kIsWasm;

double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

double _pct(List<double> xs, double p) {
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()];
}

/// Distinct node objects across [docs] (identity), counting each shared
/// subtree once.
int _distinctNodes(Iterable<StageDocument> docs) {
  final seen = Set<Node>.identity();
  void walk(Node n) {
    if (!seen.add(n)) return; // a shared subtree: already counted
    if (n is FrameNode) n.children.forEach(walk);
  }

  for (final d in docs) {
    for (final s in d.scenes) {
      walk(s.root);
    }
  }
  return seen.length;
}

int _authoredNodes(StageDocument d) => DocumentIndex.of(d).nodeIds.length;

void main() {
  final doc = documentOfNodes(5000, freeLayer: true);
  final resolvedCount = resolveDocument(doc).nodeIndex.length;
  final mid = doc.scenes.length ~/ 2;
  final target = 'free${mid}_3';

  ProviderContainer open() {
    final c = ProviderContainer(
      overrides: [initialDocumentProvider.overrideWithValue(doc)],
    );
    addTearDown(c.dispose);
    // Both artboards resolved once, as the canvas does on open.
    c.read(resolvedForProvider('desktop'));
    c.read(resolvedForProvider('mobile'));
    return c;
  }

  test('the document has about 5,000 resolved nodes', () {
    // ignore: avoid_print
    print(
      'bench document: $resolvedCount resolved / ${_authoredNodes(doc)} '
      'authored nodes, ${doc.scenes.length} scenes',
    );
    expect(resolvedCount, inInclusiveRange(4950, 5050));
    expect(validateDocument(doc), isEmpty);
  });

  test(
    'coalesced 120-step drag + both re-resolves < $_stepBudgetMs ms/step',
    () {
      final c = open();
      final ctl = c.read(editorControllerProvider.notifier);
      ctl.select({target});

      final editTimes = <double>[];
      void drag(int steps, [List<double>? times]) {
        ctl.beginGesture();
        for (var i = 1; i <= steps; i++) {
          final w = Stopwatch()..start();
          ctl.execute(
            SetProperty.values({
              target: {
                'x': IrValue.number(200.0 + i),
                'y': IrValue.number(80.0 + i / 2),
              },
            }),
          );
          final edit = _ms(w);
          c.read(resolvedForProvider('desktop'));
          c.read(resolvedForProvider('mobile'));
          times?.add(_ms(w));
          if (times != null) editTimes.add(edit);
        }
        ctl.endGesture();
      }

      drag(60); // warm-up gesture
      ctl.undo();
      final depth = ctl.history.undoDepth;
      final times = <double>[];
      drag(120, times);

      expect(ctl.history.undoDepth, depth + 1, reason: 'one coalesced entry');
      final desktop = c.read(resolvedForProvider('desktop')).resolved;
      final mobile = c.read(resolvedForProvider('mobile')).resolved;
      expect(desktop.nodeIndex[target]!.node.common.x, 320);
      // "Both" cleared mobile's x patch: the shared value shows there too.
      expect(mobile.nodeIndex[target]!.node.common.x, 320);
      expect(
        desktop,
        Resolver().resolve(
          c.read(editorControllerProvider).document,
          const ResolveContext(breakpointId: 'desktop'),
        ),
      );
      ctl.undo();
      expect(identical(c.read(editorControllerProvider).document, doc), isTrue);

      final median = _pct(times, 0.5), p95 = _pct(times, 0.95);
      // ignore: avoid_print
      print(
        'drag step ($resolvedCount nodes, SetProperty x/y + 2 re-resolves): '
        'median ${median.toStringAsFixed(3)} ms, p95 ${p95.toStringAsFixed(3)} '
        'ms, max ${_pct(times, 1).toStringAsFixed(3)} ms (budget $_stepBudgetMs '
        'ms); of which the command + history: median '
        '${_pct(editTimes, 0.5).toStringAsFixed(3)} ms',
      );
      if (_enforce) {
        expect(median, lessThan(_stepBudgetMs));
        expect(p95, lessThan(_stepBudgetMs));
      } else {
        // ignore: avoid_print
        print('(DDC debug build: budget reported, not enforced)');
      }
    },
  );

  test('200 history snapshots share every untouched subtree', () {
    final c = open();
    final ctl = c.read(editorControllerProvider.notifier);
    final index = DocumentIndex.of(doc);
    final ids = [
      for (final id in index.nodeIds)
        if (!index.locate(id)!.isRoot) id,
    ];
    final rnd = Random(1);
    for (var i = 0; i < 230; i++) {
      final id = ids[rnd.nextInt(ids.length)];
      ctl.execute(
        SetProperty([id], 'opacity', IrValue.number(0.5 + (i % 40) / 100)),
      );
    }
    final h = ctl.history;
    expect(h.undoDepth, 200);
    final docs = {
      for (final e in h.entries) ...[e.before.document, e.after.document],
    }.toList();
    final perDoc = _authoredNodes(doc);
    final distinct = _distinctNodes(docs);
    final naive = perDoc * docs.length;
    // Each edit copies only the path to the node: its ancestors (depth ≤ 5
    // here) plus the node itself.
    final pathBound = perDoc + 200 * 6;
    // ignore: avoid_print
    print(
      'history: ${docs.length} snapshots × $perDoc authored nodes = $naive '
      'if copied; $distinct distinct node objects retained '
      '(${(distinct / perDoc).toStringAsFixed(2)}× one document; bound '
      '$pathBound)',
    );
    expect(distinct, lessThanOrEqualTo(pathBound));
    // Consecutive snapshots share every scene but the edited one.
    var sharedScenes = 0, scenes = 0;
    final ordered = [
      h.entries.first.before.document,
      for (final e in h.entries) e.after.document,
    ];
    for (var i = 1; i < ordered.length; i++) {
      for (var s = 0; s < ordered[i].scenes.length; s++) {
        scenes++;
        if (identical(ordered[i].scenes[s], ordered[i - 1].scenes[s])) {
          sharedScenes++;
        }
      }
    }
    // ignore: avoid_print
    print(
      'history: $sharedScenes of $scenes scene objects identical to the '
      'previous snapshot',
    );
    expect(sharedScenes, scenes - (ordered.length - 1));
  });
}
