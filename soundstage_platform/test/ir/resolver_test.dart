import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const red = StageColor(r: 1, g: 0, b: 0);
const blue = StageColor(r: 0, g: 0, b: 1);
const green = StageColor(r: 0, g: 1, b: 0);

const size = StageSize(width: 1000, height: 800);
const breakpoints = [
  Breakpoint(id: 'desktop', name: 'Desktop', minWidth: 1024, designSize: size),
  Breakpoint(id: 'tablet', name: 'Tablet', minWidth: 600, designSize: size),
  Breakpoint(id: 'mobile', name: 'Mobile', minWidth: 0, designSize: size),
];

TokenRef ref(String id) => TokenRef(variableId: id);
NodeCommon c(
  String id, {
  double x = 0,
  double width = 0,
  double opacity = 1,
  Map<String, Patch> bp = const {},
  Map<String, TokenRef> bindings = const {},
  Map<String, String> props = const {},
}) => NodeCommon(
  id: id,
  x: x,
  width: width,
  opacity: opacity,
  breakpointOverrides: bp,
  bindings: bindings,
  componentBindings: props,
);

TextNode text(String id, String s, {Map<String, String> props = const {}}) =>
    TextNode(
      common: c(id, props: props),
      content: [
        Paragraph(spans: [Span(text: s)]),
      ],
    );

FrameNode frame(String id, List<Node> children, {double width = 0}) =>
    FrameNode(
      common: c(id, width: width),
      children: children,
    );

InstanceNode instance(
  String id,
  String componentId, {
  Map<String, IrValue> props = const {},
  Map<String, Patch> overrides = const {},
  double x = 0,
  double width = 0,
  Map<String, Patch> bp = const {},
}) => InstanceNode(
  common: c(id, x: x, width: width, bp: bp),
  source: InstanceSource.component(componentId),
  propValues: props,
  overrides: overrides,
);

final tokens = TokenSystem(
  collections: [
    const VariableCollection(
      id: 'cSpace',
      name: 'Spacing',
      modes: [
        TokenMode(id: 'roomy', name: 'Roomy'),
        TokenMode(id: 'compact', name: 'Compact'),
      ],
      defaultModeId: 'roomy',
      breakpointModes: {'mobile': 'compact'},
      variables: [
        Variable(
          id: 'vGap',
          name: 'space/gap',
          type: VariableType.number,
          valuesByMode: {
            'roomy': IrValue.number(24),
            'compact': IrValue.number(12),
          },
        ),
      ],
    ),
    VariableCollection(
      id: 'cTheme',
      name: 'Theme',
      modes: const [
        TokenMode(id: 'light', name: 'Light'),
        TokenMode(id: 'dark', name: 'Dark'),
      ],
      defaultModeId: 'light',
      variables: [
        const Variable(
          id: 'vBrand',
          name: 'color/brand',
          type: VariableType.color,
          valuesByMode: {
            'light': IrValue.color(red),
            'dark': IrValue.color(blue),
          },
        ),
        Variable(
          id: 'vAlias',
          name: 'color/alias',
          type: VariableType.color,
          valuesByMode: {'light': IrValue.tokenRef(ref('vBrand'))},
        ),
        Variable(
          id: 'vAlias2',
          name: 'color/alias2',
          type: VariableType.color,
          valuesByMode: {'light': IrValue.tokenRef(ref('vAlias'))},
        ),
        Variable(
          id: 'vCycA',
          name: 'cyc/a',
          type: VariableType.number,
          valuesByMode: {'light': IrValue.tokenRef(ref('vCycB'))},
        ),
        Variable(
          id: 'vCycB',
          name: 'cyc/b',
          type: VariableType.number,
          valuesByMode: {'light': IrValue.tokenRef(ref('vCycA'))},
        ),
      ],
    ),
  ],
  textStyles: {
    'tsBody': TextStyleDef(
      name: 'Body',
      style: const TextStyle(fontSize: 18, fontWeight: 500),
      bindings: {'fills.text.color': ref('vBrand')},
    ),
  },
  paintStyles: const {
    'psBrand': PaintStyleDef(
      name: 'Brand',
      paints: [Paint.solid(id: 'ps', color: green)],
    ),
  },
  effectStyles: const {
    'esShadow': EffectStyleDef(
      name: 'Shadow',
      effects: [Effect.dropShadow(id: 'sh')],
    ),
  },
);

