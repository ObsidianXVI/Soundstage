import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

void main() {
  testWidgets('add a tap interaction with actions, edit, remove', (
    tester,
  ) async {
    final doc = inspectorDoc([box('b')]);
    final c = await pumpInspector(
      tester,
      doc.copyWith(
        scenes: [
          doc.scenes.single.copyWith(
            clocks: const [
              ir.Clock.sceneScroll(id: 'clk1', sceneId: 's1'),
              ir.Clock.timeline(id: 'tl', duration: 2, name: 'Intro'),
            ],
          ),
        ],
      ),
      select: {'b'},
      height: 2400,
    );
    List<ir.Interaction> list() => nodeOf(c, 'b').common.interactions;
    expect(find.byKey(const ValueKey('interactions:hint')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('interactions:add')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On tap').last);
    await tester.pumpAndSettle();
    expect(list().single.trigger, const ir.InteractionTrigger.tap());

    final id = list().single.id;
    await tester.tap(find.byKey(ValueKey('interaction:$id:add-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Play timeline').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('interaction:$id:add-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Go to scene').last);
    await tester.pumpAndSettle();
    expect(list().single.actions, const [
      ir.Action.playTimeline(clockId: 'tl'),
      ir.Action.scrollToScene(sceneId: 's1'),
    ]);
    // Nothing to set: no variables, so the entry is disabled.
    await tester.tap(find.byKey(ValueKey('interaction:$id:add-action')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set variable').last);
    await tester.pumpAndSettle();
    expect(list().single.actions, hasLength(2));
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Remove interaction'));
    await tester.pumpAndSettle();
    expect(list(), isEmpty);
  });
}
