import '../section_registry.dart';

final InspectorSectionSpec textSection = InspectorSectionSpec(
  id: 'text',
  title: 'text',
  appliesTo: (info) => false,
  builder: (context, info) => throw UnimplementedError(),
);
