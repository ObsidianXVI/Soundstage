@Tags(['bench'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'bench_document.dart';

/// Budgets from architecture §18:
///   full resolve, 2,000-node document   < 16 ms
///   re-resolve after one property edit  < 2 ms
///
///   flutter test --tags bench test/bench/resolver_bench.dart
///   flutter test --platform chrome --tags bench test/bench/resolver_bench.dart
const _fullBudgetMs = 16.0;
const _editBudgetMs = 2.0;

double _median(List<double> xs) {
  final s = [...xs]..sort();
  return s[s.length ~/ 2];
}

double _ms(Stopwatch w) => w.elapsedMicroseconds / 1000;

void main() {
  final doc = documentOfNodes(2000);
  final nodeCount = resolveDocument(doc).nodeIndex.length;

  test('the benchmark document has about 2,000 resolved nodes', () {
    // ignore: avoid_print
    print(
      'bench document: $nodeCount resolved nodes, ${doc.scenes.length} scenes',
    );
    expect(nodeCount, inInclusiveRange(1950, 2050));
    expect(resolveDocument(doc).diagnostics, isEmpty);
    expect(validateDocument(doc), isEmpty);
  });

  test('full resolve (cold) stays under $_fullBudgetMs ms', () {
    const warmup = 15;
    const runs = 51;
    for (var i = 0; i < warmup; i++) {
      Resolver().resolve(doc);
    }
    final times = <double>[];
    for (var i = 0; i < runs; i++) {
      final resolver = Resolver(); // cold: no memoised state
      final w = Stopwatch()..start();
      resolver.resolve(doc);
      times.add(_ms(w));
    }
    final median = _median(times);
    // ignore: avoid_print
    print(
      'full resolve ($nodeCount nodes): median ${median.toStringAsFixed(2)} ms, '
      'min ${(([...times]..sort()).first).toStringAsFixed(2)} ms, '
      'max ${(([...times]..sort()).last).toStringAsFixed(2)} ms '
      '(budget $_fullBudgetMs ms)',
    );
    expect(median, lessThan(_fullBudgetMs));
  });

  test(
    're-resolve after a single-property edit stays under $_editBudgetMs ms',
    () {
      const warmup = 20;
      const runs = 101;
      final target = middleTextId(doc);
      // A chain of edited documents; each shares every untouched subtree with
      // its predecessor (path copying), built outside the timed region.
      final chain = <StageDocument>[doc];
      for (var i = 0; i < warmup + runs; i++) {
        chain.add(withOpacity(chain.last, target, i.isEven ? 0.5 : 0.75));
      }
      final resolver = Resolver()..resolve(chain.first);
      for (var i = 1; i <= warmup; i++) {
        resolver.resolve(chain[i]);
      }
      final times = <double>[];
      ResolvedDocument? last;
      for (var i = warmup + 1; i <= warmup + runs; i++) {
        final w = Stopwatch()..start();
        last = resolver.resolve(chain[i]);
        times.add(_ms(w));
      }
      final median = _median(times);
      // ignore: avoid_print
      print(
        'single-property re-resolve ($nodeCount nodes): median '
        '${median.toStringAsFixed(3)} ms, '
        'max ${(([...times]..sort()).last).toStringAsFixed(3)} ms '
        '(budget $_editBudgetMs ms)',
      );
      // The result is right, not merely fast.
      expect(last!.nodeIndex[target]!.node.common.opacity, anyOf(0.5, 0.75));
      expect(last, Resolver().resolve(chain.last));
      expect(median, lessThan(_editBudgetMs));
    },
  );
}
