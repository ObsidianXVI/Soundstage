import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../section_registry.dart';

/// The text section: a placeholder header until T1.8 builds the text
/// inspector (all of architecture §7). T1.8 replaces [builder] (and may add
/// `actions`); the section id, title and applicability stay.
final InspectorSectionSpec textSection = InspectorSectionSpec(
  id: 'text',
  title: 'Text',
  appliesTo: (info) => info.kinds.contains(ir.NodeKind.text),
  builder: (context, info) => Text(
    'Text properties arrive with the text inspector.',
    key: const ValueKey<String>('text-section-placeholder'),
    style: context.ss.text.caption,
  ),
);
