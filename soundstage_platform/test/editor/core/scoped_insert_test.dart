import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

/// The node [id]'s `visible` patch on [bp], or null when it has none.
Object? _patch(Node node, String bp) =>
    node.common.breakpointOverrides[bp]?['visible'];

void main() {
  const hidden = IrValue.boolean(false);

  group('insert follows the edit scope (T1.9b)', () {
    test('Both: the node is plain, with no patches', () {
      final c = editorContainer();
      expectRoundTrip(c, InsertNodes('b', [shape('n1')]));
      expect(c.node('n1').common.breakpointOverrides, isEmpty);
    });

    for (final edited in ['desktop', 'mobile']) {
      final other = edited == 'desktop' ? 'mobile' : 'desktop';
      test('This breakpoint ($edited artboard): hidden on $other only', () {
        final c = editorContainer();
        c.ctl
          ..setEditingBreakpoint(edited)
          ..setEditScope(EditScope.thisBreakpoint);
        final r = expectRoundTrip(c, InsertNodes('b', [shape('n1')]));
        expect(r.label, 'Insert layer');
        final n = c.node('n1');
        expect(n.common.visible, isTrue, reason: 'the base stays visible');
        expect(_patch(n, other), hidden);
        expect(_patch(n, edited), isNull);
        expect(c.resolved('n1', edited).node.common.visible, isTrue);
        expect(c.resolved('n1', other).node.common.visible, isFalse);
      });
    }

    test('Alt flips the scope for one insert', () {
      final c = editorContainer();
      c.ctl
        ..setEditingBreakpoint('mobile')
        ..setScopeFlipped(true);
      c.ctl.execute(InsertNodes('b', [shape('n1')]));
      expect(_patch(c.node('n1'), 'desktop'), hidden);
    });

    test('several nodes, one undo step', () {
      final c = editorContainer();
      c.ctl
        ..setEditingBreakpoint('mobile')
        ..setEditScope(EditScope.thisBreakpoint);
      c.ctl.execute(InsertNodes('b', [shape('n1'), shape('n2')]));
      expect(_patch(c.node('n1'), 'desktop'), hidden);
      expect(_patch(c.node('n2'), 'desktop'), hidden);
      expect(c.ctl.undo(), isTrue);
      expect(DocumentIndex.of(c.doc).node('n1'), isNull);
      expect(DocumentIndex.of(c.doc).node('n2'), isNull);
    });

    for (final scope in EditScope.values) {
      test('PasteNodes under $scope', () {
        final c = editorContainer();
        c.ctl
          ..setEditingBreakpoint('mobile')
          ..setEditScope(scope);
        final payload = PastePayload(nodes: [shape('src').toJson()]);
        final r = c.ctl.execute(PasteNodes(payload, 'b'));
        expect(r.ok, isTrue, reason: '${r.diagnostics}');
        final id = c.st.selection.single;
        final n = c.node(id);
        if (scope == EditScope.both) {
          expect(_patch(n, 'desktop'), isNull);
        } else {
          expect(_patch(n, 'desktop'), hidden);
          expect(_patch(n, 'mobile'), isNull);
        }
        expect(c.ctl.undo(), isTrue);
        expect(DocumentIndex.of(c.doc).node(id), isNull);
      });
    }
  });
}
