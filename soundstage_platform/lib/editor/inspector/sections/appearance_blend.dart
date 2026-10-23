import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../fields/props.dart';

const List<(ir.BlendMode, String)> _blendLabels = [
  (ir.BlendMode.passThrough, 'Pass through'),
  (ir.BlendMode.normal, 'Normal'),
  (ir.BlendMode.darken, 'Darken'),
  (ir.BlendMode.multiply, 'Multiply'),
  (ir.BlendMode.colorBurn, 'Color burn'),
  (ir.BlendMode.lighten, 'Lighten'),
  (ir.BlendMode.screen, 'Screen'),
  (ir.BlendMode.colorDodge, 'Color dodge'),
  (ir.BlendMode.overlay, 'Overlay'),
  (ir.BlendMode.softLight, 'Soft light'),
  (ir.BlendMode.hardLight, 'Hard light'),
  (ir.BlendMode.difference, 'Difference'),
  (ir.BlendMode.exclusion, 'Exclusion'),
  (ir.BlendMode.hue, 'Hue'),
  (ir.BlendMode.saturation, 'Saturation'),
  (ir.BlendMode.color, 'Color'),
  (ir.BlendMode.luminosity, 'Luminosity'),
];

/// The blend modes in Figma's order. "Pass through" is for frames only, so
/// it is offered when [passThrough] is set.
List<EnumOption> blendModeOptions({bool passThrough = false}) => [
  for (final (m, label) in _blendLabels)
    if (passThrough || m != ir.BlendMode.passThrough) EnumOption(m.name, label),
];
