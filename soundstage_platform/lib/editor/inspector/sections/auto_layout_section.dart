import '../section_registry.dart';

final InspectorSectionSpec autoLayoutSection = InspectorSectionSpec(
  id: 'auto_layout',
  title: 'auto_layout',
  appliesTo: (info) => false,
  builder: (context, info) => throw UnimplementedError(),
);
