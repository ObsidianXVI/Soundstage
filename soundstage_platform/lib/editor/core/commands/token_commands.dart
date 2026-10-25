import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Token system commands (architecture §8; m3.md T3.1). Each wraps one pure
// edit from `lib/ir/src/edit/token_edits.dart`, so every Tokens tab action
// is one undo step. Value editors that scrub or drag pass a [coalesceKey].

/// Runs token edit [edit] on the document as one undo step.
class TokenEdit extends EditCommand {
  const TokenEdit(this.label, this.edit, {this.coalesceKey});

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
