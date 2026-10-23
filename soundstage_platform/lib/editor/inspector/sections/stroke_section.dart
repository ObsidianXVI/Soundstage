import '../section_registry.dart';

final InspectorSectionSpec strokeSection = InspectorSectionSpec(
  id: 'stroke',
  title: 'stroke',
  appliesTo: (info) => false,
  builder: (context, info) => throw UnimplementedError(),
);
