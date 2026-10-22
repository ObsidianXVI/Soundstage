import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

void main() {
  const image = Size(1600, 1000);
  const moon = Offset(0.62, 0.40);
  const moonRadius = 0.07; // of the image height, as in the sky image

  for (final v in const [
    Size(390, 844),
    Size(414, 896),
    Size(834, 1112),
    Size(1024, 768),
    Size(1440, 900),
    Size(1920, 1080),
    Size(2560, 1080),
    Size(844, 390),
    Size(1440, 500),
  ]) {
    test('the moon stays in the upper focal area at $v', () {
      final p = gateCoverPlacement(image, v, moon);
      // The image covers the viewport.
      expect(p.dest.left, lessThanOrEqualTo(0.001));
      expect(p.dest.top, lessThanOrEqualTo(0.001));
      expect(p.dest.right, greaterThanOrEqualTo(v.width - 0.001));
      expect(p.dest.bottom, greaterThanOrEqualTo(v.height - 0.001));
      // The moon (and its disc) sit above the text zone and inside the view.
      final r = moonRadius * p.dest.height;
      expect(p.focalAt.dx, inInclusiveRange(r, v.width - r));
      expect(p.focalAt.dy + r, lessThanOrEqualTo(v.height * 0.5));
      expect(p.focalAt.dy - r, greaterThanOrEqualTo(0));
    });
  }
}