final components = <String, ComponentDef>{
  'cButton': ComponentDef(
    id: 'cButton',
    name: 'Button',
    root: FrameNode(
      common: c('bRoot', width: 100, opacity: 0.5),
      appearance: const Appearance(
        fills: [Paint.solid(id: 'bg', color: red)],
      ),
      children: [
        text('bLabel', 'Button', props: {'characters': 'pLabel'}),
        FrameNode(
          common: c(
            'bIcon',
            props: {'visible': 'pIcon', 'fills.img.assetId': 'pImg'},
          ),
          appearance: const Appearance(
            fills: [Paint.image(id: 'img', assetId: 'aDefault')],
          ),
        ),
      ],
    ),
    properties: const {
      'pLabel': ComponentPropDef(
        name: 'Label',
        type: ComponentPropType.text,
        defaultValue: IrValue.string('Button'),
      ),
      'pIcon': ComponentPropDef(
        name: 'Icon',
        type: ComponentPropType.boolean,
        defaultValue: IrValue.boolean(true),
      ),
      'pImg': ComponentPropDef(
        name: 'Image',
        type: ComponentPropType.asset,
        defaultValue: IrValue.string('aDefault'),
      ),
    },
  ),
  'cButtonSmall': ComponentDef(
    id: 'cButtonSmall',
    name: 'Button/Small',
    root: frame('sRoot', [text('sLabel', 'Small')], width: 50),
  ),
  'cCard': ComponentDef(
    id: 'cCard',
    name: 'Card',
    root: frame('cRoot', [
      text('cTitle', 'Title'),
      instance(
        'cBtn',
        'cButton',
        props: {'pLabel': const IrValue.string('Card')},
      ),
    ]),
  ),
  'cLoopA': ComponentDef(
    id: 'cLoopA',
    name: 'A',
    root: frame('aRoot', [instance('aInner', 'cLoopB')]),
  ),
  'cLoopB': ComponentDef(
    id: 'cLoopB',
    name: 'B',
    root: frame('bRoot2', [instance('bInner', 'cLoopA')]),
  ),
};

const variantSets = {
  'vsBtn': VariantSet(
    id: 'vsBtn',
    name: 'Button',
    axes: {
      'size': ['large', 'small'],
    },
    variants: [
      Variant(componentId: 'cButton', values: {'size': 'large'}),
      Variant(componentId: 'cButtonSmall', values: {'size': 'small'}),
    ],
  ),
};

ShapeNode shape(
  String id, {
  Map<String, TokenRef> bindings = const {},
  Map<String, Patch> bp = const {},
  Appearance appearance = const Appearance(
    fills: [Paint.solid(id: 'f', color: StageColor.black)],
  ),
}) => ShapeNode(
  common: c(id, bindings: bindings, bp: bp),
  appearance: appearance,
);

