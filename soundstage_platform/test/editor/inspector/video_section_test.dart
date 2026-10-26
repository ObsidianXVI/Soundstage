import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

void main() {
  testWidgets('video options write the node', (tester) async {
    final doc =
        inspectorDoc([
          const ir.VideoNode(
            common: ir.NodeCommon(id: 'v', width: 320, height: 180),
            assetId: 'vid',
          ),
        ]).copyWith(
          assets: const {
            'vid': ir.Asset(
              id: 'vid',
              kind: ir.AssetKind.video,
              uri: 'local://vid',
            ),
            'img': ir.Asset(
              id: 'img',
              kind: ir.AssetKind.image,
              uri: 'local://img',
              name: 'Still',
            ),
          },
        );
    final c = await pumpInspector(tester, doc, select: {'v'}, height: 1600);
    ir.VideoNode v() => nodeOf(c, 'v') as ir.VideoNode;
    expect(find.text('Video'), findsWidgets); // header kind and section
    await tester.tap(find.text('Full'));
    await tester.pumpAndSettle();
    expect(v().controls, ir.VideoControls.full);
    await tester.tap(find.text('Pause when off screen'));
    await tester.pumpAndSettle();
    expect(v().playWhenVisible, isFalse);
    await typeInto(tester, 'endTime', '4.5');
    expect(v().endTime, 4.5);
    await tester.tap(find.bySemanticsLabel('Play to the end'));
    await tester.pumpAndSettle();
    expect(v().endTime, isNull);
    await tester.tap(find.byKey(const ValueKey('video-poster')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Still').last);
    await tester.pumpAndSettle();
    expect(v().posterAssetId, 'img');
  });
}
