import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

ir.ShapeNode shape(
  String id, {
  bool visible = true,
  bool locked = false,
  ir.NodeRole role = ir.NodeRole.none,
}) => ir.ShapeNode(
  common: ir.NodeCommon(
    id: id,
    name: id,
    width: 10,
    height: 10,
    visible: visible,
    locked: locked,
    role: role,
  ),
);

ir.FrameNode frame(String id, [List<ir.Node> children = const []]) =>
    ir.FrameNode(
      common: ir.NodeCommon(id: id, name: id, width: 100, height: 100),
      children: children,
    );

const breakpoints = [
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

/// Scene s1 (pinned), children in paint order (the panel shows them
/// reversed: H, L, I, B, A):
///   A [A1, A2 [A21], T (text, heading 1)], B [B1], I (instance), L (locked),
///   H (hidden)
/// Scene s2 (flow): [C].
ir.StageDocument panelsDoc() => ir.StageDocument(
  id: 'doc',
  breakpoints: breakpoints,
  components: {
    'cmp': ir.ComponentDef(
      id: 'cmp',
      name: 'Card',
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'cmpR', width: 50, height: 50),
        children: [shape('cmpI'), shape('cmpJ')],
      ),
    ),
  },
  scenes: [
    ir.Scene(
      id: 's1',
      name: 'One',
      kind: ir.SceneKind.pinned,
      scrollLength: 1,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 1000, height: 800),
        children: [
          frame('A', [
            shape('A1'),
            frame('A2', [shape('A21')]),
            const ir.TextNode(
              common: ir.NodeCommon(
                id: 'T',
                name: 'T',
                role: ir.NodeRole.heading1,
              ),
              content: [
                ir.Paragraph(spans: [ir.Span(text: 'Title')]),
              ],
            ),
          ]),
          frame('B', [shape('B1')]),
          const ir.InstanceNode(
            common: ir.NodeCommon(id: 'I', name: 'I', width: 50, height: 50),
            source: ir.InstanceSource.component('cmp'),
          ),
          shape('L', locked: true),
          shape('H', visible: false),
        ],
      ),
      clocks: const [ir.Clock.sceneScroll(id: 'clk1', sceneId: 's1')],
    ),
    ir.Scene(
      id: 's2',
      name: 'Two',
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root2', width: 1000, height: 800),
        children: [shape('C')],
      ),
      clocks: const [ir.Clock.sceneScroll(id: 'clk2', sceneId: 's2')],
    ),
  ],
);

/// [frames] frames of [perFrame] shapes each, in one pinned scene.
ir.StageDocument bigDoc({int frames = 50, int perFrame = 100}) {
  return ir.StageDocument(
    id: 'big',
    breakpoints: breakpoints,
    scenes: [
      ir.Scene(
        id: 's1',
        name: 'Big',
        kind: ir.SceneKind.pinned,
        scrollLength: 1,
        root: ir.FrameNode(
          common: const ir.NodeCommon(id: 'root', width: 1000, height: 800),
          children: [
            for (var f = 0; f < frames; f++)
              frame('F$f', [
                for (var i = 0; i < perFrame; i++) shape('F$f.$i'),
              ]),
          ],
        ),
        clocks: const [ir.Clock.sceneScroll(id: 'clk1', sceneId: 's1')],
      ),
    ],
  );
}

/// Pumps [panel] (264 wide, [height] tall) over an editor opened on [doc].
Future<ProviderContainer> pumpPanel(
  WidgetTester tester,
  Widget panel, {
  ir.StageDocument? doc,
  double height = 600,
  double width = 264,
}) async {
  tester.view.physicalSize = Size(width + 40, height + 40);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialDocumentProvider.overrideWithValue(doc ?? panelsDoc())],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, c) => SsScope(theme: SsThemeData.dark(), child: c!),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, height: height, child: panel),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

extension PanelTestX on ProviderContainer {
  EditorController get ctl => read(editorControllerProvider.notifier);
  EditorState get st => read(editorControllerProvider);
  ir.StageDocument get doc => st.document;
}

/// The names of [parentId]'s children in paint order.
List<String> childNames(ir.StageDocument doc, String parentId) {
  final n = ir.DocumentIndex.of(doc).node(parentId)! as ir.FrameNode;
  return [for (final c in n.children) c.id];
}

Finder rowOf(String label) => find.widgetWithText(SsTreeRow, label);

SsTreeRow rowWidget(WidgetTester tester, String label) =>
    tester.widget<SsTreeRow>(rowOf(label));

Finder glyph(IconData i) => find.text(String.fromCharCode(i.codePoint));

/// [panelsDoc] plus a third scene "Three" (flow, root3 [D]).
ir.StageDocument threeScenesDoc() {
  final d = panelsDoc();
  return d.copyWith(
    scenes: [
      ...d.scenes,
      ir.Scene(
        id: 's3',
        name: 'Three',
        kind: ir.SceneKind.flow,
        root: ir.FrameNode(
          common: const ir.NodeCommon(id: 'root3', width: 1000, height: 800),
          children: [shape('D')],
        ),
        clocks: const [ir.Clock.sceneScroll(id: 'clk3', sceneId: 's3')],
      ),
    ],
  );
}

List<String> sceneIds(ir.StageDocument doc) => [
  for (final s in doc.scenes) s.id,
];
