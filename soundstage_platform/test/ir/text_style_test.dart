import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _size = StageSize(width: 1000, height: 800);

StageDocument _doc(
  List<Node> children, {
  Map<String, String> modes = const {},
}) {
  return StageDocument(
    id: 'd',
    breakpoints: const [
      Breakpoint(id: 'bp', name: 'Base', minWidth: 0, designSize: _size),
    ],
    baseBreakpointId: 'bp',
    defaultTextStyle: const TextStyle(
      fontSize: 10,
      fontWeight: 300,
      paragraphSpacing: 0,
      textCase: TextCase.lower,
    ),
    tokens: const TokenSystem(
      collections: [
        VariableCollection(
          id: 'col',
          name: 'C',
          modes: [
            TokenMode(id: 'light', name: 'L'),
            TokenMode(id: 'dark', name: 'D'),
          ],
          defaultModeId: 'light',
          variables: [
            Variable(
              id: 'vSize',
              name: 'size',
              type: VariableType.number,
              valuesByMode: {
                'light': IrValue.number(20),
                'dark': IrValue.number(30),
              },
            ),
          ],
        ),
      ],
      textStyles: {
        'tsEmpty': TextStyleDef(name: 'Empty'),
        'named': TextStyleDef(
          name: 'Named',
          style: TextStyleOverride(
            fontSize: 99,
            fontWeight: 500,
            paragraphSpacing: 1,
            textCase: TextCase.upper,
          ),
          bindings: {'fontSize': TokenRef(variableId: 'vSize')},
        ),
      },
    ),
    scenes: [
      Scene(
        id: 's',
        root: FrameNode(
          common: const NodeCommon(id: 'root'),
          modeOverrides: modes,
          children: children,
        ),
      ),
    ],
  );
}

ResolvedNode _find(ResolvedDocument r, String id) =>
    r.scenes.first.root.children.firstWhere((c) => c.id == id);

void main() {
  const spans = [
    Paragraph(
      style: ParagraphStyle(paragraphSpacing: 4),
      spans: [
        Span(text: 'a'),
        Span(text: 'b', style: TextStyleOverride(fontWeight: 700)),
      ],
    ),
  ];

  test('no named style: document default, then node override', () {
    final r = resolveDocument(
      _doc(const [
        TextNode(
          common: NodeCommon(id: 'plain'),
          content: spans,
        ),
        TextNode(
          common: NodeCommon(id: 'over'),
          style: TextStyleOverride(fontSize: 12),
          content: spans,
        ),
      ]),
    );
    final plain = _find(r, 'plain').paragraphs!.single.spans[0].style;
    expect(plain.fontSize, 10);
    expect(plain.fontWeight, 300);
    expect(plain.textCase, TextCase.lower);
    final over = _find(r, 'over').paragraphs!.single.spans[0].style;
    expect(over.fontSize, 12);
    expect(over.fontWeight, 300);
  });

  test(
    'full merge order: default < named (tokens) < node < paragraph < span',
    () {
      final doc = _doc(const [
        TextNode(
          common: NodeCommon(id: 'n'),
          textStyleId: 'named',
          style: TextStyleOverride(fontWeight: 600),
          content: spans,
        ),
      ]);
      final p = _find(resolveDocument(doc), 'n').paragraphs!.single;
      final a = p.spans[0].style;
      final b = p.spans[1].style;
      expect(a.fontSize, 20); // token binding beats the stored 99
      expect(a.textCase, TextCase.upper); // named overrides the default's lower
      expect(a.fontWeight, 600); // node override beats named (500)
      expect(p.paragraphSpacing, 4); // paragraph style beats named (1)
      expect(a.paragraphSpacing, 4);
      expect(b.fontWeight, 700); // span beats node
      expect(b.paragraphSpacing, 4);
    },
  );

  test('a partial named style inherits unset fields from the default', () {
    final doc = _doc(const [
      TextNode(
        common: NodeCommon(id: 'n'),
        textStyleId: 'tsEmpty',
        content: spans,
      ),
      TextNode(
        common: NodeCommon(id: 'm'),
        textStyleId: 'named',
        content: spans,
      ),
    ]);
    final r = resolveDocument(doc);
    final empty = _find(r, 'n').paragraphs!.single.spans[0].style;
    expect(empty.copyWith(paragraphSpacing: 0), doc.defaultTextStyle);
    final named = _find(r, 'm').paragraphs!.single.spans[0].style;
    expect(named.fontWeight, 500); // set by the style
    expect(named.fills, doc.defaultTextStyle.fills); // inherited
    expect(named.fontFamilyId, doc.defaultTextStyle.fontFamilyId);
  });

  test('named-style token bindings resolve in the node modes', () {
    final doc = _doc(
      const [
        TextNode(
          common: NodeCommon(id: 'n'),
          textStyleId: 'named',
          content: spans,
        ),
      ],
      modes: const {'col': 'dark'},
    );
    final s = _find(
      resolveDocument(doc),
      'n',
    ).paragraphs!.single.spans[0].style;
    expect(s.fontSize, 30);
    expect(s.fontWeight, 500);
  });

  test('a missing named style falls back to the default with a diagnostic', () {
    final doc = _doc(const [
      TextNode(
        common: NodeCommon(id: 'n'),
        textStyleId: 'nope',
        content: spans,
      ),
    ]);
    final r = resolveDocument(doc);
    expect(r.diagnostics.map((d) => d.kind), [IrDiagnosticKind.missingStyle]);
    expect(_find(r, 'n').paragraphs!.single.spans[0].style.fontSize, 10);
  });

  test('style.* patches write the override; none clears back to inherit', () {
    const node = TextNode(
      common: NodeCommon(id: 'n'),
      textStyleId: 'named',
      content: spans,
    );
    final diags = <IrDiagnostic>[];
    final set =
        applyPatch(node, {
              'style.fontWeight': const IrValue.number(650),
              'style.fills': const IrValue.paints([
                Paint.solid(id: 'f', color: StageColor.black),
              ]),
            }, diagnostics: diags)
            as TextNode;
    expect(diags, isEmpty);
    expect(set.style.fontWeight, 650);
    expect(set.style.fills, isNotNull);
    expect(
      PropertyRegistry.standard.get(set, 'style.fontWeight'),
      const IrValue.number(650),
    );

    final cleared =
        applyPatch(set, {
              'style.fontWeight': const IrValue.none(),
              'style.fills': const IrValue.none(),
            }, diagnostics: diags)
            as TextNode;
    expect(diags, isEmpty);
    expect(cleared.style, const TextStyleOverride());
    expect(
      PropertyRegistry.standard.get(cleared, 'style.fontWeight'),
      const IrValue.none(),
    );

    // Resolved: the set value wins, the cleared one inherits from named (500).
    expect(
      _find(
        resolveDocument(_doc([set])),
        'n',
      ).paragraphs!.single.spans[0].style.fontWeight,
      650,
    );
    expect(
      _find(
        resolveDocument(_doc([cleared])),
        'n',
      ).paragraphs!.single.spans[0].style.fontWeight,
      500,
    );
  });

  test('a document default round-trips through JSON', () {
    final doc = _doc(const []);
    expect(StageDocument.fromJson(doc.toJson()), doc);
    expect(doc.toJson()['defaultTextStyle'], isA<Map<String, dynamic>>());
  });
}
