import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

const _half = IrValue.number(0.5);

void main() {
  group('This breakpoint writes to the breakpoint in effect', () {
    // kBreakpoints: desktop ≥1024 (design 1000), tablet ≥600 inheriting
    // desktop, mobile ≥0.
    for (final (artboard, width, expected) in [
      ('desktop', null, 'desktop'),
      ('desktop', 1300.0, 'desktop'),
      ('desktop', 800.0, 'tablet'),
      ('desktop', 500.0, 'mobile'),
      ('mobile', 700.0, 'tablet'),
      ('mobile', 300.0, 'mobile'),
    ]) {
      test('$artboard artboard at ${width ?? 'design'} px → $expected', () {
        final c = editorContainer();
        c.ctl
          ..setEditingBreakpoint(artboard)
          ..setArtboardWidths({artboard: ?width})
          ..setEditScope(EditScope.thisBreakpoint);
        expect(c.st.artboardId, artboard);
        expect(c.st.breakpointId, expected);
        expectRoundTrip(c, SetProperty(['a1'], 'opacity', _half));
        final patches = c.node('a1').common.breakpointOverrides;
        expect(patches[expected]!['opacity'], _half);
        for (final other in ['desktop', 'mobile', 'tablet']) {
          if (other != expected) {
            expect(patches[other]?['opacity'], isNull, reason: other);
          }
        }
        expect(c.resolved('a1', expected).node.common.opacity, 0.5);
      });
    }

    test('back at the design width it is the artboard\'s own again', () {
      final c = editorContainer();
      c.ctl
        ..setEditingBreakpoint('desktop')
        ..setArtboardWidths({'desktop': 800});
      expect(c.st.breakpointId, 'tablet');
      c.ctl.setArtboardWidths(const {});
      expect(c.st.breakpointId, 'desktop');
    });

    test('provenance and reset follow the effective breakpoint', () {
      final c = editorContainer();
      c.ctl
        ..setEditingBreakpoint('desktop')
        ..setArtboardWidths({'desktop': 800})
        ..setEditScope(EditScope.thisBreakpoint)
        ..execute(SetProperty(['a1'], 'opacity', _half));
      final p = c.ctl.provenanceFor('a1', 'opacity');
      expect(
        p.entries.last.source,
        isA<BreakpointPatchSource>().having(
          (s) => s.breakpointId,
          'breakpointId',
          'tablet',
        ),
      );
      c.ctl.resetProperty('opacity', ['a1']);
      expect(c.node('a1').common.breakpointOverrides['tablet'], isNull);
    });
  });

  group('ResetBreakpointOverrides', () {
    StageDocument patched() {
      final c = editorContainer();
      c.ctl.setEditScope(EditScope.thisBreakpoint);
      for (final bp in ['desktop', 'mobile']) {
        c.ctl
          ..setEditingBreakpoint(bp)
          ..execute(SetProperty(['a1', 'a2'], 'opacity', _half))
          ..execute(SetProperty(['a1'], 'x', const IrValue.number(9)));
      }
      return c.doc;
    }

    test('clears every patch of the node on that breakpoint only', () {
      final c = editorContainer(patched());
      c.ctl.setEditingBreakpoint('mobile');
      expect(hasOverridesOn(c.doc, ['a1'], 'mobile'), isTrue);
      final r = expectRoundTrip(c, const ResetBreakpointOverrides(['a1']));
      expect(r.label, 'Reset overrides on Mobile');
      final o = c.node('a1').common.breakpointOverrides;
      expect(o['mobile'], isNull);
      expect(o['desktop'], isNotNull);
      expect(
        c.node('a2').common.breakpointOverrides['mobile'],
        isNotNull,
        reason: 'not selected',
      );
      expect(hasOverridesOn(c.doc, ['a1'], 'mobile'), isFalse);
    });

    test('an explicit breakpoint, and nothing to reset', () {
      final c = editorContainer(patched());
      expectRoundTrip(
        c,
        const ResetBreakpointOverrides(['a1', 'a2'], breakpointId: 'desktop'),
      );
      expect(c.node('a2').common.breakpointOverrides['desktop'], isNull);
      final again = c.ctl.execute(
        const ResetBreakpointOverrides(['a1'], breakpointId: 'desktop'),
      );
      expect(again.changed, isFalse);
    });
  });

  group('breakpoint manager commands', () {
    const wide = Breakpoint(
      id: 'wide',
      name: 'Wide',
      minWidth: 1800,
      designSize: StageSize(width: 1920, height: 1080),
      inheritsFrom: 'desktop',
      primary: true,
    );

    test('add a primary breakpoint (undoable); it gets an artboard', () {
      final c = editorContainer();
      final r = expectRoundTrip(c, const AddBreakpoint(wide));
      expect(r.label, 'Add breakpoint Wide');
      expect(c.doc.primaryBreakpoints.map((b) => b.id), contains('wide'));
    });

    test('edit: tablet becomes primary; a cycle is refused and not '
        'recorded', () {
      final c = editorContainer();
      expectRoundTrip(
        c,
        UpdateBreakpoint(kBreakpoints[2].copyWith(primary: true)),
      );
      expect(c.doc.primaryBreakpoints, hasLength(3));
      final depth = c.ctl.history.undoDepth;
      final bad = c.ctl.execute(
        UpdateBreakpoint(kBreakpoints[0].copyWith(inheritsFrom: 'tablet')),
      );
      expect(bad.ok, isFalse);
      expect(
        bad.diagnostics.map((d) => d.kind),
        contains(IrDiagnosticKind.breakpointCycle),
      );
      expect(c.ctl.history.undoDepth, depth);
    });

    test('remove drops its patches; undo brings them back', () {
      final c = editorContainer();
      c.ctl
        ..setEditingBreakpoint('desktop')
        ..setArtboardWidths({'desktop': 800})
        ..setEditScope(EditScope.thisBreakpoint)
        ..execute(SetProperty(['a1'], 'opacity', _half));
      expect(patchedNodeCount(c.doc, 'tablet'), 1);
      expectRoundTrip(c, const RemoveBreakpoint('tablet'));
      expect(c.doc.breakpoints.map((b) => b.id), ['desktop', 'mobile']);
      expect(c.node('a1').common.breakpointOverrides['tablet'], isNull);
      // Without tablet, a free width of 800 falls in mobile.
      expect(c.st.breakpointId, 'mobile');
      c.ctl.undo();
      expect(c.node('a1').common.breakpointOverrides['tablet'], isNotNull);
    });

    test('the last primary breakpoint cannot be removed', () {
      final c = editorContainer();
      expect(c.ctl.execute(const RemoveBreakpoint('mobile')).ok, isTrue);
      expect(c.ctl.execute(const RemoveBreakpoint('desktop')).ok, isFalse);
    });
  });
}