StageDocument buildDoc() => StageDocument(
  id: 'doc',
  breakpoints: breakpoints,
  baseBreakpointId: 'desktop',
  tokens: tokens,
  components: components,
  variantSets: variantSets,
  assets: const {
    'aDefault': Asset(
      id: 'aDefault',
      kind: AssetKind.image,
      uri: 'asset://a.png',
    ),
    'aHero': Asset(id: 'aHero', kind: AssetKind.image, uri: 'asset://h.png'),
  },
  scenes: [
    Scene(
      id: 's1',
      root: frame('root', [
        instance(
          'i1',
          'cButton',
          x: 10,
          width: 200,
          props: const {
            'pLabel': IrValue.string('Go'),
            'pIcon': IrValue.boolean(false),
            'pImg': IrValue.string('aHero'),
          },
          overrides: const {
            'bLabel': {'style.fontSize': IrValue.number(30)},
            'bRoot': {'fills.bg.color': IrValue.color(blue)},
          },
        ),
        instance(
          'i2',
          'cCard',
          overrides: const {
            'cBtn': {'propValues.pLabel': IrValue.string('Outer')},
            'cBtn/bLabel': {'style.fontSize': IrValue.number(40)},
          },
        ),
        const InstanceNode(
          common: NodeCommon(id: 'iv'),
          source: InstanceSource.variant(
            variantSetId: 'vsBtn',
            variantValues: {'size': 'small'},
          ),
        ),
        const InstanceNode(
          common: NodeCommon(id: 'ivBad'),
          source: InstanceSource.variant(
            variantSetId: 'vsBtn',
            variantValues: {'size': 'xl'},
          ),
        ),
        instance('iLoop', 'cLoopA'),
        instance('iMissing', 'nope', x: 7),
        FrameNode(
          common: c('gapFrame', bindings: {'autoLayout.gap': ref('vGap')}),
          autoLayout: const AutoLayout(),
        ),
        FrameNode(
          common: c('themed'),
          modeOverrides: const {'cTheme': 'dark'},
          children: [
            shape('sh', bindings: {'fills.f.color': ref('vAlias2')}),
          ],
        ),
        shape('sh2', bindings: {'fills.f.color': ref('vAlias2')}),
        shape('cyc', bindings: {'opacity': ref('vCycA')}),
        shape('missTok', bindings: {'opacity': ref('vNope')}),
        TextNode(
          common: c(
            'txt',
            bp: const {
              'mobile': {
                'style.letterSpacing': IrValue.letterSpacing(
                  LetterSpacing.px(2),
                ),
              },
            },
          ),
          textStyleId: 'tsBody',
          style: const TextStyleOverride(fontSize: 12),
          content: const [
            Paragraph(
              style: ParagraphStyle(
                alignHorizontal: TextAlignHorizontal.right,
                paragraphSpacing: 8,
              ),
              spans: [
                Span(text: 'Plain '),
                Span(text: 'bold', style: TextStyleOverride(fontWeight: 700)),
              ],
            ),
          ],
        ),
        shape(
          'styled',
          appearance: const Appearance(
            fills: [Paint.solid(id: 'local', color: StageColor.black)],
            fillStyleId: 'psBrand',
            effectStyleId: 'esShadow',
          ),
        ),
        shape('badStyle', appearance: const Appearance(fillStyleId: 'psNope')),
        shape(
          'bpNode',
          bp: const {
            'tablet': {'x': IrValue.number(10), 'y': IrValue.number(5)},
            'mobile': {'x': IrValue.number(20), 'nope.path': IrValue.number(1)},
            'desktop': {'x': IrValue.number(999)}, // base patch: never applied
          },
        ),
        shape(
          'gone',
          appearance: const Appearance(
            fills: [Paint.image(id: 'g', assetId: 'aGone')],
          ),
        ),
      ]),
      tracks: [
        Track(
          id: 't1',
          target: 'i1/bLabel',
          property: 'opacity',
          clockId: 'clk',
          keyframes: [
            Keyframe(id: 'k2', t: 1, value: IrValue.tokenRef(ref('vGap'))),
            const Keyframe(id: 'k1', t: 0, value: IrValue.number(0)),
          ],
        ),
        const Track(
          id: 't2',
          target: 'nope',
          property: 'opacity',
          clockId: 'clk',
        ),
        const Track(
          id: 't3',
          target: 'sh2',
          property: 'opacity',
          clockId: 'clk',
          breakpoints: ['mobile'],
        ),
        const Track(
          id: 't4',
          target: 'sh2',
          property: 'style.fontSize',
          clockId: 'clk',
        ),
      ],
    ),
  ],
);

ResolvedDocument resolveAt(String bp, {ResolveContext? ctx}) => resolveDocument(
  buildDoc(),
  (ctx ?? const ResolveContext()).copyWith(breakpointId: bp),
);

T nodeOf<T extends Node>(ResolvedDocument d, String id) =>
    d.nodeIndex[id]!.node as T;

List<IrDiagnosticKind> kinds(ResolvedDocument d) => [
  for (final x in d.diagnostics) x.kind,
];

