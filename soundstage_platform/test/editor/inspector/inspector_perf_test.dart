import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

/// Which widgets rebuilt while [body] ran (by runtime type name).
Future<Map<String, int>> _rebuilds(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final counts = <String, int>{};
  debugOnRebuildDirtyWidget = (element, builtOnce) {
    counts.update(
      element.widget.runtimeType.toString(),
      (n) => n + 1,
      ifAbsent: () => 1,
    );
  };
  try {
    await body();
  } finally {
    debugOnRebuildDirtyWidget = null;
  }
  return counts;
}

void main() {
  ir.StageDocument doc() => inspectorDoc([rect('a', x: 10), rect('b', x: 200)]);

  testWidgets('scrubbing x rebuilds only the x field', (tester) async {
    final c = await pumpInspector(tester, doc(), select: {'a'});
    final ctl = c.read(editorControllerProvider.notifier);
    final counts = await _rebuilds(tester, () async {
      ctl.execute(SetProperty(['a'], 'x', const ir.IrValue.number(55)));
      await tester.pump();
    });
    expect(counts['NumberProp'], 1, reason: '$counts');
    expect(counts['EnumProp'], isNull, reason: '$counts');
    expect(counts['BoolProp'], isNull, reason: '$counts');
    expect(counts['BoolIconProp'], isNull, reason: '$counts');
  });

  testWidgets('an edit to another node rebuilds no field', (tester) async {
    final c = await pumpInspector(tester, doc(), select: {'a'});
    final ctl = c.read(editorControllerProvider.notifier);
    final counts = await _rebuilds(tester, () async {
      ctl.execute(SetProperty(['b'], 'x', const ir.IrValue.number(55)));
      await tester.pump();
    });
    expect(counts['NumberProp'], isNull, reason: '$counts');
    expect(counts['FieldFrame'], isNull, reason: '$counts');
  });

  testWidgets('a typed edit commits once and the field keeps its value', (
    tester,
  ) async {
    final c = await pumpInspector(tester, doc(), select: {'a'});
    await typeInto(tester, 'x', '42');
    expect(valueAt(c, 'a', 'x', 'desktop'), const ir.IrValue.number(42));
    expect(c.read(editorControllerProvider.notifier).history.undoDepth, 1);
  });
}
