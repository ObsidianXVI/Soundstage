import 'package:flutter/widgets.dart';

import '../fields/props.dart';
import '../fields/rows.dart';
import '../inspector_providers.dart';
import '../section_registry.dart';

/// The shape's own geometry (architecture §4.1): an ellipse's arc and inner
/// radius (pies and rings), a polygon's point count, a star's point count
/// and inner ratio. Rectangles and lines have none, so the section shows
/// only for the other shapes. Each field shows for the shapes it applies
/// to, written like any property (edit scope, breakpoint patches).
final InspectorSectionSpec shapeSection = InspectorSectionSpec(
  id: 'shape',
  title: 'Shape',
  appliesTo: (info) => info.geometries.any(_kinds.contains),
  builder: (context, info) => _ShapeBody(info: info),
);

const _kinds = {'ellipse', 'polygon', 'star'};

class _ShapeBody extends StatelessWidget {
  const _ShapeBody({required this.info});

  final SelectionInfo info;

  @override
  Widget build(BuildContext context) {
    final g = info.geometries;
    return Grid(
      children: [
        if (g.contains('ellipse')) ...const [
          NumberProp(
            path: 'geometry.arcStart',
            label: 'Start',
            semanticLabel: 'Arc start',
            unit: '°',
            fractionDigits: 1,
          ),
          NumberProp(
            path: 'geometry.arcEnd',
            label: 'End',
            semanticLabel: 'Arc end',
            unit: '°',
            fractionDigits: 1,
          ),
          NumberProp(
            path: 'geometry.innerRadius',
            label: 'Ratio',
            semanticLabel: 'Inner radius',
            unit: '%',
            scale: 100,
            min: 0,
            max: 100,
            fractionDigits: 1,
          ),
        ],
        if (g.contains('polygon') || g.contains('star'))
          const NumberProp(
            path: 'geometry.pointCount',
            label: 'Count',
            semanticLabel: 'Point count',
            min: 3,
            max: 60,
            fractionDigits: 0,
          ),
        if (g.contains('star'))
          const NumberProp(
            path: 'geometry.innerRatio',
            label: 'Ratio',
            semanticLabel: 'Star inner ratio',
            unit: '%',
            scale: 100,
            min: 0,
            max: 100,
            fractionDigits: 1,
          ),
      ],
    );
  }
}
