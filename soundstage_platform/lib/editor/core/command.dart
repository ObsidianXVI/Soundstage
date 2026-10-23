import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
// Unprefixed for freezed's generated nested copyWith.
import 'package:soundstage_platform/ir/ir.dart'
    show $EditCascadeCopyWith, $StageDocumentCopyWith;

import 'editor_state.dart';

part 'command.freezed.dart';

/// What a command did (architecture §15).
///
/// Commands are atomic: when [diagnostics] hold an error, [document] is the
/// input document (`identical`) and nothing is recorded.
///
/// - `selectionAfter`: the selection once the command applied; null keeps
///   the current selection (minus nodes that no longer exist).
/// - `activeSceneAfter`: the scene to show afterwards; null keeps it.
/// - `coalesceKey`: within one gesture, consecutive commands with the same
///   key become one history entry.
/// - `cascade`: references the edit removed or rebound beyond its targets.
@freezed
abstract class CommandResult with _$CommandResult {
  const factory CommandResult({
    required ir.StageDocument document,
    required String label,
    @Default(false) bool changed,
    Set<String>? selectionAfter,
    String? activeSceneAfter,
    String? coalesceKey,
    @Default(<ir.IrDiagnostic>[]) List<ir.IrDiagnostic> diagnostics,
    @Default(ir.EditCascade()) ir.EditCascade cascade,
  }) = _CommandResult;

  const CommandResult._();

  /// Whether the command applied (no error diagnostics).
  bool get ok => !ir.hasErrors(diagnostics);
}

/// A named, pure document mutation (architecture §15): `apply` reads the
/// editor state and returns the new document plus an undo label. It never
/// mutates anything and never throws; problems are diagnostics.
abstract class EditCommand {
  const EditCommand();

  /// The undo/redo label ("Change opacity", "Delete 3 layers").
  String get label;

  /// Commands with equal keys coalesce within one gesture (a drag, a scrub,
  /// a typing burst); null never coalesces.
  String? get coalesceKey => null;

  CommandResult apply(EditorState state);
}

/// A [CommandResult] from an IR [ir.EditResult].
CommandResult resultOf(
  EditorState state,
  ir.EditResult r, {
  required String label,
  Set<String>? selectionAfter,
  String? activeSceneAfter,
  String? coalesceKey,
}) => CommandResult(
  document: r.ok ? r.document : state.document,
  label: label,
  changed: r.ok && r.changed,
  selectionAfter: r.ok ? selectionAfter : null,
  activeSceneAfter: r.ok ? activeSceneAfter : null,
  coalesceKey: coalesceKey,
  diagnostics: r.diagnostics,
  cascade: r.cascade,
);

/// A failed command: the document unchanged, with [diagnostics].
CommandResult failedCommand(
  EditorState state,
  String label,
  List<ir.IrDiagnostic> diagnostics,
) => CommandResult(
  document: state.document,
  label: label,
  diagnostics: diagnostics,
);

/// An error diagnostic for an editor command.
ir.IrDiagnostic commandError(String message, {String? nodeId, String? path}) =>
    ir.IrDiagnostic(
      ir.IrDiagnosticKind.invalidEdit,
      message,
      nodeId: nodeId,
      path: path,
    );

/// A warning diagnostic for an editor command.
ir.IrDiagnostic commandWarning(
  String message, {
  String? nodeId,
  String? path,
}) => ir.IrDiagnostic(
  ir.IrDiagnosticKind.invalidEdit,
  message,
  nodeId: nodeId,
  path: path,
  severity: ir.IrSeverity.warning,
);

/// [d] as a warning (for one node of a multi-node command that others
/// completed).
ir.IrDiagnostic asWarning(ir.IrDiagnostic d) => ir.IrDiagnostic(
  d.kind,
  d.message,
  nodeId: d.nodeId,
  path: d.path,
  severity: ir.IrSeverity.warning,
);

/// "layer" / "3 layers".
String layers(int n) => n == 1 ? 'layer' : '$n layers';

/// Applies [edit] to each node of [nodeIds] in turn on a running document.
///
/// Nodes whose edit fails are skipped and their errors become warnings, as
/// long as one node succeeded (a mixed selection where a property applies
/// to some nodes only). When every node fails, the result is a failed edit
/// with all the errors.
ir.EditResult perNode(
  ir.StageDocument doc,
  Iterable<String> nodeIds,
  ir.EditResult Function(ir.StageDocument doc, String nodeId) edit,
) {
  var current = doc;
  var changed = false;
  var any = false;
  final diags = <ir.IrDiagnostic>[];
  final errors = <ir.IrDiagnostic>[];
  for (final id in nodeIds) {
    final r = edit(current, id);
    if (!r.ok) {
      errors.addAll(
        r.diagnostics.where((d) => d.severity == ir.IrSeverity.error),
      );
      diags.addAll(
        r.diagnostics.where((d) => d.severity != ir.IrSeverity.error),
      );
      continue;
    }
    any = true;
    changed |= r.changed;
    current = r.document;
    diags.addAll(r.diagnostics);
  }
  if (!any && errors.isNotEmpty) {
    return ir.EditResult(document: doc, changed: false, diagnostics: errors);
  }
  return ir.EditResult(
    document: current,
    changed: changed,
    diagnostics: [...diags, ...errors.map(asWarning)],
  );
}
