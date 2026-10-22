import 'dart:ui' show Color;

import 'package:soundstage_platform/ir/ir.dart' as ir;

/// [c] as a Flutter colour, with its alpha multiplied by [opacity].
Color stageColor(ir.StageColor c, [double opacity = 1]) => Color.from(
  alpha: (c.a * opacity).clamp(0.0, 1.0),
  red: c.r.clamp(0.0, 1.0),
  green: c.g.clamp(0.0, 1.0),
  blue: c.b.clamp(0.0, 1.0),
);
