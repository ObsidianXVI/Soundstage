import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _red = StageColor(r: 1, g: 0, b: 0);
const _blue = StageColor(r: 0, g: 0, b: 1);
const _green = StageColor(r: 0, g: 1, b: 0);

IrValue _ref(String id) => IrValue.tokenRef(TokenRef(variableId: id));

const _bps = [
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
    designSize: StageSize(width: 390, height: 844),
    primary: true,
  ),
];

/// Collection c1 (modes light, dark): vc colour (red/blue), vn number
/// (8/16), va alias of vc. Collection c2 (mode m): vx colour aliasing vc.
/// Scene s1: frame f1 (fill p1 bound to vc; mobile patch binds opacity to
/// vn... as a number; set-variable action on vn; mode override c1 → dark),
/// text t1 (text style ts1; own fontSize 30), frame f2 (fill style ps1).
/// Track k1 animates f1 opacity with a keyframe bound to vn.
StageDocument _doc() => StageDocument(
  id: 'd',
  breakpoints: _bps,
  tokens: TokenSystem(
    collections: [
      VariableCollection(
        id: 'c1',
        name: 'Theme',
        modes: const [
          TokenMode(id: 'light', name: 'Light'),
          TokenMode(id: 'dark', name: 'Dark'),
        ],
        defaultModeId: 'light',
        breakpointModes: const {'mobile': 'dark'},
        variables: [
          const Variable(
            id: 'vc',
            name: 'color/brand',
            type: VariableType.color,
            valuesByMode: {
              'light': IrValue.color(_red),
              'dark': IrValue.color(_blue),
            },
          ),
          const Variable(
            id: 'vn',
            name: 'space/s',
            type: VariableType.number,
            valuesByMode: {
              'light': IrValue.number(8),
              'dark': IrValue.number(16),
            },
          ),
          Variable(
            id: 'va',
            name: 'color/accent',
            type: VariableType.color,
            valuesByMode: {'light': _ref('vc'), 'dark': _ref('vc')},
          ),
        ],
      ),
      VariableCollection(
        id: 'c2',
        name: 'Other',
        modes: const [TokenMode(id: 'm', name: 'M')],
        defaultModeId: 'm',
        variables: [
          Variable(
            id: 'vx',
            name: 'x',
            type: VariableType.color,
            valuesByMode: {'m': _ref('vc')},
          ),
        ],
      ),
    ],
    textStyles: {
      'ts1': const TextStyleDef(
        name: 'Heading',
        style: TextStyleOverride(fontSize: 48, fontWeight: 700),
        bindings: {'paragraphSpacing': TokenRef(variableId: 'vn')},
      ),
    },
    paintStyles: const {
      'ps1': PaintStyleDef(
        name: 'Brand fill',
        paints: [Paint.solid(id: 'sp', color: _green)],
      ),
    },
  ),
  scenes: [
    Scene(
      id: 's1',
      root: FrameNode(
        common: const NodeCommon(id: 'root', width: 1000, height: 800),
        children: [
          FrameNode(
            common: NodeCommon(
              id: 'f1',
              width: 100,
              height: 100,
              bindings: const {'fills.p1.color': TokenRef(variableId: 'vc')},
              breakpointOverrides: {
                'mobile': {'opacity': _ref('vn')},
              },
              interactions: [
                const Interaction(
                  id: 'i1',
                  trigger: InteractionTrigger.tap(),
                  actions: [
                    Action.setVariable(
                      variableId: 'vn',
                      value: IrValue.number(1),
                    ),
                    Action.openUrl(url: 'https://example.com'),
                  ],
                ),
              ],
            ),
            modeOverrides: const {'c1': 'dark'},
            appearance: const Appearance(
              fills: [Paint.solid(id: 'p1', color: _green)],
            ),
          ),
          const TextNode(
            common: NodeCommon(id: 't1', width: 200, height: 50),
            textStyleId: 'ts1',
            style: TextStyleOverride(fontSize: 30),
            content: [
              Paragraph(spans: [Span(text: 'Hi')]),
            ],
          ),
          const FrameNode(
            common: NodeCommon(id: 'f2', width: 10, height: 10),
            appearance: Appearance(fillStyleId: 'ps1'),
          ),
        ],
      ),
      clocks: const [Clock.sceneScroll(id: 'sc', sceneId: 's1')],
      tracks: [
        Track(
          id: 'k1',
          target: 'f1',
          property: 'opacity',
          clockId: 'sc',
          keyframes: [
            const Keyframe(id: 'a', t: 0, value: IrValue.number(0)),
            Keyframe(id: 'b', t: 1, value: _ref('vn')),
          ],
        ),
      ],
    ),
  ],
);

Variable _var(StageDocument d, String id) => d.tokens.collections
    .expand((c) => c.variables)
    .singleWhere((v) => v.id == id);

VariableCollection _col(StageDocument d, String id) =>
    d.tokens.collections.singleWhere((c) => c.id == id);

Node _node(StageDocument d, String id) => DocumentIndex.of(d).node(id)!;

List<IrDiagnostic> _errors(StageDocument d) =>
    validateDocument(d).where((x) => x.severity == IrSeverity.error).toList();

