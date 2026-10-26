import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Component commands (architecture §9; m3.md T3.2), one per IR helper in
// `lib/ir/src/edit/component_edits.dart`.

/// Turns frame [frameId] into a new component; its instance takes its place
/// and is selected.
class CreateComponent extends EditCommand {
  const CreateComponent(this.frameId, {this.ids});

  final String frameId;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Create component';

  @override
  CommandResult apply(EditorState state) {
    final gen = ids ?? ir.IdGenerator.forDocument(state.document);
    final instanceId = gen.next();
    final r = ir.createComponent(
      state.document,
      frameId,
      componentId: gen.next(),
      instanceId: instanceId,
    );
    return resultOf(state, r, label: label, selectionAfter: {instanceId});
  }
}

/// Replaces instance [instanceId] with plain layers (selected).
class DetachInstance extends EditCommand {
  const DetachInstance(this.instanceId, {this.ids});

  final String instanceId;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Detach instance';

  @override
  CommandResult apply(EditorState state) {
    final r = ir.detachInstance(
      state.document,
      instanceId,
      ids: ids ?? ir.IdGenerator.forDocument(state.document),
    );
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: r.ok ? {...r.createdIds} : null,
    );
  }
}

/// Places an instance of component [componentId] in frame [parentId] at
/// ([x], [y]) and selects it.
class InsertInstance extends EditCommand {
  const InsertInstance(
    this.componentId, {
    required this.parentId,
    this.x = 0,
    this.y = 0,
    this.ids,
  });

  final String componentId;
  final String parentId;
  final double x;
  final double y;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Insert instance';

  @override
  CommandResult apply(EditorState state) {
    final def = state.document.components[componentId];
    if (def == null) {
      return failedCommand(state, label, [
        commandError('Component "$componentId" does not exist.'),
      ]);
    }
    final id = (ids ?? ir.IdGenerator.forDocument(state.document)).next();
    final parent = ir.DocumentIndex.of(state.document).node(parentId);
    final at = parent is ir.FrameNode ? parent.children.length : 0;
    final r = ir.insertNodes(state.document, parentId, at, [
      ir.InstanceNode(
        common: ir.NodeCommon(
          id: id,
          name: def.name,
          x: x,
          y: y,
          width: def.root.common.width,
          height: def.root.common.height,
        ),
        source: ir.InstanceSource.component(componentId),
      ),
    ]);
    return resultOf(state, r, label: label, selectionAfter: {id});
  }
}

/// Runs component edit [edit] (rename, properties, delete) as one undo step.
class ComponentEdit extends EditCommand {
  const ComponentEdit(this.label, this.edit, {this.coalesceKey});

  @override
  final String label;

  @override
  final String? coalesceKey;

  final ir.EditResult Function(ir.StageDocument doc) edit;

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    edit(state.document),
    label: label,
    coalesceKey: coalesceKey,
  );
}
