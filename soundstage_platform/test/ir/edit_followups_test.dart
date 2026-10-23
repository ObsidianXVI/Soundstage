// T1.0 follow-ups (DECISIONS 23/10/26): removeNodes cascades, moveNodes
// copies clocks across scenes and keeps visual positions.
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

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
    designSize: StageSize(width: 400, height: 800),
    primary: true,
  ),
];

ShapeNode _shape(
  String id, {
  double x = 0,
  double y = 0,
  double w = 10,
  List<Interaction> interactions = const [],
  Map<String, Patch> patches = const {},
  LayoutChild layoutChild = const LayoutChild(),
}) => ShapeNode(
  common: NodeCommon(
    id: id,
    x: x,
    y: y,
    width: w,
    height: w,
    interactions: interactions,
    breakpointOverrides: patches,
    layoutChild: layoutChild,
  ),
);

Keyframe _k(String id, double t, double v) =>
    Keyframe(id: id, t: t, value: IrValue.number(v));

/// s1: root1 [ a(100,50) [ a1(10,20), a2 ], b(500,50 200×100) [ b1 ],
///             row (auto layout at 0,400) [ r1, r2 ], reveal(text reveal) ]
/// s2: root2 [ c(0,0) ]
StageDocument _doc() => StageDocument(
  id: 'doc',
  breakpoints: _bps,
  scenes: [
    Scene(
      id: 's1',
      root: FrameNode(
        common: const NodeCommon(id: 'root1', width: 1000, height: 800),
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
              _shape(
                'a1',
                x: 10,
                y: 20,
                patches: {
                  'mobile': {'x': const IrValue.number(30)},
                },
                interactions: const [
                  Interaction(
                    id: 'i1',
                    trigger: InteractionTrigger.tap(),
                    actions: [Action.playTimeline(clockId: 'tl1')],
                  ),
                ],
              ),
              _shape('a2', x: 40, y: 5),
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
            children: [
              _shape(
                'b1',
                x: 1,
                y: 2,
                interactions: const [
                  Interaction(
                    id: 'lb',
                    trigger: InteractionTrigger.tap(),
                    actions: [Action.openLightbox(nodeId: 'a2')],
                  ),
                  Interaction(
                    id: 'mixed',
                    trigger: InteractionTrigger.tap(),
                    actions: [
                      Action.openLightbox(nodeId: 'a2'),
                      Action.openUrl(url: 'https://example.com'),
                    ],
                  ),
                  Interaction(
                    id: 'reach',
                    trigger: InteractionTrigger.clockReach(
                      clockId: 'pc',
                      value: 0.5,
                    ),
                    actions: [Action.openUrl(url: 'https://example.com')],
                  ),
                ],
              ),
            ],
          ),
          FrameNode(
            common: const NodeCommon(
              id: 'row',
              x: 0,
              y: 400,
              width: 300,
              height: 50,
            ),
            autoLayout: const AutoLayout(gap: Gap.fixed(10)),
            children: [_shape('r1'), _shape('r2')],
          ),
          const FrameNode(
            common: NodeCommon(id: 'reveal', width: 100, height: 100),
            behavior: Behavior.textReveal(clockId: 'pc'),
          ),
        ],
      ),
      clocks: const [
        Clock.sceneScroll(id: 'clk1', sceneId: 's1'),
        Clock.timeline(id: 'tl1', duration: 2),
        Clock.pointer(id: 'pc', frameId: 'a'),
      ],
      tracks: [
        Track(
          id: 't1',
          target: 'a1',
          property: 'x',
          clockId: 'clk1',
          keyframes: [_k('k1', 0, 10), _k('k2', 1, 60)],
        ),
        Track(
          id: 't2',
          target: 'a1',
          property: 'opacity',
          clockId: 'tl1',
          keyframes: [_k('k1', 0, 1)],
        ),
        Track(
          id: 't3',
          target: 'a2',
          property: 'opacity',
          clockId: 'tl1',
          keyframes: [_k('k1', 0, 1)],
        ),
        Track(
          id: 't4',
          target: 'b1',
          property: 'opacity',
          clockId: 'pc',
          keyframes: [_k('k1', 0, 1)],
        ),
      ],
    ),
    const Scene(
      id: 's2',
      root: FrameNode(
        common: NodeCommon(id: 'root2', width: 1000, height: 800),
        children: [
          FrameNode(common: NodeCommon(id: 'c', width: 1000, height: 800)),
        ],
      ),
      clocks: [Clock.sceneScroll(id: 'clk2', sceneId: 's2')],
    ),
  ],
);

