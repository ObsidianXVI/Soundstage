import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

ir.StageDocument _doc(ir.AssetKind kind) =>
    inspectorDoc([
      const ir.EmbedNode(
        common: ir.NodeCommon(id: 'e', width: 100, height: 100),
        assetId: 'a',
      ),
    ]).copyWith(
      assets: {
        'a': ir.Asset(id: 'a', kind: kind, uri: 'local://a', name: 'anim'),
      },
    );

void main() {
  testWidgets('a Lottie embed binds its progress to a clock', (tester) async {
    final c = await pumpInspector(
      tester,
      _doc(ir.AssetKind.lottie),
      select: {'e'},
      height: 1600,
    );
    await tester.tap(find.byKey(const ValueKey('embed:bind:progress')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scene scroll').last);
    await tester.pumpAndSettle();
    expect((nodeOf(c, 'e') as ir.EmbedNode).inputBindings, {
      'progress': 'clk1',
    });
  });

  testWidgets('a Rive embed names its state machine and adds inputs', (
    tester,
  ) async {
    final c = await pumpInspector(
      tester,
      _doc(ir.AssetKind.rive),
      select: {'e'},
      height: 1600,
    );
    final sm = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is SsTextField && w.semanticLabel == 'State machine',
      ),
      matching: find.byType(EditableText),
    );
    await tester.enterText(sm, 'Main');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect((nodeOf(c, 'e') as ir.EmbedNode).stateMachine, 'Main');
    await tester.tap(find.byKey(const ValueKey('embed:add-binding')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(SsDialog),
        matching: find.byType(EditableText),
      ),
      'tilt',
    );
    await tester.tap(find.widgetWithText(SsButton, 'Add'));
    await tester.pumpAndSettle();
    expect((nodeOf(c, 'e') as ir.EmbedNode).inputBindings, {'tilt': 'clk1'});
  });

  testWidgets('an image sequence shows its frames and binds progress', (
    tester,
  ) async {
    final doc = _doc(ir.AssetKind.imageSequence);
    final c = await pumpInspector(
      tester,
      doc.copyWith(
        assets: {
          'a': doc.assets['a']!.copyWith(
            uri: 'local://a_{0001}',
            frameCount: 48,
          ),
        },
      ),
      select: {'e'},
      height: 1600,
    );
    expect(find.text('Image sequence · 48 frames · anim'), findsOneWidget);
    expect(find.text('State machine'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('embed:bind:progress')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scene scroll').last);
    await tester.pumpAndSettle();
    expect((nodeOf(c, 'e') as ir.EmbedNode).inputBindings, {
      'progress': 'clk1',
    });
  });
}
