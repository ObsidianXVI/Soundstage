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

  group('cascade, desktop-first', () {
    test('active = base applies nothing', () {
      expect(breakpointCascade(three, 'desktop', 'desktop'), isEmpty);
    });
    test('tablet inherits desktop', () {
      expect(ids(breakpointCascade(three, 'desktop', 'tablet')), ['tablet']);
    });
    test('mobile inherits desktop + tablet', () {
      expect(ids(breakpointCascade(three, 'desktop', 'mobile')), [
        'tablet',
        'mobile',
      ]);
    });
    test('four breakpoints: larger than base cascades upward', () {
      expect(ids(breakpointCascade(four, 'desktop', 'wide')), ['wide']);
      expect(ids(breakpointCascade(four, 'desktop', 'mobile')), [
        'tablet',
        'mobile',
      ]);
    });
  });

  group('cascade, mobile-first', () {
    test('active = base', () {
      expect(breakpointCascade(three, 'mobile', 'mobile'), isEmpty);
    });
    test('desktop inherits mobile + tablet', () {
      expect(ids(breakpointCascade(three, 'mobile', 'desktop')), [
        'tablet',
        'desktop',
      ]);
    });
    test('four breakpoints, widest extreme', () {
      expect(ids(breakpointCascade(four, 'mobile', 'wide')), [
        'tablet',
        'desktop',
        'wide',
      ]);
      expect(ids(breakpointCascade(four, 'mobile', 'tablet')), ['tablet']);
    });
  });

  test('a middle base cascades both ways', () {
    expect(ids(breakpointCascade(four, 'tablet', 'mobile')), ['mobile']);
    expect(ids(breakpointCascade(four, 'tablet', 'wide')), ['desktop', 'wide']);
  });

  test('unknown ids give an empty cascade', () {
    expect(breakpointCascade(three, 'nope', 'mobile'), isEmpty);
    expect(breakpointCascade(three, 'desktop', 'nope'), isEmpty);
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
