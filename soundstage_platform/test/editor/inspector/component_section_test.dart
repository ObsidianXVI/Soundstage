import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

void main() {
  testWidgets('create a component, give it a text property, bind a layer, '
      'set the value on the instance, detach', (tester) async {
    final c = await pumpInspector(
      tester,
      inspectorDoc([
        box(
          'card',
          children: const [
            ir.TextNode(
              common: ir.NodeCommon(id: 'label', width: 100, height: 20),
              content: [
                ir.Paragraph(spans: [ir.Span(text: 'Hello')]),
              ],
            ),
          ],
        ),
      ]),
      select: {'card'},
      height: 1600,
    );
    await tester.tap(find.byKey(const ValueKey('component:create')));
    await tester.pumpAndSettle();
    final inst = c.st.selection.single;
    final compId = c.doc.components.keys.single;

    // Edit the main.
    await tester.tap(find.byKey(const ValueKey('component:edit')));
    await tester.pumpAndSettle();
    expect(c.st.isolation?.componentId, compId);
    // On the main's root: add a text property.
    await tester.tap(find.byKey(const ValueKey('component:add-prop')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text').last);
    await tester.pumpAndSettle();
    final propId = c.doc.components[compId]!.properties.keys.single;
    // Bind the label's text to it.
    c.ctl.select({'label'});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('component:bind')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Text').last);
    await tester.pumpAndSettle();
    expect(nodeOf(c, 'label').common.componentBindings, {'characters': propId});
    // A second variant.
    c.ctl.select({c.st.isolation!.rootId});
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('component:add-variant')));
    await tester.pumpAndSettle();
    expect(c.doc.variantSets, hasLength(1));
    c.ctl.exitComponent();
    await tester.pumpAndSettle();

    // The instance sets its own text.
    c.ctl.select({inst});
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is SsTextField && w.semanticLabel == 'Text',
      ),
      matching: find.byType(EditableText),
    );
    await tester.enterText(field, 'Bonjour');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      (nodeOf(c, inst) as ir.InstanceNode).propValues[propId],
      const ir.IrValue.string('Bonjour'),
    );
    final label = valueAt(c, '$inst/label', 'characters', 'desktop');
    expect(label, const ir.IrValue.string('Bonjour'));

    // Switch the instance to the second variant and back.
    await tester.tap(find.byKey(const ValueKey('variant-axis:Variant')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Variant 2').last);
    await tester.pumpAndSettle();
    expect(
      (nodeOf(c, inst) as ir.InstanceNode).source,
      isA<ir.VariantSource>(),
    );
    await tester.tap(find.byKey(const ValueKey('variant-axis:Variant')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('component:detach')));
    await tester.pumpAndSettle();
    final frame = nodeOf(c, c.st.selection.single) as ir.FrameNode;
    expect(
      ir.PropertyRegistry.standard.get(frame.children.single, 'characters'),
      const ir.IrValue.string('Bonjour'),
    );
  });
}
