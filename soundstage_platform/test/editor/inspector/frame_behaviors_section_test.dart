import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

void main() {
  testWidgets('a frame becomes a carousel, its options edit, it is removed', (
    tester,
  ) async {
    final c = await pumpInspector(
      tester,
      inspectorDoc([
        box('g', children: [rect('a'), rect('b')]),
      ]),
      select: {'g'},
      height: 2200,
    );
    await tester.tap(find.widgetWithText(SsButton, 'Carousel'));
    await tester.pumpAndSettle();
    ir.Behavior? behavior() => (nodeOf(c, 'g') as ir.FrameNode).behavior;
    expect(behavior(), const ir.Behavior.carousel());
    expect(find.byKey(const ValueKey('carousel-fields')), findsOneWidget);
    await tester.tap(find.text('Loop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Free'));
    await tester.pumpAndSettle();
    expect(
      behavior(),
      const ir.Behavior.carousel(loop: true, physics: ir.CarouselPhysics.free),
    );
    await tester.tap(find.bySemanticsLabel('Remove behaviour'));
    await tester.pumpAndSettle();
    expect(behavior(), isNull);
    // Marquee and lightbox are offered too.
    await tester.tap(find.widgetWithText(SsButton, 'Marquee'));
    await tester.pumpAndSettle();
    expect(behavior(), const ir.Behavior.marquee());
    expect(find.byKey(const ValueKey('marquee-fields')), findsOneWidget);
  });
}
