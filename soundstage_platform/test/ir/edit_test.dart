import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fuzz/doc_generator.dart';

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
  Breakpoint(
    id: 'tablet',
    name: 'Tablet',
    minWidth: 600,
    designSize: StageSize(width: 700, height: 800),
    inheritsFrom: 'desktop',
  ),
];

ShapeNode _shape(String id, {double x = 0, double y = 0, double w = 10}) =>
    ShapeNode(
      common: NodeCommon(id: id, x: x, y: y, width: w, height: w),
    );

/// Two scenes:
///   s1: root1 [ a [ a1, a2 ], b [ b1 ], inst ]
///   s2: root2 [ c [ c1 ] ]
/// Tracks: s1 animates a1.x and inst/cmpR opacity; s2 animates c1.opacity.
StageDocument _doc() => StageDocument(
  id: 'doc',
  breakpoints: _bps,
  components: {
    'cmp': ComponentDef(
      id: 'cmp',
      name: 'Card',
      root: FrameNode(
        common: const NodeCommon(id: 'cmpR', width: 50, height: 50),
        children: [_shape('cmpI')],
      ),
    ),
  },
  scenes: [
    Scene(
      id: 's1',
      root: FrameNode(
        common: const NodeCommon(id: 'root1', width: 1000, height: 800),
        children: [
          FrameNode(
            common: const NodeCommon(id: 'a', x: 100, y: 50, width: 300),
            children: [_shape('a1', x: 10, y: 20), _shape('a2', x: 40, y: 5)],
          ),
          FrameNode(
            common: const NodeCommon(id: 'b', x: 500, y: 50, width: 200),
            children: [_shape('b1', x: 1, y: 2)],
          ),
          const InstanceNode(
            common: NodeCommon(id: 'inst', x: 700, y: 300, width: 50),
            source: InstanceSource.component('cmp'),
          ),
        ],
      ),
      clocks: const [
        Clock.sceneScroll(id: 'clk1', sceneId: 's1'),
        Clock.timeline(id: 'tl1', duration: 2),
      ],
      tracks: const [
        Track(
          id: 't1',
          target: 'a1',
          property: 'x',
          clockId: 'clk1',
          keyframes: [
            Keyframe(id: 'k1', t: 0, value: IrValue.number(10)),
            Keyframe(id: 'k2', t: 1, value: IrValue.number(60)),
          ],
        ),
        Track(
          id: 't2',
          target: 'inst/cmpI',
          property: 'opacity',
          clockId: 'tl1',
          keyframes: [Keyframe(id: 'k1', t: 0, value: IrValue.number(1))],
        ),
      ],
    ),
    Scene(
      id: 's2',
      root: FrameNode(
        common: const NodeCommon(id: 'root2', width: 1000, height: 800),
        children: [
          FrameNode(
            common: const NodeCommon(id: 'c'),
            children: [_shape('c1')],
          ),
        ],
      ),
      clocks: const [Clock.sceneScroll(id: 'clk2', sceneId: 's2')],
      tracks: const [
        Track(
          id: 't3',
          target: 'c1',
          property: 'opacity',
          clockId: 'clk2',
          keyframes: [Keyframe(id: 'k1', t: 0, value: IrValue.number(1))],
        ),
      ],
    ),
  ],
);

FrameNode _frame(StageDocument d, String id) =>
    DocumentIndex.of(d).node(id)! as FrameNode;
List<String> _kids(StageDocument d, String id) => [
  for (final c in _frame(d, id).children) c.id,
];
Iterable<IrDiagnosticKind> _kinds(EditResult r) =>
    r.diagnostics.map((d) => d.kind);
List<IrDiagnostic> _errors(StageDocument d) =>
    validateDocument(d).where((x) => x.severity == IrSeverity.error).toList();

