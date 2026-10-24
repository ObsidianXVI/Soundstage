import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _desktop = Breakpoint(
  id: 'desktop',
  name: 'Desktop',
  minWidth: 1024,
  designSize: StageSize(width: 1440, height: 900),
  primary: true,
);
const _mobile = Breakpoint(
  id: 'mobile',
  name: 'Mobile',
  minWidth: 0,
  designSize: StageSize(width: 390, height: 844),
  primary: true,
);
const _tablet = Breakpoint(
  id: 'tablet',
  name: 'Tablet',
  minWidth: 600,
  designSize: StageSize(width: 834, height: 1112),
  inheritsFrom: 'desktop',
);

ShapeNode _shape(String id, Map<String, Map<String, IrValue>> patches) =>
    ShapeNode(
      common: NodeCommon(
        id: id,
        width: 10,
        height: 10,
        breakpointOverrides: patches,
      ),
    );

StageDocument _doc() => StageDocument(
  id: 'd',
  breakpoints: const [_desktop, _mobile, _tablet],
  scenes: [
    Scene(
      id: 's1',
      root: FrameNode(
        common: const NodeCommon(id: 'root', width: 100, height: 100),
        children: [
          _shape('a', {
            'tablet': {'x': const IrValue.number(5)},
            'mobile': {'y': const IrValue.number(7)},
          }),
          _shape('b', const {}),
        ],
      ),
      tracks: const [
        Track(
          id: 't1',
          target: 'a',
          property: 'opacity',
          clockId: 'c',
          breakpoints: ['tablet'],
        ),
        Track(
          id: 't2',
          target: 'a',
          property: 'opacity',
          clockId: 'c',
          breakpoints: ['tablet', 'desktop'],
        ),
      ],
    ),
    Scene(
      id: 's2',
      root: FrameNode(
        common: const NodeCommon(id: 'root2', width: 100, height: 100),
        children: [_shape('c', const {})],
      ),
    ),
  ],
  components: {
    'k': const ComponentDef(
      id: 'k',
      name: 'k',
      root: FrameNode(
        common: NodeCommon(
          id: 'kR',
          breakpointOverrides: {
            'tablet': {'width': IrValue.number(3)},
          },
        ),
      ),
    ),
  },
);

