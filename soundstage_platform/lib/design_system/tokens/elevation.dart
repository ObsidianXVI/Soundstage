import 'package:flutter/painting.dart';

/// Elevation as shadow stacks. In the dark theme depth is mostly carried by
/// surface lightness plus a border, so shadows stay tight and soft.
abstract final class SsElevation {
  static const List<BoxShadow> e0 = <BoxShadow>[];

  /// Raised controls, pressed-in cards.
  static const List<BoxShadow> e1 = <BoxShadow>[
    BoxShadow(color: Color(0x33000000), blurRadius: 2, offset: Offset(0, 1)),
  ];

  /// Popovers, menus, tooltips.
  static const List<BoxShadow> e2 = <BoxShadow>[
    BoxShadow(color: Color(0x40000000), blurRadius: 12, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x33000000), blurRadius: 2, offset: Offset(0, 1)),
  ];

  /// Dialogs, drawers.
  static const List<BoxShadow> e3 = <BoxShadow>[
    BoxShadow(color: Color(0x59000000), blurRadius: 32, offset: Offset(0, 12)),
    BoxShadow(color: Color(0x40000000), blurRadius: 4, offset: Offset(0, 2)),
  ];
}