Node _node(StageDocument d, String id) => DocumentIndex.of(d).node(id)!;
List<IrDiagnostic> _errors(StageDocument d) =>
    validateDocument(d).where((x) => x.severity == IrSeverity.error).toList();

void main() {
  group('removeNodes cascade', () {
    test('removes clocks, tracks, actions and interactions that refer to '
        'removed nodes', () {
      final doc = _doc();
      expect(_errors(doc), isEmpty);
      final r = removeNodes(doc, ['a']);
      expect(r.ok, isTrue);
      final s1 = r.document.scenes[0];
      // The pointer clock was bound to "a"; t4 ran on it.
      expect(r.cascade.removedClockIds, ['pc']);
      expect(s1.clocks.map((c) => c.id), ['clk1', 'tl1']);
      expect(r.cascade.removedTrackIds, ['t1', 't2', 't3', 't4']);
      expect(s1.tracks, isEmpty);
      // Lightbox actions to a2 (inside "a") are gone; "lb" lost its only
      // action, "reach" lost its clock, "mixed" keeps its URL action.
      final b1 = _node(r.document, 'b1');
      expect(b1.common.interactions.map((i) => i.id), ['mixed']);
      expect(b1.common.interactions.single.actions, [
        const Action.openUrl(url: 'https://example.com'),
      ]);
      expect(r.cascade.removedActions.map((a) => a.interactionId), [
        'lb',
        'mixed',
      ]);
      expect(r.cascade.removedInteractions.map((i) => i.interaction.id), [
        'lb',
        'reach',
      ]);
      // The text reveal on the removed clock is reported, not rewritten.
      expect(r.diagnostics.map((d) => d.kind), [IrDiagnosticKind.missingClock]);
      expect(r.diagnostics.single.severity, IrSeverity.warning);
      final errs = _errors(r.document);
      expect(errs.map((e) => e.kind), [IrDiagnosticKind.missingClock]);
      // Untouched scenes keep their identity; the input is untouched.
      expect(identical(r.document.scenes[1], doc.scenes[1]), isTrue);
      expect(_node(doc, 'b1').common.interactions, hasLength(3));
    });

    test('a removal that touches no reference has an empty cascade', () {
      final r = removeNodes(_doc(), ['r1']);
      expect(r.ok, isTrue);
      expect(r.cascade.isEmpty, isTrue);
      expect(r.diagnostics, isEmpty);
    });

    test('a node edited by the cascade still loses its removed children', () {
      // b1 holds the lightbox action and is a child of b; removing a2 rewrites
      // b1, and removing b's sibling must not undo that.
      final doc = _doc();
      final r = removeNodes(doc, ['a2', 'r1']);
      expect(
        (_node(r.document, 'row') as FrameNode).children.map((c) => c.id),
        ['r2'],
      );
      expect(_node(r.document, 'b1').common.interactions, hasLength(2));
    });
  });

  group('moveNodes across scenes', () {
    test('copies the clocks its tracks use, once, and rebinds references', () {
      final doc = _doc();
      final r = moveNodes(
        doc,
        ['a'],
        'c',
        0,
        idGenerator: IdGenerator.seeded(7),
      );
      expect(r.ok, isTrue);
      expect(r.diagnostics, isEmpty);
      final copy = r.cascade.clockIdMap['tl1']!;
      // t2 and t3 both run on tl1: one copy. t4 (on b1) stays.
      expect(r.cascade.clockIdMap.keys, ['tl1']);
      final s1 = r.document.scenes[0], s2 = r.document.scenes[1];
      expect(s1.clocks.map((c) => c.id), ['clk1', 'tl1', 'pc']);
      expect(s1.tracks.map((t) => t.id), ['t4']);
      expect(s2.clocks.map((c) => c.id), ['clk2', copy]);
      expect(
        s2.clocks.last,
        const Clock.timeline(id: 'tl1', duration: 2).copyWith(id: copy),
      );
      final byId = {for (final t in s2.tracks) t.id: t};
      expect(byId['t1']!.clockId, 'clk2');
      expect(byId['t2']!.clockId, copy);
      expect(byId['t3']!.clockId, copy);
      // The interaction on the moved a1 now plays the copy.
      final a1 = _node(r.document, 'a1');
      expect(
        a1.common.interactions.single.actions.single,
        Action.playTimeline(clockId: copy),
      );
      expect(
        _errors(
          r.document,
        ).where((e) => e.kind != IrDiagnosticKind.missingClock),
        isEmpty,
      );
      expect(Resolver().resolve(r.document).diagnostics, isEmpty);
    });

    test('a moved text reveal follows its copied clock', () {
      // reveal uses pc; give it a track on pc so pc is copied.
      final doc = updateScene(
        _doc(),
        's1',
        (s) => s.copyWith(
          tracks: [
            ...s.tracks,
            Track(
              id: 't5',
              target: 'reveal',
              property: 'opacity',
              clockId: 'pc',
              keyframes: [_k('k1', 0, 1)],
            ),
          ],
        ),
      ).document;
      final r = moveNodes(doc, ['reveal'], 'c', 0);
      final copy = r.cascade.clockIdMap['pc']!;
      final reveal = _node(r.document, 'reveal') as FrameNode;
      expect(reveal.behavior, Behavior.textReveal(clockId: copy));
      final pointer = r.document.scenes[1].clocks.last as PointerClock;
      expect(pointer.frameId, 'a');
    });

    test('the scene root of a pinned-scroll source is not duplicated', () {
      final r = moveNodes(_doc(), ['a2'], 'c', 0);
      expect(r.cascade.clockIdMap.keys, ['tl1']);
      expect(r.document.scenes[1].clocks, hasLength(2));
    });
  });

  group('moveNodes keeps the visual position', () {
    test('reparenting between free frames converts geometry, patches and '
        'x/y tracks', () {
      final doc = _doc();
      final r = moveNodes(doc, ['a1'], 'b', 0);
      expect(r.ok, isTrue);
      expect(r.diagnostics, isEmpty);
      final a1 = _node(r.document, 'a1').common;
      // Was at (110, 70) in the root; b is at (500, 50).
      expect((a1.x, a1.y), (-390.0, 20.0));
      expect((a1.width, a1.height), (10.0, 10.0));
      expect(
        a1.breakpointOverrides['mobile']!['x'],
        const IrValue.number(-370),
      );
      final t1 = r.document.scenes[0].tracks.firstWhere((t) => t.id == 't1');
      expect(t1.keyframes.map((k) => k.value), [
        const IrValue.number(-390),
        const IrValue.number(-340),
      ]);
    });

    test('the inverse constraints use the new parent\'s box and reference', () {
      final doc = updateNode(
        _doc(),
        'a1',
        (n) => n.copyWith(
          common: n.common.copyWith(
            layoutChild: const LayoutChild(
              constraints: Constraints(
                horizontal: HorizontalConstraint.right,
                vertical: VerticalConstraint.scale,
              ),
            ),
          ),
        ),
      ).document;
      // b is laid out 400×200 (reference 200×100), at (500, 50); a1's box
      // is (600, 80, 10×10).
      final r = moveNodes(
        doc,
        ['a1'],
        'b',
        0,
        boxes: const {
          'a1': StageRect(x: 600, y: 80, width: 10, height: 10),
          'b': StageRect(x: 500, y: 50, width: 400, height: 200),
        },
      );
      final a1 = _node(r.document, 'a1').common;
      // right: keeps the right margin: 400 − 100 − 10 = 290 → x = 200 − 10 − 290.
      expect(a1.x, -100);
      // scale ×2: y 30 → 15, height 10 → 5.
      expect(a1.y, 15);
      expect(a1.height, 5);
      // Forward map gives back the box.
      final h = resolveAxisConstraint(
        constraint: AxisConstraint.end,
        position: a1.x,
        size: a1.width,
        reference: 200,
        parent: 400,
      );
      expect((h.offset, h.size), (100.0, 10.0));
    });

    test('into a flow scene root, against the design size', () {
      final r = moveNodes(_doc(), ['a1'], 'root1', 0);
      final a1 = _node(r.document, 'a1').common;
      expect((a1.x, a1.y), (110.0, 70.0));
    });

    test('in-flow auto-layout children only reorder', () {
      final doc = _doc();
      final r = moveNodes(doc, ['a1'], 'row', 1);
      expect(r.ok, isTrue);
      expect(identical(_node(r.document, 'a1'), _node(doc, 'a1')), isTrue);
      expect(
        (_node(r.document, 'row') as FrameNode).children.map((c) => c.id),
        ['r1', 'a1', 'r2'],
      );
    });

    test('an absolute child of auto layout converts', () {
      final doc = updateNode(
        _doc(),
        'a1',
        (n) => n.copyWith(
          common: n.common.copyWith(
            layoutChild: const LayoutChild(positioning: Positioning.absolute),
          ),
        ),
      ).document;
      final a1 = _node(moveNodes(doc, ['a1'], 'row', 0).document, 'a1').common;
      expect((a1.x, a1.y), (110.0, -330.0));
    });

    test('out of auto layout: needs boxes, warns without them', () {
      final doc = _doc();
      final warned = moveNodes(doc, ['r1'], 'b', 0);
      expect(warned.ok, isTrue);
      expect(warned.diagnostics.single.kind, IrDiagnosticKind.invalidEdit);
      expect(identical(_node(warned.document, 'r1'), _node(doc, 'r1')), isTrue);
      final boxed = moveNodes(
        doc,
        ['r1'],
        'b',
        0,
        boxes: const {
          'r1': StageRect(x: 20, y: 400, width: 10, height: 10),
          'b': StageRect(x: 500, y: 50, width: 200, height: 100),
        },
      );
      expect(boxed.diagnostics, isEmpty);
      final r1 = _node(boxed.document, 'r1').common;
      expect((r1.x, r1.y), (-480.0, 350.0));
    });

    test('reorders and preservePosition: false keep geometry', () {
      final doc = _doc();
      final reorder = moveNodes(doc, ['a1'], 'a', 2);
      expect(
        identical(_node(reorder.document, 'a1'), _node(doc, 'a1')),
        isTrue,
      );
      final raw = moveNodes(doc, ['a1'], 'b', 0, preservePosition: false);
      expect(identical(_node(raw.document, 'a1'), _node(doc, 'a1')), isTrue);
    });

    test('a breakpoint\'s patched geometry is what is kept there', () {
      // a1 at mobile is x 30 → box x 130 in the root.
      final r = moveNodes(_doc(), ['a1'], 'b', 0, breakpointId: 'mobile');
      final a1 = _node(r.document, 'a1').common;
      expect(
        a1.breakpointOverrides['mobile']!['x'],
        const IrValue.number(-370),
      );
      expect(a1.x, -390);
    });
  });
}
