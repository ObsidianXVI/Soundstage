import 'package:soundstage_platform/ir/ir.dart';

/// A realistic long-form story for benchmarks: several scenes of nested
/// auto-layout sections holding cards (frames with images, text and shapes),
/// component instances (with nested instances and prop overrides), token
/// bindings, a named text style and breakpoint patches.
///
/// [cards] controls the size; [documentOfNodes] searches for a card count
/// whose *resolved* tree has about the wanted number of nodes.
StageDocument benchDocument({required int cards, int scenes = 8}) {
  var n = 0;
  String id(String p) => '$p${n++}';

  const bp = [
    Breakpoint(
      id: 'desktop',
      name: 'Desktop',
      minWidth: 1024,
      designSize: StageSize(width: 1440, height: 900),
    ),
    Breakpoint(
      id: 'mobile',
      name: 'Mobile',
      minWidth: 0,
      designSize: StageSize(width: 390, height: 844),
    ),
  ];

  ComponentDef component(String cid, {String? nested}) => ComponentDef(
    id: cid,
    name: cid,
    root: FrameNode(
      common: NodeCommon(
        id: '${cid}R',
        width: 300,
        height: 80,
        bindings: const {'opacity': TokenRef(variableId: 'vOp')},
      ),
      appearance: const Appearance(
        fills: [Paint.solid(id: 'f0', color: StageColor.white)],
        cornerRadius: CornerRadius.uniform(8),
      ),
      autoLayout: const AutoLayout(gap: Gap.fixed(8)),
      children: [
        ShapeNode(
          common: NodeCommon(
            id: '${cid}I',
            width: 24,
            height: 24,
            componentBindings: const {'visible': 'pShow'},
          ),
        ),
        TextNode(
          common: NodeCommon(
            id: '${cid}L',
            componentBindings: const {'characters': 'pText'},
          ),
          textStyleId: 'tsBody',
          content: const [
            Paragraph(spans: [Span(text: 'Label')]),
          ],
        ),
        if (nested != null)
          InstanceNode(
            common: NodeCommon(id: '${cid}N'),
            source: InstanceSource.component(nested),
          ),
      ],
    ),
    properties: const {
      'pText': ComponentPropDef(
        name: 'Text',
        type: ComponentPropType.text,
        defaultValue: IrValue.string('Hello'),
      ),
      'pShow': ComponentPropDef(
        name: 'Show',
        type: ComponentPropType.boolean,
        defaultValue: IrValue.boolean(true),
      ),
    },
  );

  Node card(int i) {
    if (i % 3 == 0) {
      // A component instance with a text override.
      final cid = i % 2 == 0 ? 'cmpA' : 'cmpB';
      return InstanceNode(
        common: NodeCommon(id: id('in'), x: 4.0 * i),
        source: InstanceSource.component(cid),
        propValues: {'pText': IrValue.string('Card $i')},
        overrides: {
          '${cid}L': {'style.fontWeight': const IrValue.number(700)},
        },
      );
    }
    final cardId = id('card');
    return FrameNode(
      common: NodeCommon(
        id: cardId,
        width: 320,
        height: 200,
        breakpointOverrides: {
          'mobile': {'width': const IrValue.number(160)},
        },
      ),
      appearance: const Appearance(
        fills: [Paint.solid(id: 'f0', color: StageColor.white)],
        effects: [Effect.dropShadow(id: 'e0')],
        cornerRadius: CornerRadius.uniform(12),
      ),
      autoLayout: const AutoLayout(
        direction: LayoutDirection.vertical,
        gap: Gap.fixed(8),
        padding: EdgeInsetsValue(top: 8, left: 8, right: 8, bottom: 8),
      ),
      children: [
        ShapeNode(
          common: NodeCommon(
            id: id('img'),
            width: 300,
            height: 100,
            bindings: const {'opacity': TokenRef(variableId: 'vOp')},
          ),
          appearance: const Appearance(
            fills: [Paint.image(id: 'f0', assetId: 'aImg')],
          ),
        ),
        TextNode(
          common: NodeCommon(id: id('title')),
          textStyleId: 'tsTitle',
          style: const TextStyleOverride(fontWeight: 700),
          content: [
            Paragraph(spans: [Span(text: 'Title $i')]),
          ],
        ),
        TextNode(
          common: NodeCommon(id: id('body')),
          textStyleId: 'tsBody',
          content: [
            Paragraph(
              spans: [
                Span(text: 'Body text for card $i, '),
                const Span(
                  text: 'with emphasis',
                  style: TextStyleOverride(italic: true),
                ),
              ],
            ),
          ],
        ),
        ShapeNode(
          common: NodeCommon(id: id('rule'), width: 300, height: 1),
          appearance: const Appearance(
            fills: [Paint.solid(id: 'f0', color: StageColor.black)],
          ),
        ),
      ],
    );
  }

  Scene scene(int s, int from, int to) {
    final sections = <Node>[];
    const perSection = 6;
    for (var i = from; i < to; i += perSection) {
      sections.add(
        FrameNode(
          common: NodeCommon(id: id('sec'), width: 1440),
          autoLayout: const AutoLayout(wrap: true, gap: Gap.fixed(16)),
          children: [
            for (var c = i; c < i + perSection && c < to; c++) card(c),
          ],
        ),
      );
    }
    final sid = 'sc$s';
    return Scene(
      id: sid,
      name: 'Scene $s',
      kind: SceneKind.flow,
      root: FrameNode(
        common: NodeCommon(id: id('root'), width: 1440, height: 900),
        autoLayout: const AutoLayout(
          direction: LayoutDirection.vertical,
          gap: Gap.fixed(24),
        ),
        children: [
          TextNode(
            common: NodeCommon(id: id('h')),
            textStyleId: 'tsTitle',
            content: [
              Paragraph(spans: [Span(text: 'Chapter $s')]),
            ],
          ),
          ...sections,
        ],
      ),
      clocks: [Clock.sceneScroll(id: 'cl$s', sceneId: sid)],
    );
  }

  final perScene = (cards / scenes).ceil();
  return StageDocument(
    id: 'bench',
    breakpoints: bp,
    baseBreakpointId: 'desktop',
    assets: const {
      'aImg': Asset(id: 'aImg', kind: AssetKind.image, uri: 'asset://i.png'),
    },
    tokens: const TokenSystem(
      collections: [
        VariableCollection(
          id: 'col',
          name: 'Mode',
          modes: [
            TokenMode(id: 'light', name: 'Light'),
            TokenMode(id: 'dark', name: 'Dark'),
          ],
          defaultModeId: 'light',
          variables: [
            Variable(
              id: 'vOp',
              name: 'op',
              type: VariableType.number,
              valuesByMode: {
                'light': IrValue.number(1),
                'dark': IrValue.number(0.8),
              },
            ),
            Variable(
              id: 'vSize',
              name: 'size',
              type: VariableType.number,
              valuesByMode: {'light': IrValue.number(18)},
            ),
          ],
        ),
      ],
      textStyles: {
        'tsTitle': TextStyleDef(
          name: 'Title',
          style: TextStyle(fontSize: 28, fontWeight: 600),
          bindings: {'fontSize': TokenRef(variableId: 'vSize')},
        ),
        'tsBody': TextStyleDef(
          name: 'Body',
          style: TextStyle(fontSize: 16, lineHeight: LineHeight.percent(150)),
        ),
      },
    ),
    components: {
      'cmpA': component('cmpA'),
      'cmpB': component('cmpB', nested: 'cmpA'),
    },
    scenes: [
      for (var s = 0; s < scenes; s++)
        scene(s, s * perScene, (s + 1) * perScene),
    ],
  );
}

