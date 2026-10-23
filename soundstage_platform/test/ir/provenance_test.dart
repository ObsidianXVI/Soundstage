import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fuzz/doc_generator.dart';

const _size = StageSize(width: 1000, height: 800);
const _bps = [
  Breakpoint(
    id: 'desktop',
    name: 'D',
    minWidth: 1024,
    designSize: _size,
    primary: true,
  ),
  Breakpoint(
    id: 'mobile',
    name: 'M',
    minWidth: 0,
    designSize: _size,
    primary: true,
  ),
  Breakpoint(
    id: 'tablet',
    name: 'T',
    minWidth: 600,
    designSize: _size,
    inheritsFrom: 'desktop',
  ),
];

const _tokens = TokenSystem(
  collections: [
    VariableCollection(
      id: 'col',
      name: 'Theme',
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
            'light': IrValue.number(0.8),
            'dark': IrValue.number(0.3),
          },
        ),
        Variable(
          id: 'vSize',
          name: 'size',
          type: VariableType.number,
          valuesByMode: {
            'light': IrValue.number(30),
            'dark': IrValue.number(30),
          },
        ),
      ],
    ),
  ],
  paintStyles: {
    'psBrand': PaintStyleDef(
      name: 'Brand',
      paints: [Paint.solid(id: 'p', color: StageColor.white)],
    ),
  },
  textStyles: {
    'tsTitle': TextStyleDef(
      name: 'Title',
      style: TextStyleOverride(fontWeight: 700),
      bindings: {'fontSize': TokenRef(variableId: 'vSize')},
    ),
  },
);

StageDocument _doc() => const StageDocument(
  id: 'doc',
  breakpoints: _bps,
  tokens: _tokens,
  defaultTextStyle: TextStyle(fontSize: 16),
  components: {
    'cmp': ComponentDef(
      id: 'cmp',
      name: 'Card',
      root: FrameNode(
        common: NodeCommon(
          id: 'cmpR',
          x: 5,
          opacity: 0.5,
          breakpointOverrides: {
            'mobile': {'width': IrValue.number(77)},
          },
        ),
        children: [
          ShapeNode(
            common: NodeCommon(
              id: 'cmpI',
              visible: true,
              componentBindings: {'visible': 'pShow'},
            ),
          ),
        ],
      ),
      properties: {
        'pShow': ComponentPropDef(
          name: 'Show',
          type: ComponentPropType.boolean,
          defaultValue: IrValue.boolean(true),
        ),
      },
    ),
  },
  scenes: [
    Scene(
      id: 's',
      root: FrameNode(
        common: NodeCommon(id: 'root', width: 1000, height: 800),
        children: [
          ShapeNode(
            common: NodeCommon(
              id: 'n',
              x: 1,
              breakpointOverrides: {
                'desktop': {'x': IrValue.number(2)},
                'tablet': {'x': IrValue.number(3)},
                'mobile': {
                  'opacity': IrValue.tokenRef(TokenRef(variableId: 'vOp')),
                },
              },
            ),
            appearance: Appearance(
              fills: [Paint.solid(id: 'p', color: StageColor.black)],
              fillStyleId: 'psBrand',
            ),
          ),
          InstanceNode(
            common: NodeCommon(id: 'inst', x: 40, opacity: 0.5),
            source: InstanceSource.component('cmp'),
            propValues: {'pShow': IrValue.boolean(false)},
            overrides: {
              'cmpI': {'opacity': IrValue.number(0.25)},
            },
          ),
          TextNode(
            common: NodeCommon(id: 't'),
            textStyleId: 'tsTitle',
            style: TextStyleOverride(fontWeight: 300),
            content: [
              Paragraph(
                style: ParagraphStyle(paragraphSpacing: 12),
                spans: [
                  Span(text: 'a', style: TextStyleOverride(italic: true)),
                  Span(text: 'b', style: TextStyleOverride(fontWeight: 900)),
                ],
              ),
            ],
          ),
        ],
      ),
    ),
  ],
);

List<ProvenanceSource> _sources(Provenance p) => [
  for (final e in p.entries) e.source,
];
List<IrValue> _values(Provenance p) => [for (final e in p.entries) e.value];

