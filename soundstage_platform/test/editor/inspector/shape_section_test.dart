import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

ir.ShapeNode _shape(String id, ir.ShapeGeometry g) => ir.ShapeNode(
  common: ir.NodeCommon(id: id, name: id, width: 64, height: 64),
  geometry: g,
);

ir.StageDocument _doc() => inspectorDoc([
  _shape('pie', const ir.ShapeGeometry.ellipse()),
  _shape('star', const ir.ShapeGeometry.star()),
  _shape('hex', const ir.ShapeGeometry.polygon()),
  _shape('box', const ir.ShapeGeometry.rectangle()),
]);

ir.ShapeGeometry _g(ProviderContainer c, String id) =>
    (nodeOf(c, id) as ir.ShapeNode).geometry;

void main() {
  testWidgets('an ellipse edits its arc and inner radius (pie, ring)', (
    tester,
  ) async {
    final c = await pumpInspector(tester, _doc(), select: {'pie'});
    expect(find.byKey(const ValueKey('section:shape')), findsOneWidget);
    expect(fieldText('geometry.pointCount'), findsNothing);
    await typeInto(tester, 'geometry.arcEnd', '270');
    await typeInto(tester, 'geometry.innerRadius', '60');
    expect(
      _g(c, 'pie'),
      const ir.ShapeGeometry.ellipse(arcEnd: 270, innerRadius: 0.6),
    );
    c.read(editorControllerProvider.notifier).undo();
    expect(_g(c, 'pie'), const ir.ShapeGeometry.ellipse(arcEnd: 270));
  });

  testWidgets('a star edits its points and ratio; a polygon its points', (
    tester,
  ) async {
    final c = await pumpInspector(tester, _doc(), select: {'star'});
    expect(fieldText('geometry.arcStart'), findsNothing);
    await typeInto(tester, 'geometry.pointCount', '6');
    await typeInto(tester, 'geometry.innerRatio', '45');
    expect(
      _g(c, 'star'),
      const ir.ShapeGeometry.star(pointCount: 6, innerRatio: 0.45),
    );
    c.read(editorControllerProvider.notifier).select({'hex'});
    await tester.pump();
    expect(fieldText('geometry.innerRatio'), findsNothing);
    await typeInto(tester, 'geometry.pointCount', '6');
    expect(_g(c, 'hex'), const ir.ShapeGeometry.polygon(pointCount: 6));
  });

  testWidgets('rectangles have no Shape section', (tester) async {
    await pumpInspector(tester, _doc(), select: {'box'});
    expect(find.byKey(const ValueKey('section:shape')), findsNothing);
  });

  testWidgets('This breakpoint: the arc is patched on mobile only', (
    tester,
  ) async {
    final c = await pumpInspector(tester, _doc(), select: {'pie'});
    final ctl = c.read(editorControllerProvider.notifier);
    ctl.setEditScope(EditScope.thisBreakpoint);
    ctl.setEditingBreakpoint('mobile');
    await tester.pump();
    await typeInto(tester, 'geometry.arcEnd', '180');
    expect(_g(c, 'pie'), const ir.ShapeGeometry.ellipse());
    expect(nodeOf(c, 'pie').common.breakpointOverrides['mobile'], {
      'geometry.arcEnd': const ir.IrValue.number(180),
    });
  });
}
