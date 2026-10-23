import 'package:freezed_annotation/freezed_annotation.dart';

import '../diagnostics.dart';
import '../document.dart';
import '../validate/validate.dart';

part 'edit_result.freezed.dart';

/// The outcome of an edit helper (`lib/ir/src/edit/`).
///
/// Edits are atomic: when [diagnostics] contain an error, [document] is the
/// input document itself (`identical`) and nothing changed. Warnings (an
/// index clamped into range, a reference the edit left dangling) do not
/// stop the edit.
///
/// - `changed`: whether [document] differs from the input (an edit can also
///   be a successful no-op, e.g. moving a node to where it already is).
/// - `idMap`: old id → new id for nodes the edit created from others
///   (`duplicateNodes`).
/// - `createdIds`: ids of the top-level nodes or scenes the edit added, in
///   order (`insertNodes`, `wrapInFrame`, `duplicateNodes`, `insertScene`).
@freezed
abstract class EditResult with _$EditResult {
  const factory EditResult({
    required StageDocument document,
    required bool changed,
    @Default(<IrDiagnostic>[]) List<IrDiagnostic> diagnostics,
    @Default(<String, String>{}) Map<String, String> idMap,
    @Default(<String>[]) List<String> createdIds,
  }) = _EditResult;

  const EditResult._();

  /// Whether the edit was applied (no error diagnostics).
  bool get ok => !hasErrors(diagnostics);
}
