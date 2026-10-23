import '../section_registry.dart';

final InspectorSectionSpec effectsSection = InspectorSectionSpec(
  id: 'effects',
  title: 'effects',
  appliesTo: (info) => false,
  builder: (context, info) => throw UnimplementedError(),
);
