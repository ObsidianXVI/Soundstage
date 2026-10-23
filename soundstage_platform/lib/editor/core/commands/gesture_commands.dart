import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

/// One step of a canvas gesture (move, resize, rotate): recomputes the
/// gesture's whole effect from the document it started from ([base]) on
/// every pointer move, so steps never accumulate rounding or depend on the
/// previous frame.
///
/// - [edit] receives the editor state with `document == base` and the Alt
///   scope flip cleared: during a drag Alt means "from centre" (resize) or
///   "duplicate" (move), so a drag's edit scope comes from the toolbar only
///   (DECISIONS 23/10/26 T1.4).
/// - Every step of one gesture shares [coalesceKey], so between
///   `beginGesture` and `endGesture` the gesture records one undo entry
///   whose "before" is the document before the gesture's first step. A
///   step that brings the document back to where it already is records
///   nothing; a gesture that ends where it started leaves no entry
///   (`History.endGesture`).
class GestureStep extends EditCommand {
  GestureStep({
    required this.label,
    required this.coalesceKey,
    required this.base,
    required this.edit,
    this.selectionAfter,
  });

  @override
  final String label;

  @override
  final String coalesceKey;

  /// The document the gesture computes from.
  final ir.StageDocument base;

  final ir.EditResult Function(EditorState state) edit;

  /// The selection after the step (null keeps it).
  final Set<String>? selectionAfter;

  @override
  CommandResult apply(EditorState state) {
    final s = state.copyWith(document: base, scopeFlipped: false);
    final r = edit(s);
    if (!r.ok) return failedCommand(state, label, r.diagnostics);
    return CommandResult(
      document: r.document,
      label: label,
      changed: !identical(r.document, state.document),
      selectionAfter: selectionAfter,
      coalesceKey: coalesceKey,
      diagnostics: r.diagnostics,
      cascade: r.cascade,
    );
  }
}

/// Runs [steps] in order on a running document; the first failure stops
/// the chain and fails the whole edit (atomic).
ir.EditResult chainEdits(
  EditorState state,
  List<ir.EditResult Function(EditorState s)> steps,
) {
  var s = state;
  var changed = false;
  final diags = <ir.IrDiagnostic>[];
  var cascade = const ir.EditCascade();
  for (final step in steps) {
    final r = step(s);
    diags.addAll(r.diagnostics);
    if (!r.ok) {
      return ir.EditResult(
        document: state.document,
        changed: false,
        diagnostics: diags,
      );
    }
    changed |= r.changed;
    if (r.cascade.clockIdMap.isNotEmpty) cascade = r.cascade;
    s = s.copyWith(document: r.document);
  }
  return ir.EditResult(
    document: s.document,
    changed: changed,
    diagnostics: diags,
    cascade: cascade,
  );
}

/// [command] applied to [s] as an [ir.EditResult] (for [chainEdits]).
ir.EditResult commandEdit(EditorState s, EditCommand command) {
  final r = command.apply(s);
  return ir.EditResult(
    document: r.document,
    changed: r.changed,
    diagnostics: r.diagnostics,
    cascade: r.cascade,
  );
}
