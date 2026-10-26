import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _red = StageColor(r: 1, g: 0, b: 0);
const _blue = StageColor(r: 0, g: 0, b: 1);

const _bp = Breakpoint(
  id: 'desk',
  name: 'Desktop',
  minWidth: 0,
  designSize: StageSize(width: 1000, height: 800),
  primary: true,
);

/// Scene s: root > card (frame 200×100 at 50,60, red fill, mobile-ish
/// patch moving x and recolouring) > title (text). Track t1 on title,
/// t2 on card.
StageDocument _doc() => const StageDocument(
  id: 'd',
  breakpoints: [_bp],
  scenes: [
    Scene(
      id: 's',
      root: FrameNode(
        common: NodeCommon(id: 'root', width: 1000, height: 800),
        children: [
          FrameNode(
            common: NodeCommon(
              id: 'card',
              name: 'Card',
              x: 50,
              y: 60,
              width: 200,
              height: 100,
              breakpointOverrides: {
                'desk': {
                  'x': IrValue.number(70),
                  'fills.f.color': IrValue.color(_blue),
                },
              },
            ),
            appearance: Appearance(
              fills: [Paint.solid(id: 'f', color: _red)],
            ),
            children: [
              TextNode(
                common: NodeCommon(id: 'title', width: 100, height: 20),
                content: [
                  Paragraph(spans: [Span(text: 'Hi')]),
                ],
              ),
            ],
          ),
        ],
      ),
      clocks: [Clock.sceneScroll(id: 'c', sceneId: 's')],
      tracks: [
        Track(
          id: 't1',
          target: 'title',
          property: 'opacity',
          clockId: 'c',
          keyframes: [
            Keyframe(id: 'k1', t: 0, value: IrValue.number(0)),
            Keyframe(id: 'k2', t: 1, value: IrValue.number(1)),
          ],
        ),
        Track(
          id: 't2',
          target: 'card',
          property: 'rotation',
          clockId: 'c',
          keyframes: [
            Keyframe(id: 'k3', t: 0, value: IrValue.number(0)),
            Keyframe(id: 'k4', t: 1, value: IrValue.number(10)),
          ],
        ),
      ],
    ),
  ],
);

List<IrDiagnostic> _errors(StageDocument d) =>
    validateDocument(d).where((x) => x.severity == IrSeverity.error).toList();

