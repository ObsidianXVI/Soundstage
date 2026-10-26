import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

void main() {
  test('isolation edits the main; the story folds it back; leaving restores '
      'the scenes', () {
    final c = editorContainer();
    final storyBefore = c.doc;
    c.ctl.enterComponent('cmp');
    expect(c.st.isolation?.componentId, 'cmp');
    expect(c.doc.scenes.single.id, kIsolationSceneId);
    expect(c.st.activeSceneId, kIsolationSceneId);
    expect(c.st.selection, {'cmpR'});
    expect(c.st.storyDocument.scenes.length, storyBefore.scenes.length);
    expect(identical(c.st.storyDocument, c.st.storyDocument), isTrue);

    c.ctl.execute(SetProperty({'cmpR'}, 'opacity', const IrValue.number(0.5)));
    final story = c.st.storyDocument;
    expect(story.components['cmp']!.root.common.opacity, 0.5);
    expect(story.scenes, storyBefore.scenes);
    expect(
      validateDocument(story).where((d) => d.severity == IrSeverity.error),
      isEmpty,
    );

    c.ctl.exitComponent();
    expect(c.st.isolation, isNull);
    expect(identical(c.doc, story), isTrue);
    expect(c.st.activeSceneId, 's1');
    // The instance shows the change.
    expect(c.resolved('inst', 'desktop').node.common.opacity, 0.5);

    // Undo goes back into isolation, before the edit.
    expect(c.ctl.undo(), isTrue);
    expect(c.st.isolation?.componentId, 'cmp');
    expect(c.st.storyDocument.components['cmp']!.root.common.opacity, 1);
  });

  test('layers drawn on the stage outside the main move into it', () {
    final c = editorContainer();
    c.ctl.enterComponent('cmp');
    c.ctl.execute(
      const _Insert(
        ShapeNode(
          common: NodeCommon(id: 'extra', x: 60, y: 10, width: 5, height: 5),
        ),
      ),
    );
    final root = c.st.storyDocument.components['cmp']!.root;
    expect(root.children.map((n) => n.id), contains('extra'));
  });

  test('create component from a frame selects its instance', () {
    final c = editorContainer();
    c.ctl.execute(const CreateComponent('b'));
    final inst = c.st.selection.single;
    expect(c.node(inst), isA<InstanceNode>());
    expect(c.doc.components.length, 2);
  });
}

/// Inserts [node] on the isolation stage.
class _Insert extends EditCommand {
  const _Insert(this.node);

  final Node node;

  @override
  String get label => 'Insert';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    insertNodes(state.document, kIsolationStageId, 1, [node]),
    label: label,
  );
}
