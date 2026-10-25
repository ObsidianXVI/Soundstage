import 'package:flutter/widgets.dart';

import 'inspector_providers.dart';
import 'sections/appearance_section.dart';
import 'sections/auto_layout_section.dart';
import 'sections/behavior_section.dart';
import 'sections/effects_section.dart';
import 'sections/fill_section.dart';
import 'sections/frame_section.dart';
import 'sections/header_section.dart';
import 'sections/layout_child_section.dart';
import 'sections/modes_section.dart';
import 'sections/motion_section.dart';
import 'sections/shape_section.dart';
import 'sections/stroke_section.dart';
import 'sections/text_section.dart';

/// One inspector section, in Figma's order. A section is declared by an id
/// (also its remembered collapse key), a title, the selections it applies to
/// and a body made of registry-driven controls (`NumberProp('x')`,
/// `EnumProp('autoLayout.direction')`, …) and the few composite editors
/// (paint stack, constraints widget).
///
/// T1.8 adds the text inspector by replacing the body of the `text`
/// section, or by appending to [kInspectorSections].
class InspectorSectionSpec {
  const InspectorSectionSpec({
    required this.id,
    required this.title,
    required this.appliesTo,
    required this.builder,
    this.actions,
    this.collapsible = true,
  });

  final String id;
  final String title;

  /// Whether the section shows for [SelectionInfo].
  final bool Function(SelectionInfo info) appliesTo;

  /// The body. Built only while the section is expanded.
  final Widget Function(BuildContext context, SelectionInfo info) builder;

  /// Header buttons (add paint, add effect, …), built in the section's
  /// context.
  final List<Widget> Function(BuildContext context, SelectionInfo info)?
  actions;
  final bool collapsible;
}

/// The sections of the inspector for a selection, top to bottom.
final List<InspectorSectionSpec> kInspectorSections = [
  headerSection,
  frameSection,
  shapeSection,
  autoLayoutSection,
  layoutChildSection,
  appearanceSection,
  modesSection,
  fillSection,
  strokeSection,
  effectsSection,
  textSection,
  behaviorSection,
  motionSection,
];
