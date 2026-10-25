import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';
import '../text_size_sync.dart';

// Breakpoint editing (T1.10): reset a node's overrides on one breakpoint,
// and the breakpoint manager's add / edit / remove. All undoable.

/// The display name of breakpoint [id] in [doc] ([id] when unknown).
String breakpointName(ir.StageDocument doc, String? id) {
  for (final b in doc.breakpoints) {
    if (b.id == id) return b.name;
  }
  return id ?? '';
}

/// Whether any of [nodeIds] (authored ids) has a patch on [breakpointId].
bool hasOverridesOn(
  ir.StageDocument doc,
  Iterable<String> nodeIds,
  String? breakpointId,
) {
  if (breakpointId == null) return false;
  final index = ir.DocumentIndex.of(doc);
  for (final id in nodeIds) {
    final n = index.node(id);
    if (n != null && hasShownOverride(n, breakpointId)) return true;
  }
  return false;
}

/// Clears every patch of [nodeIds] on breakpoint [breakpointId] (default:
/// the breakpoint in effect on the edited artboard), so those nodes show
/// the shared base (plus inherited patches) there again: "Reset overrides
/// on Tablet". Instance inner nodes are skipped (their overrides apply at
/// every breakpoint).
class ResetBreakpointOverrides extends EditCommand {
  const ResetBreakpointOverrides(this.nodeIds, {this.breakpointId});

  final List<String> nodeIds;
  final String? breakpointId;

  @override
  String get label => 'Reset overrides';

  @override
  CommandResult apply(EditorState state) {
    final bp = breakpointId ?? state.breakpointId;
    final label = 'Reset overrides on ${breakpointName(state.document, bp)}';
    if (bp == null) {
      return failedCommand(state, label, [
        commandError('The document has no breakpoint.'),
      ]);
    }
    final ids = [
      for (final id in nodeIds)
        if (!id.contains('/')) id,
    ];
    final r = perNode(
      state.document,
      ids,
      (doc, id) => ir.clearBreakpointPatch(doc, id, bp),
    );
    return resultOf(state, r, label: label);
  }
}

/// Adds [breakpoint] (validated: no cycles, unique id, a primary remains).
/// A primary breakpoint gets an artboard.
class AddBreakpoint extends EditCommand {
  const AddBreakpoint(this.breakpoint);

  final ir.Breakpoint breakpoint;

  @override
  String get label => 'Add breakpoint ${breakpoint.name}';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.addBreakpoint(state.document, breakpoint),
    label: label,
  );
}

/// Replaces breakpoint [breakpoint.id] (name, min width, design size,
/// `inheritsFrom`, primary), validated like [AddBreakpoint].
class UpdateBreakpoint extends EditCommand {
  const UpdateBreakpoint(this.breakpoint);

  final ir.Breakpoint breakpoint;

  @override
  String get label => 'Edit breakpoint ${breakpoint.name}';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateBreakpoint(state.document, breakpoint.id, breakpoint),
    label: label,
  );
}

/// Removes breakpoint [breakpointId] with all its patches (see
/// `ir.removeBreakpoint`). The last primary breakpoint can't be removed.
class RemoveBreakpoint extends EditCommand {
  const RemoveBreakpoint(this.breakpointId);

  final String breakpointId;

  @override
  String get label => 'Remove breakpoint';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.removeBreakpoint(state.document, breakpointId),
    label: 'Remove breakpoint ${breakpointName(state.document, breakpointId)}',
  );
}

/// The number of authored nodes in [doc] with a patch on [breakpointId]
/// (for the remove confirmation).
int patchedNodeCount(ir.StageDocument doc, String breakpointId) {
  var n = 0;
  void walk(ir.Node node) {
    if (ir.hasBreakpointPatch(node, breakpointId)) n++;
    if (node is ir.FrameNode) {
      for (final c in node.children) {
        walk(c);
      }
    }
  }

  for (final s in doc.scenes) {
    walk(s.root);
  }
  if (doc.overlay case final o?) walk(o);
  for (final c in doc.components.values) {
    walk(c.root);
  }
  return n;
}
