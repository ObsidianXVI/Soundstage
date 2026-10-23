import '../section_registry.dart';

final InspectorSectionSpec fillSection = InspectorSectionSpec(
  id: 'fill',
  title: 'fill',
  appliesTo: (info) => false,
  builder: (context, info) => throw UnimplementedError(),
);
