import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

const _none = SelectionModifiers();
const _shift = SelectionModifiers(shift: true);
const _deep = SelectionModifiers(deep: true);

SelectionState _s(Set<String> sel, [String? ctx, String? text]) =>
    SelectionState(selection: sel, context: ctx, textEditId: text);

/// Boxes in the scene root's space (as the canvas would report them).
const _boxes = {
  'a': StageRect(x: 100, y: 50, width: 300, height: 300),
  'b': StageRect(x: 500, y: 50, width: 200, height: 100),
  'inst': StageRect(x: 700, y: 300, width: 50, height: 50),
  'locked': StageRect(width: 10, height: 10),
  'row': StageRect(y: 500, width: 200, height: 20),
};

void main() {
  final resolved = resolveDocument(
    fixtureDoc(),
    const ResolveContext(breakpointId: 'desktop'),
  );
  final tree = ResolvedSelectionTree.of(resolved.scenes.first.root);

  test('the tree covers instances by resolved id', () {
    expect(tree.rootId, 'root');
    expect(tree.childrenOf('inst'), ['inst/cmpI', 'inst/cmpT']);
    expect(tree.ancestorsOf('a21'), ['root', 'a', 'a2']);
    expect(tree.isSelectable('locked'), isFalse);
    expect(tree.isSelectable('hidden'), isFalse);
    expect(tree.isText('t1'), isTrue);
    expect(
      identical(ResolvedSelectionTree.of(resolved.scenes.first.root), tree),
      isTrue,
    );
  });

  // (name, start, rule, expected)
  final cases =
      <
        (
          String,
          SelectionState,
          SelectionState Function(SelectionState),
          SelectionState,
        )
      >[
        // ---- Click ------------------------------------------------------------
        (
          'click selects the topmost child of the context',
          _s({}),
          (s) => clickSelect(tree, ['a1', 'a', 'root'], _none, s),
          _s({'a'}),
        ),
        (
          'click keeps the level of the current context',
          _s({'a1'}, 'a'),
          (s) => clickSelect(tree, ['a21', 'a2', 'a', 'root'], _none, s),
          _s({'a2'}, 'a'),
        ),
        (
          'click outside the context goes to the common level',
          _s({'a1'}, 'a'),
          (s) => clickSelect(tree, ['b1', 'b', 'root'], _none, s),
          _s({'b'}),
        ),
        (
          'click on empty space of the context selects it',
          _s({'a1'}, 'a'),
          (s) => clickSelect(tree, ['a', 'root'], _none, s),
          _s({'a'}),
        ),
        (
          'click on empty artboard clears',
          _s({'a'}),
          (s) => clickSelect(tree, ['root'], _none, s),
          _s({}),
        ),
        (
          'click passes through locked and hidden layers',
          _s({}),
          (s) => clickSelect(
            tree,
            ['locked', 'hidden', 'a1', 'a', 'root'],
            _none,
            s,
          ),
          _s({'a'}),
        ),
        (
          'click on an instance selects the instance',
          _s({}),
          (s) => clickSelect(tree, ['inst/cmpI', 'inst', 'root'], _none, s),
          _s({'inst'}),
        ),
        (
          'Cmd/Ctrl-click deep-selects',
          _s({}),
          (s) => clickSelect(tree, ['a21', 'a2', 'a', 'root'], _deep, s),
          _s({'a21'}, 'a2'),
        ),
        (
          'Cmd/Ctrl-click deep-selects inside an instance',
          _s({}),
          (s) => clickSelect(tree, ['inst/cmpI', 'inst', 'root'], _deep, s),
          _s({'inst/cmpI'}, 'inst'),
        ),
        (
          'Shift-click adds',
          _s({'a'}),
          (s) => clickSelect(tree, ['b1', 'b', 'root'], _shift, s),
          _s({'a', 'b'}),
        ),
        (
          'Shift-click removes a selected node',
          _s({'a', 'b'}),
          (s) => clickSelect(tree, ['a1', 'a', 'root'], _shift, s),
          _s({'b'}),
        ),
        (
          'Shift-click on nothing keeps the selection',
          _s({'a'}),
          (s) => clickSelect(tree, ['root'], _shift, s),
          _s({'a'}),
        ),
        (
          'a click ends text editing',
          _s({'t1'}, 'a', 't1'),
          (s) => clickSelect(tree, ['b', 'root'], _none, s),
          _s({'b'}),
        ),
        // ---- Double-click -----------------------------------------------------
        (
          'double-click enters a frame',
          _s({'a'}),
          (s) => doubleClickSelect(tree, ['a21', 'a2', 'a', 'root'], s),
          _s({'a2'}, 'a'),
        ),
        (
          'double-click on text edits it',
          _s({'t1'}, 'a'),
          (s) => doubleClickSelect(tree, ['t1', 'a', 'root'], s),
          _s({'t1'}, 'a', 't1'),
        ),
        (
          'double-click enters an instance',
          _s({'inst'}),
          (s) => doubleClickSelect(tree, ['inst/cmpT', 'inst', 'root'], s),
          _s({'inst/cmpT'}, 'inst'),
        ),
        (
          'double-click on empty frame space keeps the frame',
          _s({'a'}),
          (s) => doubleClickSelect(tree, ['a', 'root'], s),
          _s({'a'}),
        ),
        (
          'double-click on nothing changes nothing',
          _s({'a'}),
          (s) => doubleClickSelect(tree, const [], s),
          _s({'a'}),
        ),
        // ---- Keyboard ---------------------------------------------------------
        (
          'Esc selects the parent',
          _s({'a21'}, 'a2'),
          (s) => selectParent(tree, s),
          _s({'a2'}, 'a'),
        ),
        (
          'Esc at the top level clears',
          _s({'a', 'b'}),
          (s) => selectParent(tree, s),
          _s({}),
        ),
        (
          'Esc stops text editing first',
          _s({'t1'}, 'a', 't1'),
          (s) => selectParent(tree, s),
          _s({'t1'}, 'a'),
        ),
        (
          'Enter selects the children',
          _s({'a'}),
          (s) => selectChildren(tree, s),
          _s({'a1', 't1', 'a2'}, 'a'),
        ),
        (
          'Enter on text edits it',
          _s({'t1'}, 'a'),
          (s) => selectChildren(tree, s),
          _s({'t1'}, 'a', 't1'),
        ),
        (
          'Enter on a leaf changes nothing',
          _s({'a1'}, 'a'),
          (s) => selectChildren(tree, s),
          _s({'a1'}, 'a'),
        ),
        (
          'Tab selects the next sibling',
          _s({'a1'}, 'a'),
          (s) => selectSibling(tree, s),
          _s({'t1'}, 'a'),
        ),
        (
          'Shift-Tab wraps to the last sibling',
          _s({'a1'}, 'a'),
          (s) => selectSibling(tree, s, backwards: true),
          _s({'a2'}, 'a'),
        ),
        (
          'Tab skips locked and hidden siblings',
          _s({'inst'}),
          (s) => selectSibling(tree, s),
          _s({'row'}),
        ),
        (
          'Tab with nothing selected picks the first child',
          _s({}, 'a'),
          (s) => selectSibling(tree, s),
          _s({'a1'}, 'a'),
        ),
        (
          'select all takes the selection\'s siblings',
          _s({'a1'}, 'a'),
          (s) => selectAll(tree, s),
          _s({'a1', 't1', 'a2'}, 'a'),
        ),
        (
          'select all with nothing selected takes the context',
          _s({}),
          (s) => selectAll(tree, s),
          _s({'a', 'b', 'inst', 'row'}),
        ),
        (
          'select none keeps the context',
          _s({'a1'}, 'a'),
          selectNone,
          _s({}, 'a'),
        ),
        // ---- Marquee ----------------------------------------------------------
        (
          'marquee selects nodes fully inside, in the context',
          _s({}),
          (s) => marqueeSelect(
            tree,
            const StageRect(x: 50, y: 0, width: 660, height: 400),
            _boxes,
            _none,
            s,
          ),
          _s({'a', 'b'}),
        ),
        (
          'marquee ignores partly covered nodes',
          _s({}),
          (s) => marqueeSelect(
            tree,
            const StageRect(x: 50, y: 0, width: 600, height: 400),
            _boxes,
            _none,
            s,
          ),
          _s({'a'}),
        ),
        (
          'Shift-marquee adds',
          _s({'row'}),
          (s) => marqueeSelect(
            tree,
            const StageRect(x: 450, y: 0, width: 300, height: 400),
            _boxes,
            _shift,
            s,
          ),
          _s({'row', 'b', 'inst'}),
        ),
        (
          'marquee skips locked nodes',
          _s({}),
          (s) => marqueeSelect(
            tree,
            const StageRect(x: -1, y: -1, width: 20, height: 20),
            _boxes,
            _none,
            s,
          ),
          _s({}),
        ),
      ];

  for (final (name, start, rule, expected) in cases) {
    test(name, () {
      final out = rule(start);
      expect(
        out.selection.toList(),
        expected.selection.toList(),
        reason: 'selection',
      );
      expect(out.context, expected.context, reason: 'context');
      expect(out.textEditId, expected.textEditId, reason: 'textEditId');
    });
  }

  test('the controller applies the rules to the active scene', () {
    final c = editorContainer();
    c.ctl.click(['a1', 'a', 'root'], _none);
    expect(c.st.selection, {'a'});
    c.ctl.doubleClick(['a1', 'a', 'root']);
    expect(c.st.selection, {'a1'});
    expect(c.st.selectionContext, 'a');
    c.ctl.selectNextSibling();
    expect(c.st.selection, {'t1'});
    c.ctl.selectChildrenOfSelection();
    expect(c.st.textEditId, 't1');
    c.ctl.selectParentOfSelection();
    expect(c.st.textEditId, isNull);
    c.ctl.selectParentOfSelection();
    expect(c.st.selection, {'a'});
    c.ctl.marquee(
      const StageRect(x: 0, y: 0, width: 1000, height: 800),
      _boxes,
      _none,
    );
    expect(c.st.selection, {'a', 'b', 'inst', 'row'});
    c.ctl.clearSelection();
    expect(c.st.selection, isEmpty);
  });
}
