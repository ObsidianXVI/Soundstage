import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fuzz/mutations.dart';

const _bps = [
  Breakpoint(
    id: 'd',
    name: 'D',
    minWidth: 600,
    designSize: StageSize(width: 1000, height: 800),
  ),
  Breakpoint(
    id: 'm',
    name: 'M',
    minWidth: 0,
    designSize: StageSize(width: 400, height: 800),
  ),
];

StageDocument _doc({double dark = 0.4}) => StageDocument(
  id: 'd',
  breakpoints: _bps,
  baseBreakpointId: 'd',
  assets: const {},
  tokens: TokenSystem(
    collections: [
      VariableCollection(
        id: 'col',
        name: 'Mode',
        modes: const [
          TokenMode(id: 'light', name: 'L'),
          TokenMode(id: 'dark', name: 'D'),
        ],
        defaultModeId: 'light',
        variables: [
          Variable(
            id: 'vOp',
            name: 'op',
            type: VariableType.number,
            valuesByMode: {
              'light': const IrValue.number(0.9),
              'dark': IrValue.number(dark),
            },
          ),
        ],
      ),
    ],
  ),
  scenes: [
    const Scene(
      id: 's',
      root: FrameNode(
        common: NodeCommon(id: 'root'),
        children: [
          FrameNode(
            common: NodeCommon(id: 'a'),
            children: [
              ShapeNode(
                common: NodeCommon(
                  id: 'a1',
                  bindings: {'opacity': TokenRef(variableId: 'vOp')},
                ),
              ),
              ShapeNode(
                common: NodeCommon(id: 'a2', width: 5),
                appearance: Appearance(
                  fills: [Paint.image(id: 'f', assetId: 'missing')],
                ),
              ),
            ],
          ),
          FrameNode(
            common: NodeCommon(id: 'b'),
            children: [ShapeNode(common: NodeCommon(id: 'b1'))],
          ),
        ],
      ),
    ),
  ],
);

ResolvedNode _n(ResolvedDocument d, String id) => d.nodeIndex[id]!;

void main() {
  test('an edit re-resolves only the path; other subtrees keep identity', () {
    final doc = _doc();
    final resolver = Resolver();
    final first = resolver.resolve(doc);
    final edited = editNode(
      doc,
      'b1',
      (n) => n.copyWith(common: n.common.copyWith(opacity: 0.5)),
    )!;
    final second = resolver.resolve(edited);

    expect(identical(_n(second, 'a'), _n(first, 'a')), isTrue);
    expect(identical(_n(second, 'a1'), _n(first, 'a1')), isTrue);
    expect(identical(_n(second, 'b'), _n(first, 'b')), isFalse);
    expect(_n(second, 'b1').node.common.opacity, 0.5);
    expect(second, Resolver().resolve(edited));
  });

  test('diagnostics of reused subtrees are replayed in order', () {
    final doc = _doc();
    final resolver = Resolver();
    final first = resolver.resolve(doc);
    expect(first.diagnostics.map((d) => d.kind), [
      IrDiagnosticKind.missingAsset,
    ]);
    final edited = editNode(
      doc,
      'b1',
      (n) => n.copyWith(common: n.common.copyWith(x: 3)),
    )!;
    final second = resolver.resolve(edited);
    expect(second.diagnostics, first.diagnostics);
    // And once more, reusing the second pass's memo.
    expect(resolver.resolve(edited).diagnostics, first.diagnostics);
  });

  test('the same node under different modes is resolved afresh', () {
    final doc = _doc();
    final resolver = Resolver();
    final light = resolver.resolve(doc);
    expect(_n(light, 'a1').node.common.opacity, 0.9);
    // Only the parent changes (modeOverrides); a1 is the identical object.
    final dark = editNode(
      doc,
      'a',
      (n) => (n as FrameNode).copyWith(modeOverrides: {'col': 'dark'}),
    )!;
    final out = resolver.resolve(dark);
    expect(_n(out, 'a1').node.common.opacity, 0.4);
    expect(out, Resolver().resolve(dark));
    // Back to light: the earlier result is not stale.
    expect(_n(resolver.resolve(doc), 'a1').node.common.opacity, 0.9);
  });

  test('changing a shared input resets the memo', () {
    final resolver = Resolver();
    expect(_n(resolver.resolve(_doc()), 'a1').node.common.opacity, 0.9);
    // A token edit: every dependent must see the new value. Use a document
    // whose structure is shared but whose tokens differ.
    final base = _doc();
    final changedTokens = base.copyWith(
      tokens: _doc(dark: 0.1).tokens.copyWith(
        collections: [
          _doc().tokens.collections.first.copyWith(
            defaultModeId: 'dark',
            variables: [
              const Variable(
                id: 'vOp',
                name: 'op',
                type: VariableType.number,
                valuesByMode: {
                  'light': IrValue.number(0.9),
                  'dark': IrValue.number(0.1),
                },
              ),
            ],
          ),
        ],
      ),
    );
    final out = resolver.resolve(changedTokens);
    expect(_n(out, 'a1').node.common.opacity, 0.1);
    expect(out, Resolver().resolve(changedTokens));

    // Assets: adding the missing asset removes the diagnostic.
    final withAsset = changedTokens.copyWith(
      assets: {
        'missing': const Asset(id: 'missing', kind: AssetKind.image, uri: 'x'),
      },
    );
    expect(resolver.resolve(changedTokens).diagnostics, isNotEmpty);
    expect(resolver.resolve(withAsset).diagnostics, isEmpty);
  });

  test('a different context resolves afresh', () {
    final doc = _doc();
    final resolver = Resolver();
    final desktop = resolver.resolve(doc);
    final mobile = resolver.resolve(
      doc,
      const ResolveContext(breakpointId: 'm'),
    );
    expect(mobile.breakpoint!.id, 'm');
    expect(desktop.breakpoint!.id, 'd');
    final dark = resolver.resolve(
      doc,
      const ResolveContext(modeState: {'col': 'dark'}),
    );
    expect(_n(dark, 'a1').node.common.opacity, 0.4);
  });

  test('only the previous pass is kept (no unbounded growth)', () {
    final resolver = Resolver();
    var doc = _doc();
    for (var i = 0; i < 20; i++) {
      doc = editNode(
        doc,
        'b1',
        (n) => n.copyWith(common: n.common.copyWith(x: i.toDouble())),
      )!;
      resolver.resolve(doc);
    }
    // Resolving an unrelated, much older document still works (and is right).
    expect(resolver.resolve(_doc()), Resolver().resolve(_doc()));
  });
}
