import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

void main() {
  group('evaluateNumberExpression', () {
    test('plain numbers', () {
      expect(evaluateNumberExpression('12'), 12);
      expect(evaluateNumberExpression(' 3.5 '), 3.5);
      expect(evaluateNumberExpression('.5'), 0.5);
      expect(evaluateNumberExpression('-8'), -8);
    });

    test('arithmetic and precedence', () {
      expect(evaluateNumberExpression('120/2'), 60);
      expect(evaluateNumberExpression('2+3*4'), 14);
      expect(evaluateNumberExpression('(2+3)*4'), 20);
      expect(evaluateNumberExpression('10-2-3'), 5);
      expect(evaluateNumberExpression('-(2+3)'), -5);
      expect(evaluateNumberExpression('2*-3'), -6);
      expect(evaluateNumberExpression('8 x 2'), 16);
    });

    test('a leading operator is relative to the current value', () {
      expect(evaluateNumberExpression('+8', current: 100), 108);
      expect(evaluateNumberExpression('*2', current: 21), 42);
      expect(evaluateNumberExpression('/2', current: 21), 10.5);
      // A leading minus is a negative literal.
      expect(evaluateNumberExpression('-8', current: 100), -8);
      expect(evaluateNumberExpression('+8'), 8);
    });

    test('units are ignored', () {
      expect(evaluateNumberExpression('12px'), 12);
      expect(evaluateNumberExpression('50%'), 50);
      expect(evaluateNumberExpression('90deg + 10deg'), 100);
    });

    test('invalid input is null', () {
      for (final s in ['', 'abc', '1+', '(1', '1)', '1/0', '*', '1 2', '--']) {
        expect(evaluateNumberExpression(s), isNull, reason: s);
      }
    });
  });

  test('formatNumber trims zeros', () {
    expect(formatNumber(12), '12');
    expect(formatNumber(1.5), '1.5');
    expect(formatNumber(1.005, fractionDigits: 2), '1');
    expect(formatNumber(-0.001), '0');
    expect(formatNumber(3.14159, fractionDigits: 3), '3.142');
  });

  test('roundToDigits', () {
    expect(roundToDigits(1.2345, 2), 1.23);
    expect(roundToDigits(-0.0001, 2), 0);
  });
}