/// A bench document whose resolved tree has about [target] nodes.
StageDocument documentOfNodes(int target, {int scenes = 8}) {
  var cards = target ~/ 7;
  for (var i = 0; i < 8; i++) {
    final doc = benchDocument(cards: cards, scenes: scenes);
    final count = resolveDocument(doc).nodeIndex.length;
    if ((count - target).abs() <= target * 0.01) return doc;
    cards = (cards * target / count).round();
  }
  return benchDocument(cards: cards, scenes: scenes);
}

/// [doc] with the opacity of node [nodeId] (a scene-level node) set to
/// [opacity]. Copies only the path from the scene root, so every untouched
/// subtree keeps its identity.
StageDocument withOpacity(StageDocument doc, String nodeId, double opacity) {
  Node? edit(Node n) {
    if (n.id == nodeId) {
      return n.copyWith(common: n.common.copyWith(opacity: opacity));
    }
    if (n is FrameNode) {
      for (var i = 0; i < n.children.length; i++) {
        final c = edit(n.children[i]);
        if (c != null) {
          final children = [...n.children];
          children[i] = c;
          return n.copyWith(children: children);
        }
      }
    }
    return null;
  }

  for (var i = 0; i < doc.scenes.length; i++) {
    final root = edit(doc.scenes[i].root);
    if (root != null) {
      final scenes = [...doc.scenes];
      scenes[i] = doc.scenes[i].copyWith(root: root as FrameNode);
      return doc.copyWith(scenes: scenes);
    }
  }
  throw ArgumentError('No node $nodeId');
}

/// The id of a plain (non-instance) text node near the middle of the document.
String middleTextId(StageDocument doc) {
  final s = doc.scenes[doc.scenes.length ~/ 2];
  final texts = <String>[];
  void walk(Node n) {
    if (n is TextNode) texts.add(n.id);
    if (n is FrameNode) n.children.forEach(walk);
  }

  walk(s.root);
  return texts[texts.length ~/ 2];
}