void main() {
  test('the fixture is valid', () => expect(_errors(_doc()), isEmpty));

  group('collections and variables', () {
    test('add a collection; ids and names must be new', () {
      const c = VariableCollection(
        id: 'c3',
        name: 'Spacing',
        modes: [TokenMode(id: 'm', name: 'Default')],
        defaultModeId: 'm',
      );
      final r = addCollection(_doc(), c);
      expect(r.ok, isTrue);
      expect(r.document.tokens.collections, hasLength(3));
      expect(addCollection(r.document, c).ok, isFalse);
      expect(
        addCollection(_doc(), c.copyWith(id: 'c4', name: 'Theme')).ok,
        isFalse,
      );
      expect(
        addCollection(_doc(), c.copyWith(defaultModeId: 'nope')).ok,
        isFalse,
      );
      expect(addCollection(_doc(), c.copyWith(modes: const [])).ok, isFalse);
    });

    test('variables: names unique per collection, values fit the type', () {
      final doc = _doc();
      expect(
        addVariable(
          doc,
          'c1',
          const Variable(
            id: 'vb',
            name: 'flag',
            type: VariableType.boolean,
            valuesByMode: {'light': IrValue.boolean(true)},
          ),
        ).ok,
        isTrue,
      );
      // Duplicate name in the collection, duplicate id anywhere.
      expect(
        addVariable(
          doc,
          'c1',
          const Variable(id: 'q', name: 'space/s', type: VariableType.number),
        ).ok,
        isFalse,
      );
      expect(
        addVariable(
          doc,
          'c2',
          const Variable(id: 'vn', name: 'new', type: VariableType.number),
        ).ok,
        isFalse,
      );
      // Wrong value type; unknown mode.
      expect(
        setVariableValue(doc, 'vn', 'light', const IrValue.color(_red)).ok,
        isFalse,
      );
      expect(
        setVariableValue(doc, 'vn', 'nope', const IrValue.number(1)).ok,
        isFalse,
      );
      final ok = setVariableValue(doc, 'vn', 'dark', const IrValue.number(24));
      expect(_var(ok.document, 'vn').valuesByMode['dark'], isA<NumberValue>());
    });

    test('aliases: same type, existing target, no cycles', () {
      final doc = _doc();
      expect(setVariableValue(doc, 'vn', 'light', _ref('vc')).ok, isFalse);
      expect(setVariableValue(doc, 'vc', 'light', _ref('ghost')).ok, isFalse);
      final cycle = setVariableValue(doc, 'vc', 'dark', _ref('va'));
      expect(cycle.ok, isFalse);
      expect(cycle.diagnostics.single.kind, IrDiagnosticKind.tokenCycle);
      // Across collections too.
      expect(setVariableValue(doc, 'vc', 'light', _ref('vx')).ok, isFalse);
    });

    test('rename keeps the id; the id cannot change', () {
      final r = updateVariable(_doc(), 'vc', (v) => v.copyWith(name: 'c/x'));
      expect(_var(r.document, 'vc').name, 'c/x');
      expect(
        updateCollection(_doc(), 'c1', (c) => c.copyWith(id: 'z')).ok,
        isFalse,
      );
    });
  });

  group('modes', () {
    test('a new mode copies the default mode values', () {
      final r = addMode(_doc(), 'c1', const TokenMode(id: 'hc', name: 'HC'));
      expect(r.ok, isTrue);
      expect(
        _var(r.document, 'vc').valuesByMode['hc'],
        const IrValue.color(_red),
      );
      expect(_var(r.document, 'va').valuesByMode['hc'], _ref('vc'));
      final dark = addMode(
        _doc(),
        'c1',
        const TokenMode(id: 'hc', name: 'HC'),
        copyFrom: 'dark',
      );
      expect(
        _var(dark.document, 'vn').valuesByMode['hc'],
        const IrValue.number(16),
      );
    });

    test('removing a mode drops its values, breakpoint modes and mode '
        'overrides; the default moves; the last mode stays', () {
      final r = removeMode(_doc(), 'c1', 'dark');
      expect(r.ok, isTrue);
      final c = _col(r.document, 'c1');
      expect(c.modes.map((m) => m.id), ['light']);
      expect(c.breakpointModes, isEmpty);
      expect(_var(r.document, 'vc').valuesByMode.keys, ['light']);
      expect((_node(r.document, 'f1') as FrameNode).modeOverrides, isEmpty);
      expect(_errors(r.document), isEmpty);

      final def = removeMode(_doc(), 'c1', 'light');
      expect(_col(def.document, 'c1').defaultModeId, 'dark');
      expect(removeMode(_doc(), 'c2', 'm').ok, isFalse);
    });

    test('mode overrides on frames and scenes', () {
      var r = setModeOverride(_doc(), 'c1', 'light', nodeId: 'f1');
      expect((_node(r.document, 'f1') as FrameNode).modeOverrides, {
        'c1': 'light',
      });
      r = setModeOverride(r.document, 'c1', null, nodeId: 'f1');
      expect((_node(r.document, 'f1') as FrameNode).modeOverrides, isEmpty);
      r = setModeOverride(r.document, 'c1', 'dark', sceneId: 's1');
      expect(r.document.scenes.single.modeOverrides, {'c1': 'dark'});
      expect(setModeOverride(_doc(), 'c1', 'nope', sceneId: 's1').ok, isFalse);
      expect(setModeOverride(_doc(), 'c1', 'dark', nodeId: 't1').ok, isFalse);
    });
  });

  group('deleting a variable in use', () {
    test('counts its uses', () {
      // vc: f1 binding, va (2 modes), vx.
      expect(variableUseCount(_doc(), 'vc'), 4);
      // vn: mobile patch, set-variable action, keyframe, ts1 binding.
      expect(variableUseCount(_doc(), 'vn'), 4);
      expect(variableUseCount(_doc(), 'va'), 0);
    });

    test('every use is replaced by its value, in one valid edit', () {
      final r = removeVariable(_doc(), 'vn');
      expect(r.ok, isTrue);
      final d = r.document;
      expect(_errors(d), isEmpty);
      final f1 = _node(d, 'f1');
      expect(f1.common.breakpointOverrides['mobile'], {
        'opacity': const IrValue.number(8),
      });
      final actions = f1.common.interactions.single.actions;
      expect(actions.single, isA<OpenUrlAction>());
      expect(
        d.scenes.single.tracks.single.keyframes.last.value,
        const IrValue.number(8),
      );
      final ts = d.tokens.textStyles['ts1']!;
      expect(ts.bindings, isEmpty);
      expect(ts.style.paragraphSpacing, 8);
    });

    test('bindings get the literal; aliases keep their per-mode values', () {
      final r = removeVariable(_doc(), 'vc');
      final d = r.document;
      expect(_errors(d), isEmpty);
      final f1 = _node(d, 'f1') as FrameNode;
      expect(f1.common.bindings, isEmpty);
      expect((f1.appearance.fills.single as SolidPaint).color, _red);
      expect(_var(d, 'va').valuesByMode, {
        'light': const IrValue.color(_red),
        'dark': const IrValue.color(_blue),
      });
      expect(_var(d, 'vx').valuesByMode, {'m': const IrValue.color(_red)});
    });

    test('removing a collection inlines all its variables', () {
      final r = removeCollection(_doc(), 'c1');
      final d = r.document;
      expect(d.tokens.collections.map((c) => c.id), ['c2']);
      expect((_node(d, 'f1') as FrameNode).modeOverrides, isEmpty);
      expect(_errors(d), isEmpty);
    });
  });

  group('styles', () {
    test('names are unique per kind', () {
      final doc = _doc();
      expect(
        setPaintStyle(doc, 'ps2', const PaintStyleDef(name: 'Brand fill')).ok,
        isFalse,
      );
      expect(
        setTextStyle(doc, 'ts2', const TextStyleDef(name: 'Brand fill')).ok,
        isTrue,
      );
      expect(
        setTextStyle(
          doc,
          'ts2',
          const TextStyleDef(
            name: 'Body',
            bindings: {'fontSize': TokenRef(variableId: 'ghost')},
          ),
        ).ok,
        isFalse,
      );
    });

    test('use counts', () {
      expect(styleUseCount(_doc(), StyleKind.text, 'ts1'), 1);
      expect(styleUseCount(_doc(), StyleKind.paint, 'ps1'), 1);
    });

    test('deleting a text style detaches its nodes: style values fill what '
        'the node does not override, bindings move onto the node', () {
      final r = removeStyle(_doc(), StyleKind.text, 'ts1');
      expect(r.ok, isTrue);
      final t1 = _node(r.document, 't1') as TextNode;
      expect(t1.textStyleId, isNull);
      expect(t1.style.fontSize, 30);
      expect(t1.style.fontWeight, 700);
      expect(t1.common.bindings, {
        'style.paragraphSpacing': const TokenRef(variableId: 'vn'),
      });
      expect(r.document.tokens.textStyles, isEmpty);
      expect(_errors(r.document), isEmpty);
    });

    test('deleting a paint style copies its paints in', () {
      final r = removeStyle(_doc(), StyleKind.paint, 'ps1');
      final f2 = _node(r.document, 'f2') as FrameNode;
      expect(f2.appearance.fillStyleId, isNull);
      expect((f2.appearance.fills.single as SolidPaint).color, _green);
      expect(_errors(r.document), isEmpty);
    });
  });

  test('resolution follows breakpoint modes for a bound fill', () {
    final doc = _doc().copyWith(
      scenes: [
        _doc().scenes.single.copyWith(
          root: _doc().scenes.single.root.copyWith(
            children: [
              (_doc().scenes.single.root.children.first as FrameNode).copyWith(
                modeOverrides: const {},
              ),
            ],
          ),
        ),
      ],
    );
    StageColor color(String bp) {
      final tree = resolveDocument(doc, ResolveContext(breakpointId: bp));
      final f1 = tree.scenes.single.root.children.single;
      return ((f1.node as FrameNode).appearance.fills.single as SolidPaint)
          .color;
    }

    expect(color('desktop'), _red);
    expect(color('mobile'), _blue);
  });
}