void main() {
  final desktop = resolveAt('desktop');
  final mobile = resolveAt('mobile');

  group('instances', () {
    test('expand to the component root under the instance id', () {
      final i1 = desktop.nodeIndex['i1']!;
      expect(i1.node, isA<FrameNode>());
      expect(i1.node.id, 'i1');
      expect(i1.sourceComponentId, 'cButton');
      expect(i1.instanceId, 'i1');
      expect([for (final ch in i1.children) ch.id], ['i1/bLabel', 'i1/bIcon']);
      // Placement from the instance; opacity multiplies.
      expect(i1.node.common.x, 10);
      expect(i1.node.common.width, 200);
      expect(i1.node.common.opacity, 0.5);
    });

    test('text, boolean and asset props drive bindings; overrides apply', () {
      final label = desktop.nodeIndex['i1/bLabel']!;
      expect(label.paragraphs!.single.spans.single.text, 'Go');
      expect(label.paragraphs!.single.spans.single.style.fontSize, 30);
      final icon = nodeOf<FrameNode>(desktop, 'i1/bIcon');
      expect(icon.common.visible, isFalse);
      expect((icon.appearance.fills.single as ImagePaint).assetId, 'aHero');
      // Root override, addressed by the component root id.
      expect(
        (nodeOf<FrameNode>(desktop, 'i1').appearance.fills.single as SolidPaint)
            .color,
        blue,
      );
      // Prop defaults apply when the instance does not set them.
      expect(desktop.nodeIndex['i2/cBtn/bIcon']!.node.common.visible, isTrue);
    });

    test('nested instances are namespaced; outer overrides win', () {
      final btn = desktop.nodeIndex['i2/cBtn']!;
      expect(btn.sourceComponentId, 'cButton');
      expect(btn.instanceId, 'i2/cBtn');
      expect(desktop.nodeIndex['i2/cTitle']!.instanceId, 'i2');
      final label = desktop.nodeIndex['i2/cBtn/bLabel']!;
      expect(label.paragraphs!.single.spans.single.text, 'Outer');
      expect(label.instanceId, 'i2/cBtn');
    });

    test('variant selection', () {
      expect(desktop.nodeIndex['iv']!.sourceComponentId, 'cButtonSmall');
      expect(desktop.nodeIndex['iv/sLabel'], isNotNull);
      // No exact match: closest variant (axis defaults) plus a diagnostic.
      expect(desktop.nodeIndex['ivBad']!.sourceComponentId, isNotNull);
      expect(
        desktop.diagnostics.where(
          (d) =>
              d.kind == IrDiagnosticKind.missingVariant && d.nodeId == 'ivBad',
        ),
        hasLength(1),
      );
    });

    test('component cycles become placeholders with a diagnostic', () {
      final cyc = desktop.diagnostics.singleWhere(
        (d) => d.kind == IrDiagnosticKind.componentCycle,
      );
      expect(cyc.nodeId, 'iLoop/aInner/bInner');
      expect(cyc.message, contains('cLoopA → cLoopB → cLoopA'));
      final p = desktop.nodeIndex['iLoop/aInner/bInner']!;
      expect(p.isPlaceholder, isTrue);
      expect(p.children, isEmpty);
    });

    test('missing components become placeholders keeping placement', () {
      final m = desktop.nodeIndex['iMissing']!;
      expect(m.isPlaceholder, isTrue);
      expect(m.node.common.x, 7);
      expect(
        desktop.diagnostics
            .where((d) => d.kind == IrDiagnosticKind.missingComponent)
            .single
            .nodeId,
        'iMissing',
      );
    });
  });

  group('breakpoints', () {
    test('patches cascade from the base in order', () {
      expect(desktop.breakpoint!.id, 'desktop');
      expect(nodeOf<ShapeNode>(desktop, 'bpNode').common.x, 0);
      final tablet = resolveAt('tablet');
      expect(
        (
          nodeOf<ShapeNode>(tablet, 'bpNode').common.x,
          nodeOf<ShapeNode>(tablet, 'bpNode').common.y,
        ),
        (10.0, 5.0),
      );
      expect(
        (
          nodeOf<ShapeNode>(mobile, 'bpNode').common.x,
          nodeOf<ShapeNode>(mobile, 'bpNode').common.y,
        ),
        (20.0, 5.0),
      );
      expect(
        mobile.diagnostics
            .where(
              (d) =>
                  d.kind == IrDiagnosticKind.unknownPath &&
                  d.path == 'nope.path',
            )
            .single
            .nodeId,
        'bpNode',
      );
    });

    test('viewport width picks the breakpoint', () {
      final d = resolveDocument(
        buildDoc(),
        const ResolveContext(viewportWidth: 390),
      );
      expect(d.breakpoint!.id, 'mobile');
      final none = resolveDocument(buildDoc());
      expect(none.breakpoint!.id, 'desktop');
    });

    test('an unknown breakpoint id is a diagnostic, not a throw', () {
      final d = resolveDocument(
        buildDoc(),
        const ResolveContext(breakpointId: 'bogus', viewportWidth: 700),
      );
      expect(d.breakpoint!.id, 'tablet');
      expect(kinds(d), contains(IrDiagnosticKind.missingBreakpoint));
    });
  });

  group('modes and tokens', () {
    test('breakpointModes switch a spacing token', () {
      expect(
        nodeOf<FrameNode>(desktop, 'gapFrame').autoLayout!.gap,
        const Gap.fixed(24),
      );
      expect(
        nodeOf<FrameNode>(mobile, 'gapFrame').autoLayout!.gap,
        const Gap.fixed(12),
      );
      expect(mobile.nodeIndex['gapFrame']!.modes['cSpace'], 'compact');
    });

    SolidPaint fill(ResolvedDocument d, String id) =>
        nodeOf<ShapeNode>(d, id).appearance.fills.single as SolidPaint;

    test('frame modeOverrides scope to the frame subtree; aliases chain', () {
      expect(
        fill(desktop, 'sh').color,
        blue,
      ); // vAlias2 → vAlias → vBrand (dark)
      expect(desktop.nodeIndex['sh']!.modes['cTheme'], 'dark');
      expect(fill(desktop, 'sh2').color, red); // outside the dark frame
      expect(desktop.nodeIndex['sh2']!.modes['cTheme'], 'light');
    });

    test('state has the highest priority', () {
      final d = resolveAt(
        'desktop',
        ctx: const ResolveContext(modeState: {'cTheme': 'dark'}),
      );
      expect(fill(d, 'sh2').color, blue);
      final v = resolveAt(
        'desktop',
        ctx: const ResolveContext(
          variableState: {'vBrand': IrValue.color(green)},
        ),
      );
      expect(fill(v, 'sh').color, green);
      expect(fill(v, 'sh2').color, green);
    });

    test('alias cycles and missing tokens are diagnostics', () {
      final cyc = desktop.diagnostics.singleWhere(
        (d) => d.kind == IrDiagnosticKind.tokenCycle,
      );
      expect((cyc.nodeId, cyc.path), ('cyc', 'opacity'));
      expect(nodeOf<ShapeNode>(desktop, 'cyc').common.opacity, 1); // unchanged
      final miss = desktop.diagnostics.where(
        (d) => d.kind == IrDiagnosticKind.missingToken,
      );
      expect(miss.map((d) => d.nodeId), contains('missTok'));
    });

    test(
      'keyframe token refs resolve in the target scope; tracks are cleaned',
      () {
        final tracks = desktop.scenes.single.tracks;
        expect(tracks.map((t) => t.id), [
          't1',
        ]); // t2 missing, t3 mobile-only, t4 inapplicable
        final t1 = tracks.single;
        expect(t1.target, 'i1/bLabel');
        expect(t1.keyframes.map((k) => k.t), [0, 1]); // sorted
        expect(t1.keyframes.last.value, const IrValue.number(24));
        final m = mobile.scenes.single.tracks;
        expect(m.map((t) => t.id), ['t1', 't3']);
        expect(m.first.keyframes.last.value, const IrValue.number(12));
        expect(
          kinds(desktop),
          containsAll([
            IrDiagnosticKind.missingTrackTarget,
            IrDiagnosticKind.inapplicablePath,
          ]),
        );
      },
    );
  });

  group('styles', () {
    test('node override beats the named style; spans are fully merged', () {
      final t = desktop.nodeIndex['txt']!;
      final p = t.paragraphs!.single;
      final base = p.spans[0].style;
      expect(base.fontSize, 12); // node override beats the named style (18)
      expect(base.fontWeight, 500); // from the named style
      expect(
        (base.fills.single as SolidPaint).color,
        red,
      ); // token-bound style field
      expect(p.alignHorizontal, TextAlignHorizontal.right);
      expect(p.paragraphSpacing, 8);
      expect(p.spans[0].style.fontWeight, 500);
      expect(p.spans[1].style.fontWeight, 700);
      expect(p.spans[1].style.paragraphSpacing, 8);
      // The resolved node carries no style references; paragraphs are the result.
      expect((t.node as TextNode).textStyleId, isNull);
      expect((t.node as TextNode).style, const TextStyleOverride());
      // At mobile a patched value is written into the node override.
      final m = mobile.nodeIndex['txt']!;
      expect(
        m.paragraphs!.single.spans[0].style.letterSpacing,
        const LetterSpacing.px(2),
      );
      expect(
        m.paragraphs!.single.spans[1].style.letterSpacing,
        const LetterSpacing.px(2),
      );
    });

    test('paint and effect styles replace the local stacks', () {
      final a = nodeOf<ShapeNode>(desktop, 'styled').appearance;
      expect(a.fills, tokens.paintStyles['psBrand']!.paints);
      expect(a.effects, tokens.effectStyles['esShadow']!.effects);
      expect((a.fillStyleId, a.effectStyleId), (null, null));
      expect(
        desktop.diagnostics
            .where((d) => d.kind == IrDiagnosticKind.missingStyle)
            .single
            .nodeId,
        'badStyle',
      );
    });
  });

  group('output', () {
    test('only concrete values', () {
      for (final n in desktop.nodeIndex.values) {
        expect(n.node, isNot(isA<InstanceNode>()));
        expect(n.node.id, n.id);
        expect(n.node.common.breakpointOverrides, isEmpty);
        expect(n.node.common.bindings, isEmpty);
        expect(n.node.common.componentBindings, isEmpty);
        if (n.node case final FrameNode f) {
          expect(f.children, isEmpty);
          expect(f.appearance.fillStyleId, isNull);
        }
        expect(n.paragraphs != null, n.node is TextNode);
      }
      for (final t in desktop.scenes.single.tracks) {
        expect(t.keyframes.every((k) => k.value is! TokenRefValue), isTrue);
      }
    });

    test('missing assets are reported', () {
      expect(
        desktop.diagnostics
            .where((d) => d.kind == IrDiagnosticKind.missingAsset)
            .map((d) => (d.nodeId, d.path)),
        [('gone', 'fills.g.assetId')],
      );
    });

    test('deterministic', () {
      expect(resolveAt('mobile'), resolveAt('mobile'));
    });

    test('broken documents never throw', () {
      final empty = resolveDocument(
        const StageDocument(id: 'x', breakpoints: [], baseBreakpointId: 'gone'),
      );
      expect(empty.breakpoint, isNull);
      final dangling = resolveDocument(
        buildDoc().copyWith(
          baseBreakpointId: 'gone',
          components: const {},
          tokens: const TokenSystem(),
        ),
      );
      expect(
        kinds(dangling),
        containsAll([
          IrDiagnosticKind.missingBreakpoint,
          IrDiagnosticKind.missingComponent,
        ]),
      );
      expect(dangling.scenes.single.root.children, isNotEmpty);
    });

    test('overlay is resolved and indexed', () {
      final d = resolveDocument(
        buildDoc().copyWith(overlay: frame('ov', [text('ovT', 'x')])),
      );
      expect(d.overlay!.id, 'ov');
      expect(d.nodeIndex['ovT'], isNotNull);
    });
  });

  test('selectVariant', () {
    final set = variantSets['vsBtn']!;
    expect(
      selectVariant(set, const {})!.variant.componentId,
      'cButton',
    ); // axis default
    expect(selectVariant(set, const {'size': 'small'})!.exact, isTrue);
    expect(selectVariant(set, const {'size': 'xl'})!.exact, isFalse);
    expect(
      selectVariant(const VariantSet(id: 'e', name: 'e'), const {}),
      isNull,
    );
  });
}
