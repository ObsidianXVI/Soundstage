@Tags(['bench'])
library;

import 'package:flutter/foundation.dart' show kIsWasm, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/inspector.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'bench_document.dart';

/// Inspector budgets (T1.7, architecture §17):
///   selecting a node of a 5,000-node story builds the inspector (every
///   applicable section, with all provenance checks) in < 8 ms;
///   a scrub step (SetProperty + the inspector's rebuild) < 4 ms.
///
///   flutter test --tags bench test/bench/inspector_bench.dart
///
/// Enforced on the VM (JIT, debug asserts on: pessimistic) and on wasm; a
/// plain `--platform chrome` run uses the debug JS compiler, so there the
/// numbers are only reported.
const _selectBudgetMs = 8.0;
const _scrubBudgetMs = 4.0;
const bool _enforce = !kIsWeb || kIsWasm;

double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

double _pct(List<double> xs, double p) {
  final s = [...xs]..sort();
  return s[((s.length - 1) * p).round()];
}

void main() {
  final doc = documentOfNodes(5000, freeLayer: true);
  final mid = doc.scenes.length ~/ 2;
  final targets = [for (var i = 0; i < 12; i++) 'free${mid}_${i % 8}'];

  Future<ProviderContainer> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(330, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [initialDocumentProvider.overrideWithValue(doc)],
    );
    addTearDown(c.dispose);
    final ctl = c.read(editorControllerProvider.notifier);
    ctl.setActiveScene(doc.scenes[mid].id);
    c.read(resolvedForProvider('desktop'));
    c.read(resolvedForProvider('mobile'));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          builder: (context, child) =>
              SsScope(theme: SsThemeData.dark(), child: child!),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 288, height: 960, child: Inspector()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return c;
  }

  testWidgets(
    'selecting a node in a 5,000-node story builds < $_selectBudgetMs ms',
    (tester) async {
      final c = await open(tester);
      final ctl = c.read(editorControllerProvider.notifier);
      // Warm-up: JIT, providers, fonts.
      for (var i = 0; i < 4; i++) {
        ctl.select({targets[i]});
        await tester.pump();
      }
      // Node to node (the common click): sections and fields are reused.
      final switching = <double>[];
      for (var i = 0; i < 24; i++) {
        final w = Stopwatch()..start();
        ctl.select({targets[i % targets.length]});
        await tester.pump();
        switching.add(_ms(w));
      }
      // From nothing selected: every section is built from scratch.
      final fromEmpty = <double>[];
      for (var i = 0; i < 12; i++) {
        ctl.clearSelection();
        await tester.pump();
        final w = Stopwatch()..start();
        ctl.select({targets[i % targets.length]});
        await tester.pump();
        fromEmpty.add(_ms(w));
      }
      final median = _pct(switching, 0.5), p95 = _pct(switching, 0.95);
      // ignore: avoid_print
      print(
        'inspector select node to node (5,000 nodes): median '
        '${median.toStringAsFixed(2)} ms, p95 ${p95.toStringAsFixed(2)} ms '
        '(budget $_selectBudgetMs ms); from empty: median '
        '${_pct(fromEmpty, 0.5).toStringAsFixed(2)} ms',
      );
      if (_enforce) expect(median, lessThan(_selectBudgetMs));
    },
  );

  testWidgets('a scrub step (write + inspector rebuild) < $_scrubBudgetMs ms', (
    tester,
  ) async {
    final c = await open(tester);
    final ctl = c.read(editorControllerProvider.notifier);
    ctl.select({targets[0]});
    await tester.pump();
    final times = <double>[];
    ctl.beginGesture();
    for (var i = 1; i <= 120; i++) {
      final w = Stopwatch()..start();
      ctl.execute(SetProperty([targets[0]], 'x', IrValue.number(100.0 + i)));
      c.read(resolvedForProvider('desktop'));
      c.read(resolvedForProvider('mobile'));
      await tester.pump();
      if (i > 20) times.add(_ms(w));
    }
    ctl.endGesture();
    final median = _pct(times, 0.5), p95 = _pct(times, 0.95);
    // ignore: avoid_print
    print(
      'inspector scrub step (x + 2 re-resolves + inspector pump): median '
      '${median.toStringAsFixed(2)} ms, p95 ${p95.toStringAsFixed(2)} ms '
      '(budget $_scrubBudgetMs ms)',
    );
    if (_enforce) expect(median, lessThan(_scrubBudgetMs));
  });
}
