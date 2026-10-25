import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Interaction commands (architecture §10.3; m3.md T3.4). Interactions live on
// the node's shared base (they do not vary by breakpoint).

/// Replaces the interactions of node [nodeId] with [interactions].
class SetInteractions extends EditCommand {
  const SetInteractions(
    this.nodeId,
    this.interactions, {
    this.label = 'Change interactions',
    this.coalesceKey,
  });

  final String nodeId;
  final List<ir.Interaction> interactions;

  @override
  final String label;

  @override
  final String? coalesceKey;

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateNode(
      state.document,
      nodeId,
      (n) => n.copyWith(common: n.common.copyWith(interactions: interactions)),
    ),
    label: label,
    coalesceKey: coalesceKey,
  );
}
