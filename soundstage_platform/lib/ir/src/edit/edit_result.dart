import 'package:freezed_annotation/freezed_annotation.dart';

import '../diagnostics.dart';
import '../document.dart';
import '../interactions.dart';
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
/// - `cascade`: what the edit removed or rewrote beyond the nodes it was
///   asked to change (`removeNodes`, `moveNodes`).
@freezed
abstract class EditResult with _$EditResult {
  const factory EditResult({
    required StageDocument document,
    required bool changed,
    @Default(<IrDiagnostic>[]) List<IrDiagnostic> diagnostics,
    @Default(<String, String>{}) Map<String, String> idMap,
    @Default(<String>[]) List<String> createdIds,
    @Default(EditCascade()) EditCascade cascade,
  }) = _EditResult;

  const EditResult._();

  /// Whether the edit was applied (no error diagnostics).
  bool get ok => !hasErrors(diagnostics);
}

/// References an edit removed or rebound along with the nodes it changed
/// (DECISIONS 23/10/26, T1.0 follow-ups), so the editor can report them
/// and undo restores everything (it restores the whole document).
///
/// - `removedTrackIds`: tracks removed because they targeted a removed node
///   or ran on a removed clock.
/// - `removedClockIds`: pointer and behaviour clocks removed because they
///   were bound to a removed node.
/// - `removedActions`: interaction actions removed because they referred to
///   a removed node (lightbox) or a removed clock.
/// - `removedInteractions`: interactions removed because their trigger
///   referred to a removed clock, or because they lost their last action.
/// - `clockIdMap`: source clock id → id of the copy made in the destination
///   scene, for clocks `moveNodes` copied across scenes.
@freezed
abstract class EditCascade with _$EditCascade {
  const factory EditCascade({
    @Default(<String>[]) List<String> removedTrackIds,
    @Default(<String>[]) List<String> removedClockIds,
    @Default(<CascadedAction>[]) List<CascadedAction> removedActions,
    @Default(<CascadedInteraction>[])
    List<CascadedInteraction> removedInteractions,
    @Default(<String, String>{}) Map<String, String> clockIdMap,
  }) = _EditCascade;

  const EditCascade._();

  /// Whether the edit touched nothing beyond what it was asked to change.
  bool get isEmpty =>
      removedTrackIds.isEmpty &&
      removedClockIds.isEmpty &&
      removedActions.isEmpty &&
      removedInteractions.isEmpty &&
      clockIdMap.isEmpty;
}

/// An action removed from interaction [interactionId] of node [nodeId].
@freezed
abstract class CascadedAction with _$CascadedAction {
  const factory CascadedAction({
    required String nodeId,
    required String interactionId,
    required Action action,
  }) = _CascadedAction;
}

/// Interaction [interaction] removed from node [nodeId].
@freezed
abstract class CascadedInteraction with _$CascadedInteraction {
  const factory CascadedInteraction({
    required String nodeId,
    required Interaction interaction,
  }) = _CascadedInteraction;
}
