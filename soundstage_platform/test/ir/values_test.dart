import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

void main() {
  group('StageColor', () {
    test('parses hex forms', () {
      expect(StageColor.fromHex('#ff0000'), const StageColor(r: 1, g: 0, b: 0));
      expect(StageColor.fromHex('00FF00'), const StageColor(r: 0, g: 1, b: 0));
      expect(StageColor.fromHex('#00f'), const StageColor(r: 0, g: 0, b: 1));
      expect(
        StageColor.fromHex('#0000ff00'),
        const StageColor(r: 0, g: 0, b: 1, a: 0),
      );
      expect(StageColor.fromHex('#fff8').a, closeTo(0x88 / 255, 1e-12));
    });

    test('rejects malformed hex', () {
      for (final bad in ['', '#12', '#12345', '#gggggg', '#1234567']) {
        expect(
          () => StageColor.fromHex(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('toHex omits alpha when opaque and round-trips 8-bit colours', () {
      expect(const StageColor(r: 1, g: 0.5, b: 0).toHex(), '#ff8000');
      expect(const StageColor(r: 0, g: 0, b: 0, a: 0.5).toHex(), '#00000080');
      expect(StageColor.white.toHex(includeAlpha: true), '#ffffffff');
      for (final hex in ['#123456', '#abcdef80', '#00000000']) {
        expect(StageColor.fromHex(hex).toHex(), hex);
      }
    });
  });

  group('IdGenerator', () {
    test('produces 10-char base62 ids', () {
      final gen = IdGenerator();
      for (var i = 0; i < 200; i++) {
        final id = gen.next();
        expect(id, hasLength(kIdLength));
        expect(isGeneratedId(id), isTrue, reason: id);
      }
    });

    test('is deterministic with an injected Random', () {
      final a = IdGenerator(Random(42));
      final b = IdGenerator(Random(42));
      expect(
        List.generate(5, (_) => a.next()),
        List.generate(5, (_) => b.next()),
      );
    });

    test('does not repeat in practice', () {
      final gen = IdGenerator.seeded(1);
      final ids = {for (var i = 0; i < 10000; i++) gen.next()};
      expect(ids, hasLength(10000));
    });
  });

  group('PropertyPath', () {
    const path = PropertyPath('fills.pA.color');

    test('segment helpers', () {
      expect(path.segments, ['fills', 'pA', 'color']);
      expect(path.head, 'fills');
      expect(path.last, 'color');
      expect(path.parent, const PropertyPath('fills.pA'));
      expect(const PropertyPath('opacity').parent, const PropertyPath(''));
      expect(const PropertyPath('').segments, isEmpty);
      expect(
        const PropertyPath('fills').child('pA'),
        const PropertyPath('fills.pA'),
      );
      expect(PropertyPath.fromSegments(['a', 'b']), const PropertyPath('a.b'));
    });

    test('prefix matching respects segment boundaries', () {
      expect(const PropertyPath('fills').isPrefixOf(path), isTrue);
      expect(path.isPrefixOf(path), isTrue);
      expect(const PropertyPath('fill').isPrefixOf(path), isFalse);
    });

    test('NodePath splits on slashes', () {
      expect(const NodePath('inst/inner/leaf').ids, ['inst', 'inner', 'leaf']);
      expect(NodePath.fromIds(['a', 'b']), const NodePath('a/b'));
    });
  });
}