Provenance _explain(String id, String path, {String? bp}) => Resolver().explain(
  _doc(),
  id,
  PropertyPath(path),
  ResolveContext(breakpointId: bp),
);

void main() {
  group('explain', () {
    test('lists each patch along the breakpoint chain', () {
      final p = _explain('n', 'x', bp: 'tablet');
      expect(_sources(p), const [
        ProvenanceSource.base(),
        ProvenanceSource.breakpointPatch('desktop'),
        ProvenanceSource.breakpointPatch('tablet'),
      ]);
      expect(_values(p), const [
        IrValue.number(1),
        IrValue.number(2),
        IrValue.number(3),
      ]);
      expect(p.entries[1].keys, ['x']);
      expect(p.finalValue, const IrValue.number(3));
      // A peer sees only the base.
      expect(_sources(_explain('n', 'x', bp: 'mobile')), const [
        ProvenanceSource.base(),
      ]);
    });

    test('a token bound by a patch', () {
      final p = _explain('n', 'opacity', bp: 'mobile');
      expect(_sources(p), const [
        ProvenanceSource.base(),
        ProvenanceSource.breakpointPatch('mobile'),
        ProvenanceSource.token('vOp', 'light'),
      ]);
      expect(p.finalValue, const IrValue.number(0.8));
    });

    test('a paint style replaces the stack', () {
      final p = _explain('n', 'fills.p.color');
      expect(_sources(p), const [
        ProvenanceSource.base(),
        ProvenanceSource.paintStyle('psBrand'),
      ]);
      expect(p.finalValue, const IrValue.color(StageColor.white));
      // The reference itself reports the style in effect.
      expect(
        _explain('n', 'fillStyleId').finalValue,
        const IrValue.string('psBrand'),
      );
    });

    test('an instance root: component default, then the placed instance', () {
      final x = _explain('inst', 'x', bp: 'mobile');
      expect(_sources(x), const [
        ProvenanceSource.componentDefault('cmp'),
        ProvenanceSource.base(),
      ]);
      expect(x.finalValue, const IrValue.number(40));
      final w = _explain('inst', 'width', bp: 'mobile');
      expect(_sources(w).first, const ProvenanceSource.componentDefault('cmp'));
      final op = _explain('inst', 'opacity');
      expect(_sources(op), const [
        ProvenanceSource.componentDefault('cmp'),
        ProvenanceSource.base(),
        ProvenanceSource.instancePlacement('inst'),
      ]);
      expect(op.finalValue, const IrValue.number(0.25), reason: '0.5 × 0.5');
    });

    test('an instance inner node: binding and override', () {
      final v = _explain('inst/cmpI', 'visible');
      expect(_sources(v), const [
        ProvenanceSource.componentDefault('cmp'),
        ProvenanceSource.componentBinding('pShow', 'inst'),
      ]);
      expect(v.finalValue, const IrValue.boolean(false));
      final op = _explain('inst/cmpI', 'opacity');
      expect(_sources(op), const [
        ProvenanceSource.componentDefault('cmp'),
        ProvenanceSource.instanceOverride('inst', 'cmpI'),
      ]);
      expect(op.entries.last.nodeId, 'inst');
      expect(op.finalValue, const IrValue.number(0.25));
    });

    test('text styles: default → named style (+ token) → node override', () {
      final size = _explain('t', 'style.fontSize');
      expect(_sources(size), const [
        ProvenanceSource.documentDefault(),
        ProvenanceSource.textStyle('tsTitle'),
        ProvenanceSource.token('vSize', 'light'),
      ]);
      expect(size.finalValue, const IrValue.number(30));
      final weight = _explain('t', 'style.fontWeight');
      expect(_sources(weight), const [
        ProvenanceSource.documentDefault(),
        ProvenanceSource.textStyle('tsTitle'),
        ProvenanceSource.base(),
      ]);
      expect(_values(weight).last, const IrValue.number(300));
    });

    test('span styles add the paragraph and span layers', () {
      final w = _explain('t', 'content.0.spans.1.style.fontWeight');
      expect(_sources(w), const [
        ProvenanceSource.documentDefault(),
        ProvenanceSource.textStyle('tsTitle'),
        ProvenanceSource.base(),
        ProvenanceSource.base(),
      ]);
      expect(w.finalValue, const IrValue.number(900));
      final sp = _explain('t', 'content.0.spans.0.style.paragraphSpacing');
      expect(_sources(sp).last, const ProvenanceSource.paragraphStyle(0));
      expect(sp.finalValue, const IrValue.number(12));
    });

    test('unknown nodes and properties never throw', () {
      final p = _explain('zzz', 'x');
      expect(p.entries, isEmpty);
      expect(p.finalValue, isNull);
      expect(p.diagnostics.single.kind, IrDiagnosticKind.missingNode);
      expect(
        _explain('inst/zzz', 'x').diagnostics.single.kind,
        IrDiagnosticKind.missingNode,
      );
      expect(_explain('n', 'nope').finalValue, isNull);
      expect(_explain('n', 'characters').finalValue, isNull);
    });

    test('uses the memo without changing it', () {
      final doc = _doc();
      final resolver = Resolver();
      final first = resolver.resolve(doc);
      final p = resolver.explain(
        doc,
        'inst/cmpI',
        const PropertyPath('opacity'),
      );
      expect(
        p,
        Resolver().explain(doc, 'inst/cmpI', const PropertyPath('opacity')),
      );
      final again = resolver.resolve(doc);
      expect(identical(again.nodeIndex['n'], first.nodeIndex['n']), isTrue);
    });
  });

  test('explain agrees with resolveDocument across the fuzz corpus', () {
    const paths = [
      'name',
      'visible',
      'opacity',
      'x',
      'y',
      'width',
      'height',
      'rotation',
      'flipX',
      'blendMode',
      'role',
      'readingOrder',
      'altText',
      'mask',
      'motion.translateX',
      'motion.scaleY',
      'layoutChild.positioning',
      'layoutChild.maxWidth',
      'clipContent',
      'autoLayout.gap',
      'fills',
      'strokes.weight',
      'effects',
      'cornerRadius',
      'characters',
      'style.fontSize',
      'style.fontWeight',
      'style.fills',
      'style.lineHeight',
      'componentId',
      'propValues.pText',
      'assetId',
      'geometry.pointCount',
    ];
    var checked = 0, withEntries = 0;
    for (var seed = 0; seed < 150; seed++) {
      final doc = DocGen(seed).build();
      final r = Random(seed);
      final bp = doc.breakpoints[r.nextInt(doc.breakpoints.length)].id;
      final ctx = ResolveContext(breakpointId: bp);
      final resolver = Resolver();
      final resolved = resolver.resolve(doc, ctx);
      final ids = resolved.nodeIndex.keys.toList();
      for (var i = 0; i < 25; i++) {
        final id = ids[r.nextInt(ids.length)];
        final rn = resolved.nodeIndex[id]!;
        final candidates = [
          ...paths,
          for (final p in switch (rn.node) {
            FrameNode(:final appearance) ||
            ShapeNode(:final appearance) => appearance.fills,
            _ => const <Paint>[],
          })
            'fills.${p.id}.opacity',
          if (rn.paragraphs case final ps?
              when ps.isNotEmpty && ps[0].spans.isNotEmpty) ...[
            'content.0.spans.0.style.fontSize',
            'content.0.spans.0.style.fills',
          ],
        ];
        final path = candidates[r.nextInt(candidates.length)];
        // Alternate between a memo-backed and a cold resolver.
        final p = (i.isEven ? resolver : Resolver()).explain(
          doc,
          id,
          PropertyPath(path),
          ctx,
        );
        final expected = resolvedPropertyValue(rn, path);
        expect(p.finalValue, expected, reason: 'seed $seed $id $path');
        if (p.entries.isNotEmpty && !rn.isPlaceholder) {
          withEntries++;
          expect(
            p.entries.last.value,
            p.finalValue,
            reason: 'seed $seed $id $path: ${p.entries}',
          );
        }
        if (!path.startsWith('style.') && !path.contains('.style.')) {
          expect(
            p.finalValue,
            rn.node.common.id == id
                ? PropertyRegistry.standard.get(rn.node, path)
                : null,
          );
        }
        checked++;
      }
    }
    expect(checked, 150 * 25);
    expect(withEntries, greaterThan(checked ~/ 2));
  });
}