void main() {
  test('a frame becomes a component; its instance looks the same', () {
    final before = resolveDocument(_doc());
    final r = createComponent(
      _doc(),
      'card',
      componentId: 'comp',
      instanceId: 'inst',
    );
    expect(r.ok, isTrue, reason: '${r.diagnostics}');
    final d = r.document;
    expect(_errors(d), isEmpty);
    final def = d.components['comp']!;
    expect(def.name, 'Card');
    expect(def.root.common.x, 0);
    // Placement patches stay on the instance; the recolour on the main.
    final inst = DocumentIndex.of(d).node('inst')! as InstanceNode;
    expect(inst.common.x, 50);
    expect(inst.common.breakpointOverrides['desk'], {
      'x': const IrValue.number(70),
    });
    expect(def.root.common.breakpointOverrides['desk'], {
      'fills.f.color': const IrValue.color(_blue),
    });
    // Tracks follow.
    final tracks = {for (final t in d.scenes.single.tracks) t.id: t.target};
    expect(tracks, {'t1': 'inst/title', 't2': 'inst'});
    // Same resolved look.
    final after = resolveDocument(d);
    final a = before.nodeIndex['card']!.node as FrameNode;
    final b = after.nodeIndex['inst']!.node as FrameNode;
    expect(b.common.x, a.common.x);
    expect(b.appearance.fills, a.appearance.fills);
    expect(after.nodeIndex['inst/title'], isNotNull);
  });

  test('detaching applies overrides and property values, and tracks '
      'follow the copies', () {
    var d = createComponent(
      _doc(),
      'card',
      componentId: 'comp',
      instanceId: 'inst',
    ).document;
    // A text property bound to the title, set on the instance; an override
    // on the root's fill.
    d = updateComponent(
      d,
      'comp',
      (c) => c.copyWith(
        properties: const {
          'p': ComponentPropDef(
            name: 'Title',
            type: ComponentPropType.text,
            defaultValue: IrValue.string('Default'),
          ),
        },
        root: c.root.copyWith(
          children: [
            (c.root.children.single as TextNode).copyWith(
              common: c.root.children.single.common.copyWith(
                componentBindings: const {'name': 'p'},
              ),
            ),
          ],
        ),
      ),
    ).document;
    d = setInstanceProp(d, 'inst', 'p', const IrValue.string('Bound')).document;
    d = updateNode(
      d,
      'inst',
      (n) => (n as InstanceNode).copyWith(
        overrides: {
          d.components['comp']!.root.id: {
            'fills.f.color': const IrValue.color(_blue),
          },
        },
      ),
    ).document;
    final r = detachInstance(d, 'inst', ids: IdGenerator.forDocument(d));
    expect(r.ok, isTrue, reason: '${r.diagnostics}');
    final out = r.document;
    final rootId = r.createdIds.single;
    final root = DocumentIndex.of(out).node(rootId)! as FrameNode;
    expect(root.common.x, 50);
    expect((root.appearance.fills.single as SolidPaint).color, _blue);
    final title = root.children.single;
    expect(title.common.name, 'Bound');
    expect(title.common.componentBindings, isEmpty);
    final tracks = {for (final t in out.scenes.single.tracks) t.id: t.target};
    expect(tracks['t2'], rootId);
    expect(tracks['t1'], title.id);
    expect(_errors(out), isEmpty);
  });

  test('removing a component detaches its instances', () {
    final d = createComponent(
      _doc(),
      'card',
      componentId: 'comp',
      instanceId: 'inst',
    ).document;
    final r = removeComponent(d, 'comp', ids: IdGenerator.forDocument(d));
    expect(r.ok, isTrue);
    expect(r.document.components, isEmpty);
    expect(DocumentIndex.of(r.document).node('inst'), isNull);
    expect(_errors(r.document), isEmpty);
  });

  test('only a non-root frame can become a component', () {
    expect(
      createComponent(_doc(), 'root', componentId: 'c', instanceId: 'i').ok,
      isFalse,
    );
    expect(
      createComponent(_doc(), 'title', componentId: 'c', instanceId: 'i').ok,
      isFalse,
    );
  });

  test('variants: a copy joins a set; an instance switches to it', () {
    var d = createComponent(
      _doc(),
      'card',
      componentId: 'comp',
      instanceId: 'inst',
    ).document;
    final ids = IdGenerator.forDocument(d);
    final r = addVariant(
      d,
      'comp',
      newComponentId: 'comp2',
      setId: 'set',
      ids: ids,
    );
    expect(r.ok, isTrue);
    d = r.document;
    final set = d.variantSets['set']!;
    expect(set.axes, {
      'Variant': ['Default', 'Variant 2'],
    });
    // The copy has fresh ids; recolour it.
    final copyRoot = d.components['comp2']!.root;
    expect(copyRoot.id, isNot(d.components['comp']!.root.id));
    d = updateComponent(
      d,
      'comp2',
      (c) => c.copyWith(
        root: c.root.copyWith(
          appearance: const Appearance(
            fills: [Paint.solid(id: 'f', color: _blue)],
          ),
          common: c.root.common.copyWith(breakpointOverrides: const {}),
        ),
      ),
    ).document;
    d = setInstanceVariant(d, 'inst', 'set', const {
      'Variant': 'Variant 2',
    }).document;
    final inst = DocumentIndex.of(d).node('inst')! as InstanceNode;
    expect(instanceComponentId(d, inst), 'comp2');
    final shown = resolveDocument(d).nodeIndex['inst']!.node as FrameNode;
    expect((shown.appearance.fills.single as SolidPaint).color, _blue);
    expect(_errors(d), isEmpty);
  });
}
