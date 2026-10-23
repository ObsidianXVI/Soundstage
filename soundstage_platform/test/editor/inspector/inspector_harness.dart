import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/inspector.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

export '../panels/panels_harness.dart' show PanelTestX;

const kBreakpoints = [
  ir.Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 1024,
    designSize: ir.StageSize(width: 1000, height: 800),
    primary: true,
  ),
  ir.Breakpoint(
    id: 'mobile',
    name: 'Mobile',
    minWidth: 0,
    designSize: ir.StageSize(width: 400, height: 800),
    primary: true,
  ),
];

/// One pinned scene "s1" with root [children], for inspector tests.
ir.StageDocument inspectorDoc(
  List<ir.Node> children, {
  List<ir.Breakpoint> breakpoints = kBreakpoints,
}) => ir.StageDocument(
  id: 'doc',
  breakpoints: breakpoints,
  scenes: [
    ir.Scene(
      id: 's1',
      name: 'One',
      kind: ir.SceneKind.pinned,
      scrollLength: 1,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 1000, height: 800),
        children: children,
      ),
      clocks: const [ir.Clock.sceneScroll(id: 'clk1', sceneId: 's1')],
    ),
  ],
);

ir.ShapeNode rect(
  String id, {
  double x = 0,
  double y = 0,
  double w = 100,
  double h = 50,
  double opacity = 1,
  Map<String, ir.Patch> patches = const {},
  ir.Appearance appearance = const ir.Appearance(),
  ir.LayoutChild layoutChild = const ir.LayoutChild(),
}) => ir.ShapeNode(
  common: ir.NodeCommon(
    id: id,
    name: id,
    x: x,
    y: y,
    width: w,
    height: h,
    opacity: opacity,
    breakpointOverrides: patches,
    layoutChild: layoutChild,
  ),
  appearance: appearance,
);

ir.FrameNode box(
  String id, {
  List<ir.Node> children = const [],
  double x = 0,
  double y = 0,
  double w = 300,
  double h = 300,
  ir.AutoLayout? autoLayout,
  ir.Appearance appearance = const ir.Appearance(),
  ir.LayoutChild layoutChild = const ir.LayoutChild(),
}) => ir.FrameNode(
  common: ir.NodeCommon(
    id: id,
    name: id,
    x: x,
    y: y,
    width: w,
    height: h,
    layoutChild: layoutChild,
  ),
  children: children,
  autoLayout: autoLayout,
  appearance: appearance,
);

/// Pumps the [Inspector] (288 wide) over an editor opened on [doc].
Future<ProviderContainer> pumpInspector(
  WidgetTester tester,
  ir.StageDocument doc, {
  double width = 288,
  double height = 900,
  Set<String> select = const {},
}) async {
  tester.view.physicalSize = Size(width + 40, height + 40);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialDocumentProvider.overrideWithValue(doc)],
  );
  addTearDown(container.dispose);
  if (select.isNotEmpty) {
    container.read(editorControllerProvider.notifier).select(select);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, c) => SsScope(theme: SsThemeData.dark(), child: c!),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: height,
              child: const Inspector(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// The editable text of the control keyed `field:<path>`.
Finder fieldText(String path) => find.descendant(
  of: find.byKey(ValueKey<String>('field:$path')),
  matching: find.byType(EditableText),
);

/// Types [text] into the number field at [path] and commits with Enter.
Future<void> typeInto(WidgetTester tester, String path, String text) async {
  final f = fieldText(path);
  expect(f, findsOneWidget, reason: 'field:$path');
  await tester.tap(f);
  await tester.pump();
  await tester.enterText(f, text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

/// The IR node [id] of the current document.
ir.Node nodeOf(ProviderContainer c, String id) =>
    ir.DocumentIndex.of(c.read(editorControllerProvider).document).node(id)!;

/// The resolved value of [path] on [id] at breakpoint [bp].
ir.IrValue? valueAt(ProviderContainer c, String id, String path, String bp) {
  final art = c.read(editorControllerProvider.notifier).resolvedFor(bp);
  return ir.resolvedPropertyValue(art.resolved.nodeIndex[id]!, path);
}
