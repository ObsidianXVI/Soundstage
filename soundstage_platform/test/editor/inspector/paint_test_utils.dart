import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/inspector/inspector.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

/// Sections collapsed by [pumpPaints] so the paint stack sits near the top.
const _otherSections = ['frame', 'autoLayout', 'layoutChild', 'appearance'];

/// [pumpInspector] for paint-stack tests: other sections are collapsed
/// (and errors they report at narrow widths, which are not the paint
/// editors', are taken), so later checks see only the paint editors.
Future<ProviderContainer> pumpPaints(
  WidgetTester tester,
  ir.StageDocument doc, {
  required Set<String> select,
  double width = 288,
  double height = 1600,
}) async {
  final c = await pumpInspector(
    tester,
    doc,
    select: select,
    width: width,
    height: height,
  );
  tester.takeException();
  final collapsed = c.read(collapsedSectionsProvider.notifier);
  for (final id in _otherSections) {
    collapsed.set(id, collapsed: true);
  }
  await tester.pump(const Duration(milliseconds: 400));
  tester.takeException();
  return c;
}

/// Scrolls [finder] into view and taps it.
Future<void> tapOn(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await tester.pump();
  // Let size animations (panel bodies, expanding editors) settle.
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> tapKey(WidgetTester tester, String key) =>
    tapOn(tester, find.byKey(ValueKey<String>(key)));

/// The fills of shape or frame [id].
List<ir.Paint> fillsOf(ProviderContainer c, String id) =>
    switch (nodeOf(c, id)) {
      ir.ShapeNode(:final appearance) ||
      ir.FrameNode(:final appearance) => appearance.fills,
      _ => const [],
    };
