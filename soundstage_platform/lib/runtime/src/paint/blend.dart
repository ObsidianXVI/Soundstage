import 'dart:ui' as ui;

import 'package:soundstage_platform/ir/ir.dart' as ir;

/// The canvas blend mode for an IR blend mode (architecture §5). `normal`
/// and `passThrough` both draw source-over: `passThrough` (frames) differs
/// only in that the frame does not isolate its children.
ui.BlendMode flutterBlendMode(ir.BlendMode m) => switch (m) {
  ir.BlendMode.normal || ir.BlendMode.passThrough => ui.BlendMode.srcOver,
  ir.BlendMode.darken => ui.BlendMode.darken,
  ir.BlendMode.multiply => ui.BlendMode.multiply,
  ir.BlendMode.colorBurn => ui.BlendMode.colorBurn,
  ir.BlendMode.lighten => ui.BlendMode.lighten,
  ir.BlendMode.screen => ui.BlendMode.screen,
  ir.BlendMode.colorDodge => ui.BlendMode.colorDodge,
  ir.BlendMode.overlay => ui.BlendMode.overlay,
  ir.BlendMode.softLight => ui.BlendMode.softLight,
  ir.BlendMode.hardLight => ui.BlendMode.hardLight,
  ir.BlendMode.difference => ui.BlendMode.difference,
  ir.BlendMode.exclusion => ui.BlendMode.exclusion,
  ir.BlendMode.hue => ui.BlendMode.hue,
  ir.BlendMode.saturation => ui.BlendMode.saturation,
  ir.BlendMode.color => ui.BlendMode.color,
  ir.BlendMode.luminosity => ui.BlendMode.luminosity,
};

/// Whether a node with [mode] must be composited in an isolated group
/// (a `saveLayer`) to blend with what is behind it.
bool blendNeedsIsolation(ir.BlendMode mode) =>
    mode != ir.BlendMode.normal && mode != ir.BlendMode.passThrough;
