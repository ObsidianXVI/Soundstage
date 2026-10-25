import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

SetProperty _x(String id, double x) =>
    SetProperty([id], 'x', IrValue.number(x));

HistorySnapshot _snap(int rev) =>
    HistorySnapshot(document: fixtureDoc(), revision: rev);

void main() {
  group('History', () {
    test('coalesces equal keys within one gesture only', () {
      final h = History();
      void rec(int i, String? key) => h.record(
        label: 'l$i',
        before: _snap(i),
        after: _snap(i + 1),
        coalesceKey: key,
      );
      h.beginGesture();
      rec(0, 'k');
      rec(1, 'k');
      rec(2, 'k');
      expect(h.undoDepth, 1);
      expect(h.entries.single.before.revision, 0);
      expect(h.entries.single.after.revision, 3);
      rec(3, 'other');
      rec(4, null);
      rec(5, null);
      expect(h.undoDepth, 4, reason: 'other key and null keys never merge');
      h.endGesture();
      rec(6, 'k');
      rec(7, 'k');
      expect(h.undoDepth, 6, reason: 'outside a gesture nothing coalesces');
      h
        ..beginGesture()
        ..beginGesture(); // nested: same gesture
      rec(8, 'g');
      rec(9, 'g');
      h.endGesture();
      h.beginGesture();
      rec(10, 'g');
      h.endGesture();
      expect(h.undoDepth, 8, reason: 'a new gesture starts a new entry');
    });

    test('caps at 200 entries, dropping the oldest', () {
      final h = History();
      for (var i = 0; i < 205; i++) {
        h.record(label: '$i', before: _snap(i), after: _snap(i + 1));
      }
      expect(h.undoDepth, 200);
      expect(h.entries.first.label, '5');
      var undone = 0;
      while (h.undo() != null) {
        undone++;
      }
      expect(undone, 200);
      expect(h.redoDepth, 200);
    });

    test('recording after undo drops the redo stack (branching)', () {
      final h = History();
      h.record(label: 'a', before: _snap(0), after: _snap(1));
      h.record(label: 'b', before: _snap(1), after: _snap(2));
      expect(h.undo()!.revision, 1);
      expect(h.canRedo, isTrue);
      h.record(label: 'c', before: _snap(1), after: _snap(3));
      expect(h.canRedo, isFalse);
      expect(h.undoLabel, 'c');
      expect(h.redo(), isNull);
    });
  });

  group('EditorController history', () {
    test('a drag in a gesture is one undo entry', () {
      final c = editorContainer();
      final start = c.doc;
      c.ctl.beginGesture();
      for (var i = 1; i <= 30; i++) {
        c.ctl.execute(_x('a1', 10.0 + i));
      }
      c.ctl.endGesture();
      expect(c.ctl.history.undoDepth, 1);
      expect(c.node('a1').common.x, 40);
      c.ctl.undo();
      expect(identical(c.doc, start), isTrue);
      c.ctl.redo();
      expect(c.node('a1').common.x, 40);
    });

    test('two drags are two entries; a different node is a new entry', () {
      final c = editorContainer();
      for (final id in ['a1', 'a1', 'b1']) {
        c.ctl.beginGesture();
        c.ctl
          ..execute(_x(id, 1))
          ..execute(_x(id, 2));
        c.ctl.endGesture();
      }
      expect(c.ctl.history.undoDepth, 3);
      c.ctl.beginGesture();
      c.ctl
        ..execute(_x('a1', 5))
        ..execute(_x('b1', 5))
        ..execute(_x('a1', 6));
      c.ctl.endGesture();
      expect(c.ctl.history.undoDepth, 6);
    });

    test('undo/redo restore the selection with the document', () {
      final c = editorContainer();
      c.ctl.select({'a1'});
      c.ctl.execute(const DeleteNodes(['a1']));
      c.ctl.select({'b'});
      c.ctl.execute(_x('b', 0));
      c.ctl.undo();
      expect(c.st.selection, {'b'});
      c.ctl.undo();
      expect(c.st.selection, {'a1'});
      expect(DocumentIndex.of(c.doc).contains('a1'), isTrue);
      c.ctl.redo();
      expect(c.st.selection, isEmpty);
      expect(
        c.st.history,
        const HistoryStatus(
          canUndo: true,
          canRedo: true,
          undoLabel: 'Delete layer',
          redoLabel: 'Change x',
        ),
      );
    });

    test('a selection of nodes an edit removed is pruned', () {
      final c = editorContainer();
      c.ctl.select({'a1', 'b1', 'inst/cmpI'});
      c.ctl.execute(_RemoveOnly('b1'));
      expect(c.st.selection, {'a1', 'inst/cmpI'});
      c.ctl.execute(_RemoveOnly('inst'));
      expect(c.st.selection, {'a1'});
    });

    test('failed and no-op commands are not recorded', () {
      final c = editorContainer();
      final rev = c.st.revision;
      expect(c.ctl.execute(const DeleteNodes(['nope'])).ok, isFalse);
      expect(c.ctl.execute(_x('b1', 1)).changed, isFalse);
      expect(c.ctl.history.canUndo, isFalse);
      expect(c.st.revision, rev);
    });

    test('revisions and dirty tracking survive undo', () {
      final c = editorContainer();
      expect(c.st.isDirty, isFalse);
      c.ctl.execute(_x('a1', 1));
      expect(c.st.isDirty, isTrue);
      c.ctl.markSaved();
      expect(c.st.isDirty, isFalse);
      c.ctl.execute(_x('a1', 2));
      expect(c.st.isDirty, isTrue);
      c.ctl.undo();
      expect(c.st.isDirty, isFalse, reason: 'back at the saved revision');
      c.ctl.undo();
      expect(c.st.isDirty, isTrue);
    });

    test('openDocument resets history and state', () {
      final c = editorContainer();
      c.ctl.execute(_x('a1', 1));
      c.ctl.openDocument(fixtureDoc());
      expect(c.ctl.history.canUndo, isFalse);
      expect(c.st.isDirty, isFalse);
      expect(c.st.activeSceneId, 's1');
    });
  });

  group('EditorController state', () {
    test('scope toggle, Alt flip, scene and artboard, hover, playhead', () {
      final c = editorContainer();
      expect(c.st.editingBreakpointId, 'desktop');
      c.ctl.toggleEditScope();
      expect(c.st.effectiveScope, EditScope.thisBreakpoint);
      c.ctl.setScopeFlipped(true);
      expect(c.st.effectiveScope, EditScope.both);
      c.ctl
        ..setEditingBreakpoint('mobile')
        ..setEditingBreakpoint('nope');
      expect(c.st.breakpointId, 'mobile');
      c.ctl
        ..select({'a1'})
        ..hover('b1')
        ..setActiveScene('s2');
      expect(c.st.activeSceneId, 's2');
      expect(c.st.selection, isEmpty);
      expect(c.st.hoverId, isNull);
      c.ctl
        ..setPlayhead('s2', 'clk', 0.25)
        ..setTool(EditorTool.text);
      expect(c.st.playheadOf('s2', 'clk'), 0.25);
      expect(c.st.tool, EditorTool.text);
    });

    test('resolvedFor keeps one incremental resolver per breakpoint', () {
      final c = editorContainer();
      final d0 = c.read(resolvedForProvider('desktop'));
      final m0 = c.read(resolvedForProvider('mobile'));
      expect(m0.resolved.nodeIndex['a1']!.node.common.x, 30);
      expect(d0.resolved.nodeIndex['a1']!.node.common.x, 10);
      c.ctl.execute(SetProperty(['b1'], 'opacity', const IrValue.number(0.5)));
      final d1 = c.read(resolvedForProvider('desktop'));
      final m1 = c.read(resolvedForProvider('mobile'));
      for (final (before, after) in [(d0, d1), (m0, m1)]) {
        expect(identical(before, after), isFalse);
        // Off the edited path, resolved nodes are reused.
        expect(
          identical(
            before.resolved.nodeIndex['a']!,
            after.resolved.nodeIndex['a']!,
          ),
          isTrue,
        );
        expect(after.resolved.nodeIndex['b1']!.node.common.opacity, 0.5);
      }
      // Hover and selection don't re-resolve.
      c.ctl.hover('a');
      expect(identical(c.read(resolvedForProvider('desktop')), d1), isTrue);
    });

    test('provenanceFor explains at the requested breakpoint', () {
      final c = editorContainer();
      expect(
        c.ctl.provenanceFor('a1', 'x', 'mobile').entries.map((e) => e.source),
        [
          const ProvenanceSource.base(),
          const ProvenanceSource.breakpointPatch('mobile'),
        ],
      );
      expect(
        c.ctl.provenanceFor('a1', 'x').finalValue,
        const IrValue.number(10),
      );
    });
  });
}

class _RemoveOnly extends EditCommand {
  _RemoveOnly(this.id);

  final String id;

  @override
  String get label => 'Remove';

  @override
  CommandResult apply(EditorState state) =>
      resultOf(state, removeNodes(state.document, [id]), label: label);
}
