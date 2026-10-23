import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

List<String> _kids(ProviderContainer c, String id) => [
  for (final k in (c.node(id) as FrameNode).children) k.id,
];

(double, double) _xy(ProviderContainer c, String id) =>
    (c.node(id).common.x, c.node(id).common.y);

void main() {
  group('node commands', () {
    test('InsertNodes inserts on top and selects the new nodes', () {
      final c = editorContainer();
      expectRoundTrip(c, InsertNodes('b', [shape('n1'), shape('n2')]));
      expect(_kids(c, 'b'), ['b1', 'n1', 'n2']);
      expect(c.st.selection, {'n1', 'n2'});
      expect(c.st.selectionContext, 'b');
      expect(c.st.history.undoLabel, 'Insert 2 layers');
      final at = c.ctl.execute(InsertNodes('b', [shape('n0')], index: 0));
      expect(at.ok, isTrue);
      expect(_kids(c, 'b').first, 'n0');
    });

    test('DeleteNodes cascades and clears the selection', () {
      final doc = updateScene(
        fixtureDoc(),
        's1',
        (s) => s.copyWith(
          clocks: [
            ...s.clocks,
            const Clock.pointer(id: 'pc', frameId: 'a'),
          ],
          tracks: const [
            Track(id: 't', target: 'b1', property: 'opacity', clockId: 'pc'),
          ],
        ),
      ).document;
      final c = editorContainer(doc);
      c.ctl.select({'a'});
      final r = expectRoundTrip(c, const DeleteNodes(['a']));
      expect(c.st.selection, isEmpty);
      expect(r.cascade.removedClockIds, ['pc']);
      expect(r.cascade.removedTrackIds, ['t']);
      expect(c.doc.scenes.first.tracks, isEmpty);
      // Undo restores everything, selection included.
      c.ctl.undo();
      expect(c.st.selection, {'a'});
      expect(c.doc.scenes.first.tracks, hasLength(1));
    });

    test('MoveNodes keeps the visual position and selects the moved', () {
      final c = editorContainer();
      expectRoundTrip(c, const MoveNodes(['a1'], 'b', 0));
      expect(_kids(c, 'b'), ['a1', 'b1']);
      expect(_xy(c, 'a1'), (-390.0, 20.0));
      expect(c.st.selection, {'a1'});
    });

    test('MoveNodes to another scene switches to it', () {
      final c = editorContainer();
      expectRoundTrip(c, const MoveNodes(['b'], 'root2', 1));
      expect(c.st.activeSceneId, 's2');
      expect(_kids(c, 'root2'), ['c', 'b']);
    });

    test('ReorderNodes: forward, backward, front, back', () {
      final c = editorContainer();
      expectRoundTrip(c, const ReorderNodes(['a1'], ReorderDirection.forward));
      expect(_kids(c, 'a'), ['t1', 'a1', 'a2']);
      c.ctl.execute(const ReorderNodes(['a1'], ReorderDirection.front));
      expect(_kids(c, 'a'), ['t1', 'a2', 'a1']);
      c.ctl.execute(const ReorderNodes(['a1'], ReorderDirection.backward));
      expect(_kids(c, 'a'), ['t1', 'a1', 'a2']);
      c.ctl.execute(const ReorderNodes(['a2', 'a1'], ReorderDirection.back));
      expect(_kids(c, 'a'), ['a1', 'a2', 't1']);
      // Already at the back: a no-op, not recorded.
      final depth = c.ctl.history.undoDepth;
      final r = c.ctl.execute(
        const ReorderNodes(['a1'], ReorderDirection.back),
      );
      expect(r.changed, isFalse);
      expect(c.ctl.history.undoDepth, depth);
    });

    test(
      'DuplicateNodes copies above the originals and selects the copies',
      () {
        final c = editorContainer();
        final r = expectRoundTrip(
          c,
          DuplicateNodes(const ['a1', 'b1'], ids: IdGenerator.seeded(1)),
        );
        final copies = r.selectionAfter!.toList();
        expect(_kids(c, 'a'), ['a1', copies[0], 't1', 'a2']);
        expect(_kids(c, 'b'), ['b1', copies[1]]);
        expect(c.st.selection, copies.toSet());
      },
    );

    test('WrapInFrame and Group keep positions and select the frame', () {
      final c = editorContainer();
      final r = expectRoundTrip(
        c,
        WrapInFrame(const ['a1', 'a2'], ids: IdGenerator.seeded(2)),
      );
      final f = r.selectionAfter!.single;
      expect(c.node(f).common.name, 'Frame');
      expect(_kids(c, f), ['a1', 'a2']);
      expect(_xy(c, f), (10.0, 20.0));
      expect(_xy(c, 'a2'), (30.0, 80.0));
      final g = c.ctl.execute(
        WrapInFrame(const ['b1'], group: true, ids: IdGenerator.seeded(3)),
      );
      expect(c.node(g.selectionAfter!.single).common.name, 'Group');
      expect(c.st.history.undoLabel, 'Group selection');
    });

    test('UnwrapFrame releases the children in place', () {
      final c = editorContainer();
      final r = expectRoundTrip(c, const UnwrapFrame(['a']));
      expect(_kids(c, 'root').take(4), ['a1', 't1', 'a2', 'b']);
      expect(_xy(c, 'a1'), (110.0, 70.0));
      expect(_xy(c, 'a2'), (140.0, 150.0));
      expect(r.selectionAfter, {'a1', 't1', 'a2'});
      expect(DocumentIndex.of(c.doc).contains('a'), isFalse);
      final bad = c.ctl.execute(const UnwrapFrame(['b1']));
      expect(bad.ok, isFalse);
    });

    test('AddAutoLayout on a frame infers direction, gap, padding', () {
      final doc = insertNodes(fixtureDoc(), 'root', 0, [
        FrameNode(
          common: const NodeCommon(id: 'col', width: 100, height: 200),
          children: [
            shape('k2', x: 10, y: 60, w: 50, h: 20),
            shape('k1', x: 10, y: 20, w: 50, h: 20),
            shape('k3', x: 10, y: 104, w: 50, h: 20),
          ],
        ),
      ]).document;
      final c = editorContainer(doc);
      expectRoundTrip(c, const AddAutoLayout(['col']));
      final f = c.node('col') as FrameNode;
      final al = f.autoLayout!;
      expect(al.direction, LayoutDirection.vertical);
      expect(al.gap, const Gap.fixed(22)); // (20 + 24) / 2
      expect(
        al.padding,
        const EdgeInsetsValue(top: 20, left: 10, right: 40, bottom: 76),
      );
      expect(al.counterAlign, CounterAlign.start);
      expect(_kids(c, 'col'), ['k1', 'k2', 'k3']);
      expect(c.st.selection, {'col'});
    });

    test('AddAutoLayout on several nodes wraps them in a hugging frame', () {
      final c = editorContainer();
      final r = expectRoundTrip(
        c,
        AddAutoLayout(const ['a2', 'a1'], ids: IdGenerator.seeded(4)),
      );
      final f = c.node(r.selectionAfter!.single) as FrameNode;
      expect(f.autoLayout!.direction, LayoutDirection.vertical);
      expect(f.autoLayout!.gap, const Gap.fixed(70)); // 100 − 30
      expect(f.common.layoutChild.horizontalSizing, Sizing.hug);
      expect(_kids(c, f.id), ['a1', 'a2']);
    });

    test('inferAutoLayout: rows, centred counter axis, rounding', () {
      final r = inferAutoLayout([
        ('b', const StageRect(x: 40, y: 5, width: 20, height: 10)),
        ('a', const StageRect(x: 0, y: 0, width: 30, height: 20)),
        ('c', const StageRect(x: 73, y: 0, width: 10, height: 20)),
      ]);
      expect(r.layout.direction, LayoutDirection.horizontal);
      expect(r.order, ['a', 'b', 'c']);
      expect(r.layout.gap, const Gap.fixed(12)); // (10 + 13) / 2 = 11.5
      expect(r.layout.counterAlign, CounterAlign.center);
      expect(r.layout.padding, EdgeInsetsValue.zero);
      expect(inferAutoLayout(const []).order, isEmpty);
    });

    test('RemoveAutoLayout keeps children where the flow put them', () {
      final c = editorContainer();
      expectRoundTrip(c, const RemoveAutoLayout(['row']));
      final f = c.node('row') as FrameNode;
      expect(f.autoLayout, isNull);
      expect(_xy(c, 'r1'), (5.0, 5.0));
      expect(_xy(c, 'r2'), (35.0, 5.0));
      // Boxes from the canvas win over the estimate.
      final c2 = editorContainer();
      c2.ctl.execute(
        const RemoveAutoLayout(
          ['row'],
          boxes: {'r2': StageRect(x: 99, y: 1, width: 30, height: 10)},
        ),
      );
      expect(_xy(c2, 'r2'), (99.0, 1.0));
      expect(c2.ctl.execute(const RemoveAutoLayout(['a'])).ok, isFalse);
    });

    test('RenameNode, SetLocked, SetVisible', () {
      final c = editorContainer();
      expectRoundTrip(c, const RenameNode('a1', 'Dot'));
      expect(c.node('a1').common.name, 'Dot');
      expectRoundTrip(c, const SetLocked(['a1', 'b1'], true));
      expect(c.node('b1').common.locked, isTrue);
      expectRoundTrip(c, SetVisible(['a1'], false));
      expect(c.node('a1').common.visible, isFalse);
      expect(c.st.history.undoLabel, 'Hide layer');
      // Hide on mobile only.
      c.ctl
        ..setEditScope(EditScope.thisBreakpoint)
        ..setEditingBreakpoint('mobile')
        ..execute(SetVisible(['b1'], false));
      expect(c.node('b1').common.visible, isTrue);
      expect(c.resolved('b1', 'mobile').node.common.visible, isFalse);
      expect(c.resolved('b1', 'desktop').node.common.visible, isTrue);
    });

    test('NudgeNodes moves as each artboard sees it; in-flow nodes skip', () {
      final c = editorContainer();
      expectRoundTrip(c, const NudgeNodes(['a1', 'r1'], 10, -1));
      expect(_xy(c, 'a1'), (20.0, 19.0));
      expect(_xy(c, 'r1'), (0.0, 0.0));
      // "Both" cleared mobile's x patch; "This breakpoint" then nudges
      // mobile from the shared 20 into a patch.
      expect(c.node('a1').common.breakpointOverrides['mobile'], isNull);
      c.ctl
        ..setEditScope(EditScope.thisBreakpoint)
        ..setEditingBreakpoint('mobile')
        ..execute(const NudgeNodes(['a1'], 1, 0));
      expect(
        c.node('a1').common.breakpointOverrides['mobile']!['x'],
        const IrValue.number(21),
      );
      expect(c.node('a1').common.x, 20);
    });
  });

  group('scene commands', () {
    test('AddScene inserts after the active scene and activates it', () {
      final c = editorContainer();
      final r = expectRoundTrip(
        c,
        AddScene(name: 'New', ids: IdGenerator.seeded(5)),
      );
      expect(c.doc.scenes.map((s) => s.name), ['One', 'New', 'Two']);
      expect(c.st.activeSceneId, r.activeSceneAfter);
      final s = c.doc.scenes[1];
      expect(s.kind, SceneKind.pinned);
      expect((s.root.common.width, s.root.common.height), (1000.0, 800.0));
      expect(s.clocks.single, isA<SceneScrollClock>());
      final flow = c.ctl.execute(
        AddScene(kind: SceneKind.flow, index: 0, ids: IdGenerator.seeded(6)),
      );
      expect(c.doc.scenes.first.id, flow.activeSceneAfter);
      expect(c.doc.scenes.first.kind, SceneKind.flow);
    });

    test('DeleteScene activates a neighbour; the last scene stays', () {
      final c = editorContainer();
      c.ctl.select({'a'});
      expectRoundTrip(c, const DeleteScene('s1'));
      expect(c.st.activeSceneId, 's2');
      expect(c.st.selection, isEmpty);
      final last = c.ctl.execute(const DeleteScene('s2'));
      expect(last.ok, isFalse);
      expect(c.doc.scenes, hasLength(1));
    });

    test('MoveScene and UpdateSceneSettings', () {
      final c = editorContainer();
      expectRoundTrip(c, const MoveScene('s1', 2));
      expect(c.doc.scenes.map((s) => s.id), ['s2', 's1']);
      expectRoundTrip(
        c,
        const UpdateSceneSettings(
          's1',
          name: 'Opening',
          scrollLength: 3,
          exportAs: SceneExportMode.poster,
          posterClock: (value: 0.2),
        ),
      );
      final s = c.doc.scenes[1];
      expect(
        (s.name, s.scrollLength, s.exportAs, s.posterClock),
        ('Opening', 3.0, SceneExportMode.poster, 0.2),
      );
      c.ctl.execute(
        const UpdateSceneSettings('s1', posterClock: (value: null)),
      );
      expect(c.doc.scenes[1].posterClock, isNull);
      expect(
        c.ctl.execute(const UpdateSceneSettings('s1', scrollLength: -1)).ok,
        isFalse,
      );
    });
  });
}
