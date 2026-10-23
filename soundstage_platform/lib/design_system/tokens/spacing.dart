import 'package:flutter/widgets.dart';

/// Spacing on a 4 px grid.
abstract final class SsSpace {
  static const double s0 = 0;
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 20;
  static const double s6 = 24;
  static const double s8 = 32;
  static const double s10 = 40;
  static const double s12 = 48;

  /// Height of a standard control (input, button, tree row).
  static const double controlHeight = 28;

  /// Height of a compact control (inline toggles, small buttons).
  static const double controlHeightSm = 24;

  /// The minimum pointer target for an icon button.
  static const double hitTarget = 28;
}

/// Corner radii.
abstract final class SsRadius {
  static const double xs = 2;
  static const double sm = 4;
  static const double md = 6;
  static const double lg = 8;
  static const double xl = 12;
  static const double pill = 999;

  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brXl = BorderRadius.all(Radius.circular(xl));
}
