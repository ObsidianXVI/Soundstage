import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/insert/starter_components.dart';
import 'package:soundstage_platform/ir/ir.dart';

import '../core/fixtures.dart';

void main() {
  for (final s in StarterComponent.values) {
    test('${starterName(s)} adds a valid component and an instance', () {
      final c = editorContainer();
      final before = c.doc.components.length;
      c.ctl.execute(AddStarterComponent(s, parentId: 'root'));
      expect(c.doc.components.length, before + 1);
      final inst = c.node(c.st.selection.single) as InstanceNode;
      expect(inst.common.name, starterName(s));
      expect(
        validateDocument(c.doc).where((d) => d.severity == IrSeverity.error),
        isEmpty,
      );
      // Behaviours survive instance expansion.
      final shown = resolveDocument(c.doc).nodeIndex[inst.id]!.node;
      final behavior = (shown as FrameNode).behavior;
      switch (s) {
        case StarterComponent.carousel:
          expect(behavior, isA<CarouselBehavior>());
        case StarterComponent.gallery:
          expect(behavior, isA<LightboxBehavior>());
          expect(shown.grid, isNotNull);
        case StarterComponent.tiles:
          expect(shown.grid, isNotNull);
      }
      expect(c.ctl.undo(), isTrue);
      expect(c.doc.components.length, before);
    });
  }
}
