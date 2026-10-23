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

/// Inspector budgets (T1.7, architecture §17), measured as the cost a
/// 5,000-node story adds over a tiny story, so the budget isolates what
/// scales with the document (resolution, provenance, selection facts) from
/// the fixed cost of laying out ~50 controls in a test harness (the debug
/// VM JIT, test binding, fonts), which is a few ms per frame everywhere:
///   selecting a node: +< 8 ms (build + layout of every applicable section);
///   a scrub step (SetProperty + 2 re-resolves + inspector rebuild): +< 4 ms.
/// Absolute numbers are printed too.
///
///   flutter test --tags bench test/bench/inspector_bench.dart
///
/// Enforced on the VM and wasm; a plain `--platform chrome` run uses the
/// debug JS compiler, so there the numbers are only reported.
const _selectBudgetMs = 8.0;
const _scrubBudgetMs = 4.0;
const bool _enforce = !kIsWeb || kIsWasm;

double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

double _median(List<double> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

class _Measure {
  _Measure(this.selectMs, this.scrubMs);
  final double selectMs, scrubMs;
}

Future<_Measure> _measure(
  WidgetTester tester,
  StageDocument doc,
  String sceneId,
  List<String> targets,
) async {
  tester.view.physicalSize = const Size(330, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final c = ProviderContainer(
    overrides: [initialDocumentProvider.overrideWithValue(doc)],
  );
  addTearDown(c.dispose);
  final ctl = c.read(editorControllerProvider.notifier);
  ctl.setActiveScene(sceneId);
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

  for (var i = 0; i < 4; i++) {
    ctl.select({targets[i]});
    await tester.pump();
  }
  final select = <double>[];
  for (var i = 0; i < 24; i++) {
    final w = Stopwatch()..start();
    ctl.select({targets[i % targets.length]});
    await tester.pump();
    select.add(_ms(w));
  }

  ctl.select({targets[0]});
  await tester.pump();
  final scrub = <double>[];
  ctl.beginGesture();
  for (var i = 1; i <= 120; i++) {
    final w = Stopwatch()..start();
    ctl.execute(SetProperty([targets[0]], 'x', IrValue.number(100.0 + i)));
    c.read(resolvedForProvider('desktop'));
    c.read(resolvedForProvider('mobile'));
    await tester.pump();
    if (i > 20) scrub.add(_ms(w));
  }
  ctl.endGesture();
  return _Measure(_median(select), _median(scrub));
}

void main() {
  _Measure? tiny;

  testWidgets('tiny story baseline', (tester) async {
    final small = benchDocument(cards: 2, scenes: 1, freeLayer: true);
    tiny = await _measure(tester, small, small.scenes.first.id, [
      for (var i = 0; i < 12; i++) 'free0_${i % 8}',
    ]);
  });

  testWidgets('a 5,000-node story adds < $_selectBudgetMs ms to a select and '
      '< $_scrubBudgetMs ms to a scrub step', (tester) async {
    final big = documentOfNodes(5000, freeLayer: true);
    final mid = big.scenes.length ~/ 2;
    final bigM = await _measure(tester, big, big.scenes[mid].id, [
      for (var i = 0; i < 12; i++) 'free${mid}_${i % 8}',
    ]);
    final smallM = tiny!;
    final dSelect = bigM.selectMs - smallM.selectMs;
    final dScrub = bigM.scrubMs - smallM.scrubMs;
    // ignore: avoid_print
    print(
      'inspector select: ${bigM.selectMs.toStringAsFixed(2)} ms at 5,000 nodes, '
      '${smallM.selectMs.toStringAsFixed(2)} ms tiny (delta '
      '${dSelect.toStringAsFixed(2)}, budget $_selectBudgetMs); scrub step: '
      '${bigM.scrubMs.toStringAsFixed(2)} ms vs ${smallM.scrubMs.toStringAsFixed(2)} '
      '(delta ${dScrub.toStringAsFixed(2)}, budget $_scrubBudgetMs)',
    );
    if (_enforce) {
      expect(dSelect, lessThan(_selectBudgetMs));
      expect(dScrub, lessThan(_scrubBudgetMs));
    }
  });
}
