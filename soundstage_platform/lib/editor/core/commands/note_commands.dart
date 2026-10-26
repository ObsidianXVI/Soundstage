import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

/// Sets or clears (empty text) the author's note on scene or node [id]
/// (m5.md T5.3). Notes are private: publishing drops them.
class SetNote extends EditCommand {
  const SetNote(this.id, this.text);

  final String id;
  final String text;

  @override
  String get label => text.trim().isEmpty ? 'Remove note' : 'Edit note';

  @override
  String get coalesceKey => 'note:$id';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final index = ir.DocumentIndex.of(doc);
    if (!index.contains(id) && index.sceneIndexOf(id) == null) {
      return failedCommand(state, label, [
        commandError('There is no scene or layer "$id".', nodeId: id),
      ]);
    }
    final trimmed = text.trim();
    final current = doc.notes[id];
    if ((current ?? '') == (trimmed.isEmpty ? '' : text)) {
      return CommandResult(document: doc, label: label);
    }
    final notes = {...doc.notes};
    if (trimmed.isEmpty) {
      notes.remove(id);
    } else {
      notes[id] = text;
    }
    return resultOf(
      state,
      ir.EditResult(document: doc.copyWith(notes: notes), changed: true),
      label: label,
      coalesceKey: coalesceKey,
    );
  }
}
