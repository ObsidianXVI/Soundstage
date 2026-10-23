import 'dart:ui' show Brightness;

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

void main() {
  for (final (name, c) in [
    ('dark', SsColors.dark),
    ('light', SsColors.light),
  ]) {
    group('$name theme contrast (WCAG AA)', () {
      final surfaces = {
        'surface0': c.surface0,
        'surface1': c.surface1,
        'surface2': c.surface2,
        'surface3': c.surface3,
      };
      for (final e in surfaces.entries) {
        test('primary text on ${e.key} >= 4.5', () {
          expect(
            SsColors.contrast(c.textPrimary, e.value),
            greaterThanOrEqualTo(4.5),
          );
        });
        test('secondary text on ${e.key} >= 4.5', () {
          expect(
            SsColors.contrast(c.textSecondary, e.value),
            greaterThanOrEqualTo(4.5),
          );
        });
        test('accent text on ${e.key} >= 4.5', () {
          expect(
            SsColors.contrast(c.accentText, e.value),
            greaterThanOrEqualTo(4.5),
          );
        });
      }
      test('text on a solid accent fill >= 4.5', () {
        expect(
          SsColors.contrast(c.textOnAccent, c.accent),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('focus ring against surfaces >= 3 (non-text)', () {
        expect(
          SsColors.contrast(c.focusRing, c.surface1),
          greaterThanOrEqualTo(3),
        );
      });
    });
  }

  test('type scale sizes and line heights', () {
    final t = SsThemeData.dark().text;
    final expected = {
      t.caption: (11.0, 16.0),
      t.small: (12.0, 16.0),
      t.body: (13.0, 20.0),
      t.large: (14.0, 20.0),
      t.title: (16.0, 24.0),
      t.heading: (20.0, 28.0),
    };
    for (final e in expected.entries) {
      expect(e.key.fontSize, e.value.$1);
      expect(e.key.fontSize! * e.key.height!, closeTo(e.value.$2, 1e-9));
      expect(e.key.fontFamily, 'Inter');
    }
  });

  test('spacing is on a 4 px grid', () {
    for (final s in [
      SsSpace.s1,
      SsSpace.s2,
      SsSpace.s3,
      SsSpace.s4,
      SsSpace.s5,
      SsSpace.s6,
      SsSpace.s8,
      SsSpace.s10,
      SsSpace.s12,
    ]) {
      expect(s % 4, 0);
    }
  });

  test('the light theme differs from dark', () {
    expect(SsColors.light.brightness, Brightness.light);
    expect(SsColors.light.surface1, isNot(SsColors.dark.surface1));
  });
}
