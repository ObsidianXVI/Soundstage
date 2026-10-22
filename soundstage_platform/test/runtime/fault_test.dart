// Fault containment (architecture §17.2): a node that throws during layout
// or paint is reported, sized from its stored geometry, painted as an error
// box in edit mode or nothing in play, and never breaks its siblings.
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

ir.FrameNode rowOfThree() => frame(
  'root',
  common('root', w: 1440, h: 900),
  children: [
    frame(
      'row',
      common('row'),
      autoLayout: const ir.AutoLayout(gap: ir.Gap.fixed(10)),
      children: [
        rect('a', common('a', w: 50, h: 20)),
        textNode('bad', text: 'boom', nodeCommon: common('bad', w: 30, h: 20)),
        rect('c', common('c', w: 50, h: 20)),
      ],
    ),
  ],
);

/// Captures reported Flutter errors while [body] runs.
Future<List<FlutterErrorDetails>> collectErrors(
  Future<void> Function() body,
) async {
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    await body();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

void main() {
  tearDown(() => debugStageFaultInjector = null);

  for (final mode in StageRenderMode.values) {
    testWidgets('a layout fault is contained (${mode.name})', (tester) async {
      debugStageFaultInjector = (id, phase) =>
          id == 'bad' && phase == StageFaultPhase.layout;
      final errors = await collectErrors(
        () => pumpScene(
          tester,
          docWithRoot(rowOfThree()),
          viewport: const Size(1440, 900),
          mode: mode,
        ),
      );
      expect(errors, isNotEmpty);
      expect(errors.first.library, 'soundstage runtime');
      expect(errors.first.exception, isA<StateError>());
      final bad = stageBox(tester, 'bad');
      expect(bad.hasLayoutFault, isTrue);
      // Sized from stored geometry; siblings laid out around it.
      expect(globalRect(tester, 'bad'), const Rect.fromLTWH(60, 0, 30, 20));
      expect(globalRect(tester, 'c'), const Rect.fromLTWH(100, 0, 50, 20));
      expect(tester.takeException(), isNull);
      // Play mode: not hittable. Edit mode: hittable (the editor selects it).
      final hit = tester.hitTestOnBinding(const Offset(70, 10));
      expect(
        hit.path.any((e) => e.target == bad),
        mode == StageRenderMode.edit,
      );
    });

    testWidgets('a paint fault is contained (${mode.name})', (tester) async {
      debugStageFaultInjector = (id, phase) =>
          id == 'bad' && phase == StageFaultPhase.paint;
      final errors = await collectErrors(
        () => pumpScene(
          tester,
          docWithRoot(rowOfThree()),
          viewport: const Size(1440, 900),
          mode: mode,
        ),
      );
      expect(errors, hasLength(1));
      expect(stageBox(tester, 'bad').hasPaintFault, isTrue);
      expect(stageBox(tester, 'c').hasPaintFault, isFalse);
      // Layout is unaffected: the text keeps its real 40 px width.
      expect(globalRect(tester, 'c'), const Rect.fromLTWH(110, 0, 50, 20));
      // Repainting does not report again.
      final again = await collectErrors(() async {
        stageBox(tester, 'root').markNeedsPaint();
        await tester.pump();
      });
      expect(again, isEmpty);
    });
  }

  testWidgets('the fault clears when the node lays out again', (tester) async {
    debugStageFaultInjector = (id, phase) =>
        id == 'bad' && phase == StageFaultPhase.layout;
    await collectErrors(
      () => pumpScene(
        tester,
        docWithRoot(rowOfThree()),
        viewport: const Size(1440, 900),
      ),
    );
    debugStageFaultInjector = null;
    stageBox(tester, 'bad').markStageLayoutDirty();
    await tester.pump();
    expect(stageBox(tester, 'bad').hasLayoutFault, isFalse);
    expect(globalRect(tester, 'bad').width, 40); // its real text width
  });

  testWidgets('a placeholder keeps its stored box and paints nothing in play', (
    tester,
  ) async {
    final root = frame(
      'root',
      common('root', w: 1440, h: 900),
      children: [
        frame(
          'row',
          common('row'),
          autoLayout: const ir.AutoLayout(),
          children: [
            const ir.InstanceNode(
              common: ir.NodeCommon(id: 'inst', width: 80, height: 40),
              source: ir.InstanceSource.component('missing'),
            ),
            rect('after', common('after', w: 10, h: 10)),
          ],
        ),
      ],
    );
    final resolved = await pumpScene(
      tester,
      docWithRoot(root),
      viewport: const Size(1440, 900),
    );
    expect(resolved.nodeIndex['inst']!.isPlaceholder, isTrue);
    expect(stageBox(tester, 'inst').placeholder, isTrue);
    expect(globalRect(tester, 'inst'), const Rect.fromLTWH(0, 0, 80, 40));
    expect(globalRect(tester, 'after').left, 80);
    expect(tester.takeException(), isNull);
  });
}
