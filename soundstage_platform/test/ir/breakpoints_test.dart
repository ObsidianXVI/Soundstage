import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

Breakpoint bp(String id, double minWidth) => Breakpoint(
  id: id,
  name: id,
  minWidth: minWidth,
  designSize: StageSize(width: minWidth + 100, height: 800),
);

List<String> ids(List<Breakpoint> l) => [for (final b in l) b.id];

void main() {
  // Declared out of width order on purpose.
  final three = [bp('tablet', 600), bp('desktop', 1024), bp('mobile', 0)];
  final four = [
    bp('wide', 1600),
    bp('mobile', 0),
    bp('desktop', 1024),
    bp('tablet', 600),
  ];

  Breakpoint child(String id, double w, String? parent) =>
      bp(id, w).copyWith(inheritsFrom: parent);
  List<String> chain(List<Breakpoint> l, String id) =>
      ids(breakpointChain(l, id).chain);

  group('inheritsFrom chain (shared base)', () {
    // desktop and mobile are peers; tablet inherits desktop; wide inherits
    // tablet.
    final bps = [
      child('wide', 1600, 'tablet'),
      bp('mobile', 0),
      bp('desktop', 1024),
      child('tablet', 600, 'desktop'),
    ];
    test('peers apply only their own patch', () {
      expect(chain(bps, 'desktop'), ['desktop']);
      expect(chain(bps, 'mobile'), ['mobile']);
    });
    test('a chain applies root first, itself last', () {
      expect(chain(bps, 'tablet'), ['desktop', 'tablet']);
      expect(chain(bps, 'wide'), ['desktop', 'tablet', 'wide']);
      expect(breakpointChain(bps, 'wide').problem, isNull);
    });
    test('width order is irrelevant', () {
      final narrowParent = [bp('mobile', 0), child('desktop', 1024, 'mobile')];
      expect(chain(narrowParent, 'desktop'), ['mobile', 'desktop']);
    });
    test('an unknown active id gives an empty chain', () {
      expect(breakpointChain(bps, 'nope').chain, isEmpty);
    });
    test('an unknown parent stops the walk and is reported', () {
      final r = breakpointChain([child('a', 0, 'gone')], 'a');
      expect(ids(r.chain), ['a']);
      expect(r.problem, BreakpointChainProblem.unknownParent);
      expect(r.problemId, 'gone');
    });
    test('a cycle stops the walk and is reported', () {
      final cyc = [
        child('a', 0, 'b'),
        child('b', 500, 'c'),
        child('c', 900, 'b'),
      ];
      final r = breakpointChain(cyc, 'a');
      expect(ids(r.chain), ['c', 'b', 'a']);
      expect(r.problem, BreakpointChainProblem.cycle);
      expect(r.problemId, 'b');
      final self = breakpointChain([child('x', 0, 'x')], 'x');
      expect(ids(self.chain), ['x']);
      expect(self.problem, BreakpointChainProblem.cycle);
    });
  });

  group('resolution over the shared base', () {
    StageDocument doc(List<Breakpoint> bps) => StageDocument(
      id: 'd',
      breakpoints: bps,
      scenes: [
        Scene(
          id: 's',
          root: FrameNode(
            common: const NodeCommon(id: 'root', width: 100, height: 100),
            children: [
              ShapeNode(
                common: NodeCommon(
                  id: 'n',
                  x: 1,
                  y: 1,
                  opacity: 1,
                  breakpointOverrides: {
                    for (final b in bps)
                      b.id: {
                        // Each patch sets x to its own marker; only some set y.
                        'x': IrValue.number(b.minWidth),
                        if (b.id == 'desktop') 'y': const IrValue.number(7),
                      },
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
    double x(StageDocument d, String bp) => resolveDocument(
      d,
      ResolveContext(breakpointId: bp),
    ).nodeIndex['n']!.node.common.x;
    double y(StageDocument d, String bp) => resolveDocument(
      d,
      ResolveContext(breakpointId: bp),
    ).nodeIndex['n']!.node.common.y;

    final bps = [
      bp('desktop', 1024).copyWith(primary: true),
      bp('mobile', 0).copyWith(primary: true),
      child('tablet', 600, 'desktop'),
    ];
    test('peers start from the shared base', () {
      final d = doc(bps);
      expect(x(d, 'desktop'), 1024);
      expect(y(d, 'desktop'), 7);
      expect(x(d, 'mobile'), 0);
      expect(y(d, 'mobile'), 1, reason: 'mobile does not inherit desktop');
    });
    test('a child applies its parent patch, then its own', () {
      final d = doc(bps);
      expect(x(d, 'tablet'), 600);
      expect(y(d, 'tablet'), 7, reason: 'inherited from desktop');
    });
    test('without a context the first primary breakpoint resolves', () {
      final d = doc([bp('tablet', 600), ...bps.take(2)]);
      expect(resolveDocument(d).breakpoint!.id, 'desktop');
    });
    test('a cycle resolves the walked part and reports, never throws', () {
      final d = doc([
        child('a', 0, 'b').copyWith(primary: true),
        child('b', 500, 'a'),
      ]);
      final r = resolveDocument(d, const ResolveContext(breakpointId: 'a'));
      expect(r.nodeIndex['n']!.node.common.x, 0);
      expect(
        r.diagnostics.map((e) => e.kind),
        contains(IrDiagnosticKind.breakpointCycle),
      );
      expect(
        validateDocument(d).map((e) => e.code),
        contains('breakpointCycle'),
      );
    });
    test('the validator flags unknown parents and a missing primary', () {
      final d = doc([child('a', 0, 'gone')]);
      final codes = validateDocument(d).map((e) => e.code).toList();
      expect(codes, containsAll(['missingBreakpoint', 'noPrimaryBreakpoint']));
    });
  });

  group('active breakpoint', () {
    test('largest minWidth <= width', () {
      expect(activeBreakpoint(three, 1440)!.id, 'desktop');
      expect(activeBreakpoint(three, 1024)!.id, 'desktop');
      expect(activeBreakpoint(three, 1023.9)!.id, 'tablet');
      expect(activeBreakpoint(three, 600)!.id, 'tablet');
      expect(activeBreakpoint(three, 390)!.id, 'mobile');
      expect(activeBreakpoint(four, 2000)!.id, 'wide');
    });
    test('below every minWidth falls back to the narrowest', () {
      expect(activeBreakpoint([bp('a', 300), bp('b', 800)], 100)!.id, 'a');
    });
    test('no breakpoints', () {
      expect(activeBreakpoint(const [], 500), isNull);
    });
    test('breakpointForWidth on a document', () {
      final doc = StageDocument.empty(ids: IdGenerator.seeded(1));
      expect(breakpointForWidth(doc, 390)!.name, 'Mobile');
      expect(breakpointForWidth(doc, 834)!.name, 'Tablet');
      expect(breakpointForWidth(doc, 1440)!.name, 'Desktop');
    });
  });
}
