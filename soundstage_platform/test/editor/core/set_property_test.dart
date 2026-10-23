import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

const _half = IrValue.number(0.5);

/// A fixture where a1 also has desktop, mobile and tablet opacity patches.
StageDocument _patched() => updateNode(
  fixtureDoc(),
  'a1',
  (n) => n.copyWith(
    common: n.common.copyWith(
      breakpointOverrides: {
        'desktop': {'opacity': const IrValue.number(0.9)},
        'mobile': {
          'x': const IrValue.number(30),
          'opacity': const IrValue.number(0.8),
        },
        'tablet': {'opacity': const IrValue.number(0.7)},
      },
    ),
  ),
).document;

double _opacity(ProviderContainer c, String id, String bp) =>
    c.resolved(id, bp).node.common.opacity;

void main() {
  group('SetProperty routing (§15): node × scope × breakpoint', () {
    for (final editing in ['desktop', 'mobile', 'tablet']) {
      test('Both, editing $editing: writes the base, clears the primary '
          'patches', () {
        final c = editorContainer(_patched());
        c.ctl.setEditingBreakpoint(editing);
        expectRoundTrip(c, SetProperty(['a1'], 'opacity', _half));
        final a1 = c.node('a1').common;
        expect(a1.opacity, 0.5);
        expect(a1.breakpointOverrides['desktop'], isNull);
        expect(a1.breakpointOverrides['mobile'], {
          'x': const IrValue.number(30),
        });
        // Not primary: tablet keeps its own patch.
        expect(a1.breakpointOverrides['tablet'], {
          'opacity': const IrValue.number(0.7),
        });
        expect(_opacity(c, 'a1', 'desktop'), 0.5);
        expect(_opacity(c, 'a1', 'mobile'), 0.5);
        expect(_opacity(c, 'a1', 'tablet'), 0.7);
      });

      test('This breakpoint, editing $editing: writes $editing\'s patch', () {
        final c = editorContainer(_patched());
        c.ctl
          ..setEditingBreakpoint(editing)
          ..setEditScope(EditScope.thisBreakpoint);
        expectRoundTrip(c, SetProperty(['a1'], 'opacity', _half));
        final a1 = c.node('a1').common;
        expect(a1.opacity, 1, reason: 'base untouched');
        expect(a1.breakpointOverrides[editing]!['opacity'], _half);
        for (final other in ['desktop', 'mobile', 'tablet']) {
          if (other == editing) continue;
          expect(
            a1.breakpointOverrides[other]!['opacity'],
            isNot(_half),
            reason: other,
          );
        }
        expect(_opacity(c, 'a1', editing), 0.5);
      });
    }

    test('Alt flips the scope for the edits made while it is held', () {
      final c = editorContainer(_patched());
      c.ctl.setScopeFlipped(true);
      expect(c.st.effectiveScope, EditScope.thisBreakpoint);
      c.ctl.execute(SetProperty(['a1'], 'opacity', _half));
      expect(
        c.node('a1').common.breakpointOverrides['desktop']!['opacity'],
        _half,
      );
      c.ctl.setScopeFlipped(false);
      c.ctl.execute(SetProperty(['a1'], 'opacity', const IrValue.number(0.25)));
      expect(c.node('a1').common.opacity, 0.25);
      expect(c.node('a1').common.breakpointOverrides['desktop'], isNull);
    });

    for (final scope in EditScope.values) {
      test('inside an instance → instance override (scope ${scope.name})', () {
        final c = editorContainer();
        c.ctl
          ..setEditScope(scope)
          ..setEditingBreakpoint('mobile');
        expect(routeFor(c.st, 'inst/cmpI'), WriteTarget.instanceOverride);
        expectRoundTrip(c, SetProperty(['inst/cmpI'], 'opacity', _half));
        final inst = c.node('inst') as InstanceNode;
        expect(inst.overrides, {
          'cmpI': {'opacity': _half},
        });
        expect(c.node('inst').common.breakpointOverrides, isEmpty);
        // Overrides apply at every breakpoint.
        for (final bp in ['desktop', 'mobile', 'tablet']) {
          expect(_opacity(c, 'inst/cmpI', bp), 0.5, reason: bp);
        }
      });
    }

    test('the instance itself routes like any node', () {
      final c = editorContainer();
      c.ctl.setEditScope(EditScope.thisBreakpoint);
      c.ctl.execute(SetProperty(['inst'], 'opacity', _half));
      expect(c.node('inst').common.breakpointOverrides['desktop'], {
        'opacity': _half,
      });
    });

    for (final scope in EditScope.values) {
      test('multi-selection applies per node (scope ${scope.name})', () {
        final c = editorContainer();
        c.ctl
          ..setEditScope(scope)
          ..setEditingBreakpoint('mobile');
        expectRoundTrip(
          c,
          SetProperty(['a1', 'inst/cmpI', 'b1'], 'opacity', _half),
        );
        for (final id in ['a1', 'b1']) {
          final common = c.node(id).common;
          if (scope == EditScope.both) {
            expect(common.opacity, 0.5);
          } else {
            expect(common.breakpointOverrides['mobile']!['opacity'], _half);
          }
          expect(_opacity(c, id, 'mobile'), 0.5);
        }
        expect((c.node('inst') as InstanceNode).overrides['cmpI'], {
          'opacity': _half,
        });
      });
    }

    test('a property some selected nodes lack applies to the others', () {
      final c = editorContainer();
      final r = c.ctl.execute(
        SetProperty(['t1', 'a1'], 'style.fontSize', const IrValue.number(30)),
      );
      expect(r.ok, isTrue);
      expect((c.node('t1') as TextNode).style.fontSize, 30);
      expect(r.diagnostics.single.severity, IrSeverity.warning);
      expect(r.diagnostics.single.nodeId, 'a1');
    });

    test('per-node values (a drag) and unknown paths', () {
      final c = editorContainer();
      c.ctl.execute(
        SetProperty.values({
          'a1': {'x': const IrValue.number(1), 'y': const IrValue.number(2)},
          'b1': {'x': const IrValue.number(3)},
        }),
      );
      expect((c.node('a1').common.x, c.node('a1').common.y), (1.0, 2.0));
      expect(c.node('b1').common.x, 3);
      final bad = c.ctl.execute(SetProperty(['a1'], 'nope', _half));
      expect(bad.ok, isFalse);
      expect(bad.diagnostics.single.kind, IrDiagnosticKind.unknownPath);
      expect(c.st.history.undoLabel, 'Change properties');
    });

    test('auto-key is reserved for M2: writes route as usual', () {
      final c = editorContainer();
      c.ctl.setAutoKey(true);
      c.ctl.execute(SetProperty(['a1'], 'opacity', _half));
      expect(c.node('a1').common.opacity, 0.5);
      expect(c.doc.scenes.first.tracks, isEmpty);
    });
  });

  group('ResetProperty via provenance', () {
    test('This breakpoint removes the edited breakpoint\'s own patch', () {
      final c = editorContainer(_patched());
      c.ctl
        ..setEditScope(EditScope.thisBreakpoint)
        ..setEditingBreakpoint('mobile');
      final before = c.ctl.provenanceFor('a1', 'x');
      expect(
        before.entries.last.source,
        const ProvenanceSource.breakpointPatch('mobile'),
      );
      final r = c.ctl.resetProperty('x', ['a1']);
      expect(r.ok && r.changed, isTrue);
      expect(c.node('a1').common.breakpointOverrides['mobile'], {
        'opacity': const IrValue.number(0.8),
      });
      expect(
        c.ctl.provenanceFor('a1', 'x').finalValue,
        const IrValue.number(10),
      );
      c.ctl.undo();
      expect(
        c.node('a1').common.breakpointOverrides['mobile']!['x'],
        isNotNull,
      );
    });

    test('an inherited patch is not this breakpoint\'s to reset', () {
      final doc = updateNode(
        fixtureDoc(),
        'a1',
        (n) => n.copyWith(
          common: n.common.copyWith(
            breakpointOverrides: {
              'desktop': {'opacity': const IrValue.number(0.9)},
            },
          ),
        ),
      ).document;
      final c = editorContainer(doc);
      c.ctl
        ..setEditScope(EditScope.thisBreakpoint)
        ..setEditingBreakpoint('tablet');
      final r = c.ctl.resetProperty('opacity', ['a1']);
      expect(r.changed, isFalse);
      expect(r.diagnostics.single.severity, IrSeverity.warning);
      expect(c.st.history.canUndo, isFalse, reason: 'no-ops are not recorded');
    });

    test('Both clears the primary patches (and the edited breakpoint\'s)', () {
      final c = editorContainer(_patched());
      c.ctl.setEditingBreakpoint('tablet');
      c.ctl.resetProperty('opacity', ['a1']);
      final o = c.node('a1').common.breakpointOverrides;
      expect(o['desktop'], isNull);
      expect(o['mobile'], {'x': const IrValue.number(30)});
      expect(o['tablet'], isNull);
      expect(_opacity(c, 'a1', 'tablet'), 1);
    });

    test('removes an instance override', () {
      final c = editorContainer();
      c.ctl.execute(SetProperty(['inst/cmpI'], 'opacity', _half));
      expect(
        c.ctl.provenanceFor('inst/cmpI', 'opacity').entries.last.source,
        const ProvenanceSource.instanceOverride('inst', 'cmpI'),
      );
      c.ctl.resetProperty('opacity', ['inst/cmpI']);
      expect((c.node('inst') as InstanceNode).overrides, isEmpty);
      expect(_opacity(c, 'inst/cmpI', 'desktop'), 1);
    });

    test('a base value has nothing to reset', () {
      final c = editorContainer();
      c.ctl.execute(SetProperty(['b1'], 'opacity', _half));
      final r = c.ctl.resetProperty('opacity', ['b1']);
      expect(r.changed, isFalse);
      expect(c.node('b1').common.opacity, 0.5);
    });

    test('passes over a token layer to the patch beneath it', () {
      final doc = fixtureDoc().copyWith(
        tokens: const TokenSystem(
          collections: [
            VariableCollection(
              id: 'col',
              name: 'c',
              modes: [TokenMode(id: 'm', name: 'm')],
              defaultModeId: 'm',
              variables: [
                Variable(
                  id: 'v',
                  name: 'v',
                  type: VariableType.number,
                  valuesByMode: {'m': IrValue.number(0.3)},
                ),
              ],
            ),
          ],
        ),
      );
      final c = editorContainer(doc);
      c.ctl
        ..setEditScope(EditScope.thisBreakpoint)
        ..execute(
          SetProperty(
            ['b1'],
            'opacity',
            const IrValue.tokenRef(TokenRef(variableId: 'v')),
          ),
        );
      expect(_opacity(c, 'b1', 'desktop'), 0.3);
      c.ctl.resetProperty('opacity', ['b1']);
      expect(c.node('b1').common.breakpointOverrides, isEmpty);
      expect(_opacity(c, 'b1', 'desktop'), 1);
    });
  });
}