void main() {
  group('DocumentIndex', () {
    test('locates scene nodes and the overlay', () {
      final doc = _doc().copyWith(
        overlay: FrameNode(
          common: const NodeCommon(id: 'ov'),
          children: [_shape('ov1')],
        ),
      );
      final index = DocumentIndex.of(doc);
      final loc = index.locate('a2')!;
      expect(loc.sceneIndex, 0);
      expect(loc.sceneId, 's1');
      expect(loc.childPath, [0, 1]);
      expect(loc.ancestorIds, ['root1', 'a']);
      expect(loc.parentId, 'a');
      expect(loc.index, 1);
      expect(index.locate('root2')!.isRoot, isTrue);
      expect(index.locate('ov1')!.inOverlay, isTrue);
      expect(index.locate('inst/cmpI'), isNull);
      expect(index.isAncestor('root1', 'a1'), isTrue);
      expect(index.nodeIds, containsAll(['a1', 'c1', 'ov1']));
      expect(identical(DocumentIndex.of(doc), index), isTrue);
    });
  });

  group('updateNode', () {
    test('copies only the path; untouched branches keep identity', () {
      final doc = _doc();
      final r = updateNode(
        doc,
        'a1',
        (n) => n.copyWith(common: n.common.copyWith(opacity: 0.5)),
      );
      expect(r.ok && r.changed, isTrue);
      final out = r.document;
      expect(identical(out.scenes[1], doc.scenes[1]), isTrue);
      final i0 = DocumentIndex.of(doc), i1 = DocumentIndex.of(out);
      for (final id in ['a2', 'b', 'b1', 'inst']) {
        expect(identical(i1.node(id), i0.node(id)), isTrue, reason: id);
      }
      for (final id in ['root1', 'a', 'a1']) {
        expect(identical(i1.node(id), i0.node(id)), isFalse, reason: id);
      }
      expect(i1.node('a1')!.common.opacity, 0.5);
      // Tracks and other scene fields are shared too.
      expect(
        identical(out.scenes[0].tracks[0], doc.scenes[0].tracks[0]),
        isTrue,
      );
      expect(identical(out.tokens, doc.tokens), isTrue);
    });

    test('the resolver memo hits for everything off the path', () {
      final doc = _doc();
      final resolver = Resolver();
      final before = resolver.resolve(doc);
      final out = updateNode(
        doc,
        'a1',
        (n) => n.copyWith(common: n.common.copyWith(opacity: 0.5)),
      ).document;
      final after = resolver.resolve(out);
      for (final id in ['a2', 'b', 'b1', 'inst', 'inst/cmpI', 'root2', 'c1']) {
        expect(
          identical(after.nodeIndex[id], before.nodeIndex[id]),
          isTrue,
          reason: id,
        );
      }
      for (final id in ['root1', 'a', 'a1']) {
        expect(identical(after.nodeIndex[id], before.nodeIndex[id]), isFalse);
      }
      expect(after, Resolver().resolve(out));
    });

    test('a same-shape edit reuses the scene index', () {
      final doc = _doc();
      DocumentIndex.of(doc).locate('a1');
      final out = updateNode(
        doc,
        'a',
        (n) => n.copyWith(common: n.common.copyWith(x: 1)),
      ).document;
      expect(DocumentIndex.of(out).locate('a2')!.childPath, [0, 1]);
      expect(DocumentIndex.of(out).node('a')!.common.x, 1);
    });

    test('returning the node is a no-op', () {
      final doc = _doc();
      final r = updateNode(doc, 'a1', (n) => n);
      expect(identical(r.document, doc), isTrue);
      expect(r.changed, isFalse);
      expect(r.ok, isTrue);
    });

    test('bad ids, instance inner ids and root kinds give diagnostics', () {
      final doc = _doc();
      final missing = updateNode(doc, 'nope', (n) => n);
      expect(_kinds(missing), [IrDiagnosticKind.missingNode]);
      expect(identical(missing.document, doc), isTrue);
      expect(_kinds(updateNode(doc, 'inst/cmpI', (n) => n)), [
        IrDiagnosticKind.editInsideInstance,
      ]);
      expect(_kinds(updateNode(doc, 'root1', (n) => _shape('root1'))), [
        IrDiagnosticKind.invalidEdit,
      ]);
      final rename = updateNode(
        doc,
        'a1',
        (n) => n.copyWith(common: n.common.copyWith(id: 'b1')),
      );
      expect(_kinds(rename), [IrDiagnosticKind.invalidEdit]);
      expect(identical(rename.document, doc), isTrue);
    });
  });

  group('insertNodes', () {
    test('inserts at an index; siblings and other scenes keep identity', () {
      final doc = _doc();
      final r = insertNodes(doc, 'a', 1, [_shape('n1'), _shape('n2')]);
      expect(r.ok, isTrue);
      expect(r.createdIds, ['n1', 'n2']);
      expect(_kids(r.document, 'a'), ['a1', 'n1', 'n2', 'a2']);
      expect(identical(r.document.scenes[1], doc.scenes[1]), isTrue);
      expect(
        identical(DocumentIndex.of(r.document).node('b'), _frame(doc, 'b')),
        isTrue,
      );
      expect(_errors(r.document), isEmpty);
    });

    test('clamps the index with a warning', () {
      final r = insertNodes(_doc(), 'a', 99, [_shape('n1')]);
      expect(r.ok, isTrue);
      expect(_kids(r.document, 'a').last, 'n1');
      expect(r.diagnostics.single.severity, IrSeverity.warning);
    });

    test('refuses duplicate ids, non-frame and instance parents', () {
      final doc = _doc();
      expect(_kinds(insertNodes(doc, 'a', 0, [_shape('b1')])), [
        IrDiagnosticKind.invalidEdit,
      ]);
      expect(_kinds(insertNodes(doc, 'a', 0, [_shape('x'), _shape('x')])), [
        IrDiagnosticKind.invalidEdit,
      ]);
      expect(_kinds(insertNodes(doc, 'a1', 0, [_shape('x')])), [
        IrDiagnosticKind.invalidEdit,
      ]);
      expect(_kinds(insertNodes(doc, 'inst', 0, [_shape('x')])), [
        IrDiagnosticKind.editInsideInstance,
      ]);
    });
  });

  group('removeNodes', () {
    test('removes subtrees and their tracks', () {
      final doc = _doc();
      final r = removeNodes(doc, ['a', 'a1', 'inst']);
      expect(r.ok, isTrue);
      expect(_kids(r.document, 'root1'), ['b']);
      expect(r.document.scenes[0].tracks, isEmpty);
      expect(identical(r.document.scenes[1], doc.scenes[1]), isTrue);
      expect(_errors(r.document), isEmpty);
    });

    test('warns about clocks left pointing at a removed node', () {
      final doc = _doc();
      final withClock = updateScene(
        doc,
        's1',
        (s) => s.copyWith(
          clocks: [
            ...s.clocks,
            const Clock.pointer(id: 'pc', frameId: 'b', axis: PointerAxis.x),
          ],
        ),
      ).document;
      final r = removeNodes(withClock, ['b']);
      expect(r.ok, isTrue);
      expect(r.diagnostics.single.kind, IrDiagnosticKind.missingNode);
      expect(r.diagnostics.single.severity, IrSeverity.warning);
    });

    test('roots and unknown ids are errors and change nothing', () {
      final doc = _doc();
      final r = removeNodes(doc, ['a1', 'root1']);
      expect(_kinds(r), [IrDiagnosticKind.invalidEdit]);
      expect(identical(r.document, doc), isTrue);
      expect(_kinds(removeNodes(doc, ['zzz'])), [IrDiagnosticKind.missingNode]);
    });
  });

  group('moveNodes', () {
    test('reorders with drop-indicator indices', () {
      final doc = _doc();
      // Move a1 below a2: insertion point 2 counts a1 itself.
      expect(_kids(moveNodes(doc, ['a1'], 'a', 2).document, 'a'), ['a2', 'a1']);
      // Back to the top.
      final top = moveNodes(doc, ['a2'], 'a', 0).document;
      expect(_kids(top, 'a'), ['a2', 'a1']);
      // Already there: a no-op that returns the same document.
      final same = moveNodes(doc, ['a1'], 'a', 0);
      expect(same.changed, isFalse);
      expect(identical(same.document, doc), isTrue);
    });

    test('reparents several nodes, keeping tree order', () {
      final doc = _doc();
      final r = moveNodes(doc, ['b1', 'a2', 'a1'], 'b', 0);
      expect(r.ok, isTrue);
      expect(_kids(r.document, 'b'), ['a1', 'a2', 'b1']);
      expect(_kids(r.document, 'a'), isEmpty);
      expect(identical(r.document.scenes[1], doc.scenes[1]), isTrue);
      expect(
        identical(
          DocumentIndex.of(r.document).node('a1'),
          DocumentIndex.of(doc).node('a1'),
        ),
        isTrue,
        reason: 'moved nodes keep their identity',
      );
      expect(_errors(r.document), isEmpty);
    });

    test('refuses cycles', () {
      final doc = _doc();
      final r = moveNodes(doc, ['a'], 'a', 0);
      expect(_kinds(r), [IrDiagnosticKind.editCycle]);
      final deep = insertNodes(doc, 'a', 0, [
        const FrameNode(common: NodeCommon(id: 'aa')),
      ]).document;
      expect(_kinds(moveNodes(deep, ['a'], 'aa', 0)), [
        IrDiagnosticKind.editCycle,
      ]);
      expect(identical(moveNodes(deep, ['a'], 'aa', 0).document, deep), isTrue);
    });

    test('tracks follow nodes to another scene; scroll clocks rebind', () {
      final doc = _doc();
      final r = moveNodes(doc, ['a'], 'c', 0);
      expect(r.ok, isTrue);
      final s1 = r.document.scenes[0], s2 = r.document.scenes[1];
      expect(s1.tracks.map((t) => t.id), ['t2']);
      final moved = s2.tracks.firstWhere((t) => t.id == 't1');
      expect(moved.clockId, 'clk2');
      expect(r.diagnostics, isEmpty);
      expect(_errors(r.document), isEmpty);
      expect(Resolver().resolve(r.document).diagnostics, isEmpty);
    });

    test('a track on another clock moves with a warning', () {
      final r = moveNodes(_doc(), ['inst'], 'c', 0);
      expect(r.ok, isTrue);
      expect(_kinds(r), [IrDiagnosticKind.missingClock]);
    });
  });

  group('wrapInFrame', () {
    test('keeps visual positions and offsets x tracks and patches', () {
      final doc = updateNode(
        _doc(),
        'a1',
        (n) => n.copyWith(
          common: n.common.copyWith(
            breakpointOverrides: {
              'mobile': {
                'x': const IrValue.number(30),
                'opacity': const IrValue.number(0.5),
              },
            },
          ),
        ),
      ).document;
      final r = wrapInFrame(
        doc,
        ['a2', 'a1'],
        (b) => const FrameNode(
          common: NodeCommon(id: 'w', name: 'Wrap'),
        ),
      );
      expect(r.ok, isTrue);
      expect(r.createdIds, ['w']);
      final out = r.document;
      expect(_kids(out, 'a'), ['w']);
      expect(_kids(out, 'w'), ['a1', 'a2']);
      final w = _frame(out, 'w').common;
      // a1 (10,20,10,10) ∪ a2 (40,5,10,10) = (10,5) → (50,30).
      expect([w.x, w.y, w.width, w.height], [10, 5, 40, 25]);
      final idx = DocumentIndex.of(out);
      for (final (id, x, y) in [('a1', 10.0, 20.0), ('a2', 40.0, 5.0)]) {
        final c = idx.node(id)!.common;
        expect((w.x + c.x, w.y + c.y), (x, y), reason: id);
      }
      expect(
        idx.node('a1')!.common.breakpointOverrides['mobile']!['x'],
        const IrValue.number(20),
      );
      final t1 = out.scenes[0].tracks.firstWhere((t) => t.id == 't1');
      expect(t1.keyframes.map((k) => k.value), const [
        IrValue.number(0),
        IrValue.number(50),
      ]);
      expect(identical(out.scenes[1], doc.scenes[1]), isTrue);
      expect(_errors(out), isEmpty);
    });

    test('takes the place of the topmost wrapped node', () {
      final r = wrapInFrame(_doc(), [
        'a',
        'b',
      ], (b) => const FrameNode(common: NodeCommon(id: 'w')));
      expect(_kids(r.document, 'root1'), ['w', 'inst']);
    });

    test('uses rotated bounds and explicit boxes', () {
      final doc = updateNode(
        _doc(),
        'b1',
        (n) => n.copyWith(common: n.common.copyWith(rotation: 45)),
      ).document;
      final r = wrapInFrame(doc, [
        'b1',
      ], (b) => const FrameNode(common: NodeCommon(id: 'w')));
      final w = _frame(r.document, 'w').common;
      final half = 10 * sqrt2 / 2;
      expect(w.width, closeTo(2 * half, 1e-9));
      expect(w.x, closeTo(6 - half, 1e-9));
      final boxed = wrapInFrame(
        _doc(),
        ['a1'],
        (b) => const FrameNode(common: NodeCommon(id: 'w')),
        boxes: {'a1': const StageRect(x: 3, y: 4, width: 5, height: 6)},
      );
      final bw = _frame(boxed.document, 'w').common;
      expect([bw.x, bw.y, bw.width, bw.height], [3, 4, 5, 6]);
      expect(DocumentIndex.of(boxed.document).node('a1')!.common.x, 0);
    });

    test('refuses non-siblings, roots and clashing frame ids', () {
      final doc = _doc();
      FrameNode f(StageRect _) => const FrameNode(common: NodeCommon(id: 'w'));
      expect(_kinds(wrapInFrame(doc, ['a1', 'b1'], f)), [
        IrDiagnosticKind.invalidEdit,
      ]);
      expect(_kinds(wrapInFrame(doc, ['root1'], f)), [
        IrDiagnosticKind.invalidEdit,
      ]);
      expect(
        _kinds(
          wrapInFrame(doc, [
            'a1',
          ], (_) => const FrameNode(common: NodeCommon(id: 'b'))),
        ),
        [IrDiagnosticKind.invalidEdit],
      );
    });
  });

  group('duplicateNodes', () {
    test('deep-copies with fresh ids after each original', () {
      final doc = _doc();
      final r = duplicateNodes(doc, ['a', 'a1', 'b1'], IdGenerator.seeded(1));
      expect(r.ok, isTrue);
      expect(r.idMap.keys, containsAll(['a', 'a1', 'a2', 'b1']));
      final a = r.idMap['a']!;
      expect(_kids(r.document, 'root1'), ['a', a, 'b', 'inst']);
      expect(_kids(r.document, a), [r.idMap['a1'], r.idMap['a2']]);
      expect(_kids(r.document, 'b'), ['b1', r.idMap['b1']]);
      expect(r.createdIds, [a, r.idMap['b1']]);
      // a1's track is duplicated onto the copy.
      final tracks = r.document.scenes[0].tracks;
      expect(tracks.where((t) => t.target == r.idMap['a1']), hasLength(1));
      expect(identical(r.document.scenes[1], doc.scenes[1]), isTrue);
      expect(_errors(r.document), isEmpty);
    });

    test('remaps instance-inner track targets and lightbox actions', () {
      final doc = updateNode(
        _doc(),
        'a1',
        (n) => n.copyWith(
          common: n.common.copyWith(
            interactions: const [
              Interaction(
                id: 'i1',
                trigger: InteractionTrigger.tap(),
                actions: [
                  Action.openLightbox(nodeId: 'a2'),
                  Action.openLightbox(nodeId: 'b1'),
                ],
              ),
            ],
          ),
        ),
      ).document;
      final r = duplicateNodes(doc, ['a', 'inst'], IdGenerator.seeded(2));
      final copyA1 = DocumentIndex.of(r.document).node(r.idMap['a1']!)!;
      final actions = copyA1.common.interactions.single.actions;
      expect(actions[0], Action.openLightbox(nodeId: r.idMap['a2']!));
      expect(actions[1], const Action.openLightbox(nodeId: 'b1'));
      final inst = r.idMap['inst']!;
      expect(
        r.document.scenes[0].tracks.map((t) => t.target),
        contains('$inst/cmpI'),
      );
      expect(_errors(r.document), isEmpty);
      expect(Resolver().resolve(r.document).diagnostics, isEmpty);
    });
  });

  group('scenes', () {
    test('update, insert, move and remove keep other scenes', () {
      final doc = _doc();
      final up = updateScene(doc, 's2', (s) => s.copyWith(scrollLength: 3));
      expect(up.document.scenes[1].scrollLength, 3);
      expect(identical(up.document.scenes[0], doc.scenes[0]), isTrue);
      expect(identical(up.document.scenes[1].root, doc.scenes[1].root), isTrue);

      final blank = const Scene(
        id: 's3',
        root: FrameNode(common: NodeCommon(id: 'root3')),
        clocks: [Clock.sceneScroll(id: 'clk3', sceneId: 's3')],
      );
      final ins = insertScene(doc, 1, blank);
      expect(ins.document.scenes.map((s) => s.id), ['s1', 's3', 's2']);
      expect(identical(ins.document.scenes[2], doc.scenes[1]), isTrue);

      final mv = moveScene(ins.document, 's1', 3);
      expect(mv.document.scenes.map((s) => s.id), ['s3', 's2', 's1']);
      expect(moveScene(ins.document, 's1', 0).changed, isFalse);

      final rm = removeScene(doc, 's1');
      expect(rm.document.scenes.single, same(doc.scenes[1]));
    });

    test('clashes and unknown scenes are errors', () {
      final doc = _doc();
      expect(_kinds(removeScene(doc, 'zz')), [IrDiagnosticKind.missingScene]);
      final dup = const Scene(
        id: 's3',
        root: FrameNode(common: NodeCommon(id: 'a1')),
      );
      expect(_kinds(insertScene(doc, 0, dup)), [IrDiagnosticKind.invalidEdit]);
      expect(_kinds(updateScene(doc, 's1', (s) => s.copyWith(id: 's2'))), [
        IrDiagnosticKind.invalidEdit,
      ]);
    });
  });

  group('edit scope', () {
    StageDocument withPatches() => updateNode(
      _doc(),
      'a1',
      (n) => n.copyWith(
        common: n.common.copyWith(
          breakpointOverrides: {
            'mobile': {
              'opacity': const IrValue.number(0.2),
              'x': const IrValue.number(5),
            },
            'tablet': {'opacity': const IrValue.number(0.3)},
          },
        ),
      ),
    ).document;
    double opacityAt(StageDocument d, String bp) => resolveDocument(
      d,
      ResolveContext(breakpointId: bp),
    ).nodeIndex['a1']!.node.common.opacity;

    test('Both writes the base and clears the listed patches only', () {
      final doc = withPatches();
      final r = setPropertyAcrossBreakpoints(
        doc,
        'a1',
        'opacity',
        const IrValue.number(0.9),
        clearPatchesOn: {'desktop', 'mobile'},
      );
      expect(r.ok, isTrue);
      final out = r.document;
      expect(opacityAt(out, 'desktop'), 0.9);
      expect(opacityAt(out, 'mobile'), 0.9);
      expect(opacityAt(out, 'tablet'), 0.3, reason: 'not a listed breakpoint');
      final patches = DocumentIndex.of(
        out,
      ).node('a1')!.common.breakpointOverrides;
      expect(patches['mobile'], {'x': const IrValue.number(5)});
      // Identity: only the path to a1 is copied.
      expect(identical(out.scenes[1], doc.scenes[1]), isTrue);
      expect(
        identical(
          DocumentIndex.of(out).node('b'),
          DocumentIndex.of(doc).node('b'),
        ),
        isTrue,
      );
      expect(
        identical(
          DocumentIndex.of(out).node('a2'),
          DocumentIndex.of(doc).node('a2'),
        ),
        isTrue,
      );
    });

    test('Both rewrites a whole-value patch above the path', () {
      final doc = updateNode(
        _doc(),
        'a1',
        (n) => (n as ShapeNode).copyWith(
          appearance: const Appearance(
            fills: [Paint.solid(id: 'p', color: StageColor.black)],
          ),
          common: n.common.copyWith(
            breakpointOverrides: {
              'mobile': {
                'fills': const IrValue.paints([
                  Paint.solid(id: 'p', color: StageColor.white, opacity: 0.5),
                ]),
              },
            },
          ),
        ),
      ).document;
      const red = StageColor(r: 1, g: 0, b: 0);
      final out = setPropertyAcrossBreakpoints(
        doc,
        'a1',
        'fills.p.color',
        const IrValue.color(red),
        clearPatchesOn: {'mobile'},
      ).document;
      final mobile =
          resolveDocument(
                out,
                const ResolveContext(breakpointId: 'mobile'),
              ).nodeIndex['a1']!.node
              as ShapeNode;
      final p = mobile.appearance.fills.single as SolidPaint;
      expect(p.color, red);
      expect(p.opacity, 0.5, reason: 'the patch keeps its other override');
    });

    test('Both reports bad paths and unknown breakpoints', () {
      final doc = withPatches();
      final bad = setPropertyAcrossBreakpoints(
        doc,
        'a1',
        'nope',
        const IrValue.number(1),
        clearPatchesOn: {'mobile'},
      );
      expect(bad.ok, isFalse);
      expect(identical(bad.document, doc), isTrue);
      final unknown = setPropertyAcrossBreakpoints(
        doc,
        'a1',
        'opacity',
        const IrValue.number(1),
        clearPatchesOn: {'zz'},
      );
      expect(unknown.ok, isTrue);
      expect(_kinds(unknown), [IrDiagnosticKind.missingBreakpoint]);
    });

    test('This breakpoint writes, reorders and clears a patch value', () {
      final doc = withPatches();
      final r = setBreakpointPatchValue(
        doc,
        'a1',
        'mobile',
        'opacity',
        const IrValue.number(0.7),
      );
      expect(r.ok, isTrue);
      expect(opacityAt(r.document, 'mobile'), 0.7);
      expect(opacityAt(r.document, 'desktop'), 1);
      final patch = DocumentIndex.of(
        r.document,
      ).node('a1')!.common.breakpointOverrides['mobile']!;
      expect(patch.keys, ['x', 'opacity']);

      final cleared = clearBreakpointPatchValue(
        r.document,
        'a1',
        'mobile',
        'opacity',
      );
      expect(opacityAt(cleared.document, 'mobile'), 1);
      final gone = clearBreakpointPatchValue(
        cleared.document,
        'a1',
        'mobile',
        'x',
      );
      expect(
        DocumentIndex.of(gone.document).node('a1')!.common.breakpointOverrides,
        {
          'tablet': {'opacity': const IrValue.number(0.3)},
        },
      );
      expect(
        clearBreakpointPatchValue(gone.document, 'a1', 'mobile', 'x').changed,
        isFalse,
      );
    });

    test('This breakpoint validates the breakpoint, path and value', () {
      final doc = _doc();
      expect(
        _kinds(
          setBreakpointPatchValue(
            doc,
            'a1',
            'zz',
            'x',
            const IrValue.number(1),
          ),
        ),
        [IrDiagnosticKind.missingBreakpoint],
      );
      expect(
        _kinds(
          setBreakpointPatchValue(
            doc,
            'a1',
            'mobile',
            'nope',
            const IrValue.number(1),
          ),
        ),
        [IrDiagnosticKind.unknownPath],
      );
      expect(
        _kinds(
          setBreakpointPatchValue(
            doc,
            'a1',
            'mobile',
            'x',
            const IrValue.boolean(true),
          ),
        ),
        [IrDiagnosticKind.inapplicablePath],
      );
      expect(
        _kinds(
          setBreakpointPatchValue(
            doc,
            'inst/cmpI',
            'mobile',
            'x',
            const IrValue.number(1),
          ),
        ),
        [IrDiagnosticKind.editInsideInstance],
      );
    });
  });

  test('random edits on fuzz documents: never throw, stay coherent', () {
    var applied = 0;
    for (var seed = 0; seed < 120; seed++) {
      final doc = DocGen(seed).build();
      final r = Random(seed);
      final index = DocumentIndex.of(doc);
      final ids = index.nodeIds
          .where((id) => !index.locate(id)!.isRoot)
          .toList();
      if (ids.isEmpty) continue;
      String pick() => ids[r.nextInt(ids.length)];
      final frames = [
        for (final id in index.nodeIds)
          if (index.node(id) is FrameNode) id,
      ];
      final gen = IdGenerator.forDocument(doc, random: Random(seed));
      final results = <EditResult>[
        updateNode(
          doc,
          pick(),
          (n) => n.copyWith(common: n.common.copyWith(opacity: 0.25)),
        ),
        moveNodes(
          doc,
          [pick()],
          frames[r.nextInt(frames.length)],
          r.nextInt(3),
        ),
        duplicateNodes(doc, [pick(), pick()], gen),
        removeNodes(doc, [pick()]),
        setPropertyAcrossBreakpoints(
          doc,
          pick(),
          'x',
          const IrValue.number(12),
          clearPatchesOn: {for (final b in doc.primaryBreakpoints) b.id},
        ),
      ];
      final resolver = Resolver()..resolve(doc);
      for (final (i, res) in results.indexed) {
        final out = res.document;
        if (!res.ok) {
          expect(identical(out, doc), isTrue, reason: 'seed $seed op $i');
          continue;
        }
        applied++;
        // Scenes the edit did not touch keep their identity.
        final touched = <int>{};
        for (var s = 0; s < doc.scenes.length && s < out.scenes.length; s++) {
          if (!identical(out.scenes[s], doc.scenes[s])) touched.add(s);
        }
        if (i == 0 || i == 4) expect(touched.length, lessThanOrEqualTo(1));
        // No new duplicate ids, and incremental resolution stays exact.
        final dup = validateDocument(
          out,
        ).where((d) => d.kind == IrDiagnosticKind.duplicateNodeId);
        expect(dup, isEmpty, reason: 'seed $seed op $i');
        expect(
          Resolver().resolve(out),
          resolver.resolve(out),
          reason: 'seed $seed op $i',
        );
        resolver.resolve(doc);
      }
    }
    expect(applied, greaterThan(400));
  });
}
