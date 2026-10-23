import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

const kBreakpoints = [
  Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 1024,
    designSize: StageSize(width: 1000, height: 800),
    primary: true,
  ),
  Breakpoint(
    id: 'mobile',
    name: 'Mobile',
    minWidth: 0,
    designSize: StageSize(width: 400, height: 800),
    primary: true,
  ),
  Breakpoint(
    id: 'tablet',
    name: 'Tablet',
    minWidth: 600,
    designSize: StageSize(width: 700, height: 800),
    inheritsFrom: 'desktop',
  ),
];

ShapeNode shape(
  String id, {
  double x = 0,
  double y = 0,
  double w = 10,
  double h = 10,
  bool visible = true,
  bool locked = false,
  Map<String, Patch> patches = const {},
}) => ShapeNode(
  common: NodeCommon(
    id: id,
    x: x,
    y: y,
    width: w,
    height: h,
    visible: visible,
    locked: locked,
    breakpointOverrides: patches,
  ),
);

/// s1 (pinned): root [
///   a (100,50 300×300) [ a1 (10,20; mobile x 30), t1 (text), a2 (40,100 100×100) [ a21 ] ],
///   b (500,50 200×100) [ b1 ],
///   inst (700,300 50×50, component cmp: cmpR [ cmpI, cmpT ]),
///   locked (locked), hidden (hidden),
///   row (0,500 auto layout, gap 10, padding 5) [ r1 (20×10), r2 (30×10) ],
/// ]
/// s2 (flow): root2 [ c ]
StageDocument fixtureDoc() => StageDocument(
  id: 'doc',
  breakpoints: kBreakpoints,
  components: {
    'cmp': ComponentDef(
      id: 'cmp',
      name: 'Card',
      root: FrameNode(
        common: const NodeCommon(id: 'cmpR', width: 50, height: 50),
        children: [
          shape('cmpI'),
          const TextNode(
            common: NodeCommon(id: 'cmpT', y: 20),
            content: [
              Paragraph(spans: [Span(text: 'Card')]),
            ],
          ),
        ],
      ),
    ),
  },
  scenes: [
    Scene(
      id: 's1',
      name: 'One',
      kind: SceneKind.pinned,
      scrollLength: 1,
      root: FrameNode(
        common: const NodeCommon(id: 'root', width: 1000, height: 800),
        children: [
          FrameNode(
            common: const NodeCommon(
              id: 'a',
              x: 100,
              y: 50,
              width: 300,
              height: 300,
            ),
            children: [
              shape(
                'a1',
                x: 10,
                y: 20,
                patches: {
                  'mobile': {'x': const IrValue.number(30)},
                },
              ),
              const TextNode(
                common: NodeCommon(id: 't1', x: 10, y: 50),
                content: [
                  Paragraph(spans: [Span(text: 'Hello')]),
                ],
              ),
              FrameNode(
                common: const NodeCommon(
                  id: 'a2',
                  x: 40,
                  y: 100,
                  width: 100,
                  height: 100,
                ),
                children: [shape('a21')],
              ),
            ],
          ),
          FrameNode(
            common: const NodeCommon(
              id: 'b',
              x: 500,
              y: 50,
              width: 200,
              height: 100,
            ),
            children: [shape('b1', x: 1, y: 2)],
          ),
          const InstanceNode(
            common: NodeCommon(
              id: 'inst',
              x: 700,
              y: 300,
              width: 50,
              height: 50,
            ),
            source: InstanceSource.component('cmp'),
          ),
          shape('locked', locked: true),
          shape('hidden', visible: false),
          FrameNode(
            common: const NodeCommon(id: 'row', y: 500, width: 200, height: 20),
            autoLayout: const AutoLayout(
              gap: Gap.fixed(10),
              padding: EdgeInsetsValue(top: 5, left: 5, right: 5, bottom: 5),
            ),
            children: [shape('r1', w: 20), shape('r2', w: 30)],
          ),
        ],
      ),
      clocks: const [Clock.sceneScroll(id: 'clk1', sceneId: 's1')],
    ),
    Scene(
      id: 's2',
      name: 'Two',
      root: FrameNode(
        common: const NodeCommon(id: 'root2', width: 1000, height: 800),
        children: [shape('c')],
      ),
      clocks: const [Clock.sceneScroll(id: 'clk2', sceneId: 's2')],
    ),
  ],
);

/// A container whose editor opens [doc] (default [fixtureDoc]).
ProviderContainer editorContainer([StageDocument? doc]) {
  final c = ProviderContainer(
    overrides: [initialDocumentProvider.overrideWithValue(doc ?? fixtureDoc())],
  );
  addTearDown(c.dispose);
  return c;
}

extension EditorTestX on ProviderContainer {
  EditorController get ctl => read(editorControllerProvider.notifier);
  EditorState get st => read(editorControllerProvider);
  StageDocument get doc => st.document;
  Node node(String id) => DocumentIndex.of(doc).node(id)!;

  /// The resolved node [id] at breakpoint [bp].
  ResolvedNode resolved(String id, String bp) =>
      read(resolvedForProvider(bp)).resolved.nodeIndex[id]!;
}

/// Executes [command] and checks undo restores the document and selection
/// exactly, and redo restores the result. Returns the result.
CommandResult expectRoundTrip(ProviderContainer c, EditCommand command) {
  final before = c.st;
  final r = c.ctl.execute(command);
  expect(r.ok, isTrue, reason: '${r.diagnostics}');
  expect(r.changed, isTrue);
  final after = c.st;
  expect(identical(after.document, before.document), isFalse);
  expect(c.ctl.undo(), isTrue);
  expect(identical(c.doc, before.document), isTrue);
  expect(c.st.selection, before.selection);
  expect(c.st.activeSceneId, before.activeSceneId);
  expect(c.st.revision, before.revision);
  expect(c.ctl.redo(), isTrue);
  expect(identical(c.doc, after.document), isTrue);
  expect(c.st.selection, after.selection);
  expect(c.st.activeSceneId, after.activeSceneId);
  return r;
}