void main() {
  group('validateBreakpointList', () {
    test('accepts the default list', () {
      expect(
        validateBreakpointList(const [_desktop, _mobile, _tablet]),
        isEmpty,
      );
    });

    test('rejects cycles, self-inheritance and unknown parents', () {
      final cyc = validateBreakpointList([
        _desktop.copyWith(inheritsFrom: 'tablet'),
        _mobile,
        _tablet,
      ]);
      expect(
        cyc.map((d) => d.kind),
        contains(IrDiagnosticKind.breakpointCycle),
      );
      expect(
        validateBreakpointList([
          _desktop,
          _mobile.copyWith(inheritsFrom: 'mobile'),
        ]).single.kind,
        IrDiagnosticKind.breakpointCycle,
      );
      expect(
        validateBreakpointList([
          _desktop,
          _mobile.copyWith(inheritsFrom: 'nope'),
        ]).single.kind,
        IrDiagnosticKind.missingBreakpoint,
      );
    });

    test('rejects duplicates, empty names, bad sizes and no primary', () {
      expect(
        validateBreakpointList([_desktop, _desktop]).single.kind,
        IrDiagnosticKind.duplicateId,
      );
      expect(
        validateBreakpointList([_desktop.copyWith(name: ' ')]).single.kind,
        IrDiagnosticKind.invalidValue,
      );
      expect(
        validateBreakpointList([
          _desktop.copyWith(designSize: const StageSize(width: 0, height: 9)),
        ]).single.kind,
        IrDiagnosticKind.invalidValue,
      );
      expect(
        validateBreakpointList([_desktop.copyWith(minWidth: -1)]).single.kind,
        IrDiagnosticKind.invalidValue,
      );
      expect(
        validateBreakpointList([_desktop.copyWith(primary: false)]).single.kind,
        IrDiagnosticKind.noPrimaryBreakpoint,
      );
      expect(validateBreakpointList(const []), isNotEmpty);
    });
  });

  group('add / update', () {
    test('adds a valid breakpoint, refuses an invalid one', () {
      const wide = Breakpoint(
        id: 'wide',
        name: 'Wide',
        minWidth: 1800,
        designSize: StageSize(width: 1920, height: 1080),
        inheritsFrom: 'desktop',
      );
      final r = addBreakpoint(_doc(), wide);
      expect(r.ok && r.changed, isTrue);
      expect(r.document.breakpoints.last, wide);
      final bad = addBreakpoint(_doc(), wide.copyWith(id: 'desktop'));
      expect(bad.ok, isFalse);
      expect(bad.document.breakpoints, hasLength(3));
    });

    test('update keeps the id and prevents cycles', () {
      final doc = _doc();
      final r = updateBreakpoint(
        doc,
        'tablet',
        _tablet.copyWith(primary: true, name: 'iPad'),
      );
      expect(r.ok, isTrue);
      expect(r.document.primaryBreakpoints.map((b) => b.id), [
        'desktop',
        'mobile',
        'tablet',
      ]);
      expect(
        updateBreakpoint(
          doc,
          'desktop',
          _desktop.copyWith(inheritsFrom: 'tablet'),
        ).ok,
        isFalse,
      );
      expect(
        updateBreakpoint(doc, 'tablet', _tablet.copyWith(id: 'x')).ok,
        isFalse,
      );
      expect(updateBreakpoint(doc, 'tablet', _tablet).changed, isFalse);
    });
  });

  group('removeBreakpoint', () {
    test('drops its patches everywhere, its track filters, and re-parents '
        'its children', () {
      final doc = _doc().copyWith(
        breakpoints: [
          _desktop,
          _mobile,
          _tablet,
          const Breakpoint(
            id: 'small',
            name: 'Small tablet',
            minWidth: 500,
            designSize: StageSize(width: 600, height: 900),
            inheritsFrom: 'tablet',
          ),
        ],
      );
      final r = removeBreakpoint(doc, 'tablet');
      expect(r.ok, isTrue);
      final d = r.document;
      expect(d.breakpoints.map((b) => b.id), ['desktop', 'mobile', 'small']);
      expect(d.breakpoints.last.inheritsFrom, 'desktop');
      final a = DocumentIndex.of(d).node('a')!;
      expect(a.common.breakpointOverrides.keys, ['mobile']);
      expect(d.components['k']!.root.common.breakpointOverrides, isEmpty);
      final tracks = d.scenes.first.tracks;
      expect(tracks[0].breakpoints, isEmpty);
      expect(tracks[1].breakpoints, ['desktop']);
      // Untouched trees keep their identity.
      expect(identical(d.scenes[1], doc.scenes[1]), isTrue);
      expect(
        identical(
          DocumentIndex.of(d).node('b'),
          DocumentIndex.of(doc).node('b'),
        ),
        isTrue,
      );
    });

    test('refuses the last primary and unknown ids', () {
      final doc = _doc();
      final one = removeBreakpoint(doc, 'mobile');
      expect(one.ok, isTrue);
      expect(removeBreakpoint(one.document, 'desktop').ok, isFalse);
      expect(removeBreakpoint(doc, 'nope').ok, isFalse);
    });
  });

  test('clearBreakpointPatch removes one breakpoint patch of a node', () {
    final doc = _doc();
    final r = clearBreakpointPatch(doc, 'a', 'tablet');
    expect(r.changed, isTrue);
    final a = DocumentIndex.of(r.document).node('a')!;
    expect(hasBreakpointPatch(a, 'tablet'), isFalse);
    expect(hasBreakpointPatch(a, 'mobile'), isTrue);
    expect(hasAnyBreakpointPatch(a), isTrue);
    expect(clearBreakpointPatch(r.document, 'a', 'tablet').changed, isFalse);
  });
}
