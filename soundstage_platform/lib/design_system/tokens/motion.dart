import 'package:flutter/animation.dart';

/// Motion durations and easings. The chrome is quick: hover and press
/// feedback is near-instant, structure changes ease out.
abstract final class SsMotion {
  static const Duration instant = Duration(milliseconds: 60);
  static const Duration fast = Duration(milliseconds: 100);
  static const Duration base = Duration(milliseconds: 160);
  static const Duration slow = Duration(milliseconds: 240);

  /// Elements entering or changing size.
  static const Curve easeOut = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Elements leaving.
  static const Curve easeIn = Cubic(0.4, 0.0, 1.0, 1.0);

  /// Moves between two on-screen positions.
  static const Curve standard = Cubic(0.2, 0.0, 0.2, 1.0);

  /// Tooltip hover delay before it shows.
  static const Duration tooltipDelay = Duration(milliseconds: 500);

  /// How long a toast stays by default.
  static const Duration toastDuration = Duration(seconds: 4);
}
