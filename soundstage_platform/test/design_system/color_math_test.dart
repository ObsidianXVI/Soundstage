import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

void main() {
  test('RGB -> HSV -> RGB round-trips every sampled 8-bit colour', () {
    var n = 0;
    for (var r = 0; r < 256; r += 5) {
      for (var g = 0; g < 256; g += 5) {
        for (var b = 0; b < 256; b += 5) {
          final c = rgbaColor(r, g, b);
          final back = SsHsv.fromColor(c).toColor();
          expect(back, c, reason: 'rgb($r,$g,$b)');
          n++;
        }
      }
    }
    expect(n, greaterThan(100000));
  });

  test('RGB -> HSL -> RGB round-trips sampled colours', () {
    for (var r = 0; r < 256; r += 15) {
      for (var g = 0; g < 256; g += 15) {
        for (var b = 0; b < 256; b += 15) {
          final c = rgbaColor(r, g, b);
          expect(SsHsl.fromColor(c).toColor(), c, reason: 'rgb($r,$g,$b)');
        }
      }
    }
  });

  test('alpha survives the conversions', () {
    final c = rgbaColor(10, 200, 90, 0.5);
    expect(SsHsv.fromColor(c).toColor(), c);
    expect(SsHsl.fromColor(c).toColor(), c);
    expect(SsHsv.fromColor(c).a, closeTo(0.5, 0.01));
  });

  test('known values', () {
    final red = SsHsv.fromColor(const Color(0xFFFF0000));
    expect((red.h, red.s, red.v), (0.0, 1.0, 1.0));
    final grey = SsHsv.fromColor(const Color(0xFF808080));
    expect(grey.s, 0);
    final hsl = SsHsl.fromColor(const Color(0xFF00FF00));
    expect((hsl.h, hsl.s, hsl.l), (120.0, 1.0, 0.5));
    expect(const SsHsv(240, 1, 1).toColor(), const Color(0xFF0000FF));
  });

  test('hex parse and format', () {
    expect(parseHexColor('#2F6FED'), const Color(0xFF2F6FED));
    expect(parseHexColor('2f6fed'), const Color(0xFF2F6FED));
    expect(parseHexColor('#fa0'), const Color(0xFFFFAA00));
    expect(parseHexColor('#2F6FED80'), const Color(0x802F6FED));
    expect(parseHexColor('#fa08'), const Color(0x88FFAA00));
    for (final bad in ['', '#', '#12', '#12345', 'zzzzzz', '#1234567']) {
      expect(parseHexColor(bad), isNull, reason: bad);
    }
    expect(formatHexColor(const Color(0xFF2F6FED)), '#2F6FED');
    expect(formatHexColor(const Color(0x802F6FED)), '#2F6FED80');
    expect(
      formatHexColor(const Color(0x802F6FED), withAlpha: false),
      '#2F6FED',
    );
    expect(
      parseHexColor(formatHexColor(const Color(0x1234ABCD))),
      const Color(0x1234ABCD),
    );
  });
}
