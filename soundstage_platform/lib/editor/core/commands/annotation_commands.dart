import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Annotate mode's edits: undoable like any change; editing one note in a
// typing burst is one step.

CommandResult _annotations(
  EditorState state,
  String label,
  List<ir.Annotation> Function(List<ir.Annotation> list) change, {
  String? coalesceKey,
}) {
  final doc = state.document;
  final current = doc.annotations; // one read: freezed views are new each time
  final next = change(current);
  if (identical(next, current)) {
    return CommandResult(document: doc, label: label);
  }
  return resultOf(
    state,
    ir.EditResult(document: doc.copyWith(annotations: next), changed: true),
    label: label,
    coalesceKey: coalesceKey,
  );
}

class AddAnnotation extends EditCommand {
  const AddAnnotation(this.annotation);

  final ir.Annotation annotation;

  @override
  String get label => 'Annotate';

  @override
  CommandResult apply(EditorState state) => _annotations(
    state,
    label,
    (list) => [...list.where((a) => a.id != annotation.id), annotation],
  );
}

/// Replaces the annotation with [annotation]'s id (its note, status,
/// targets or geometry).
class UpdateAnnotation extends EditCommand {
  const UpdateAnnotation(this.annotation);

  final ir.Annotation annotation;

  @override
  String get label => 'Edit annotation';

  @override
  String get coalesceKey => 'annotation:${annotation.id}';

  @override
  CommandResult apply(EditorState state) => _annotations(state, label, (list) {
    final i = list.indexWhere((a) => a.id == annotation.id);
    if (i < 0 || list[i] == annotation) return list;
    return [...list]..[i] = annotation;
  }, coalesceKey: coalesceKey);
}

class RemoveAnnotation extends EditCommand {
  const RemoveAnnotation(this.id);

  final String id;

  @override
  String get label => 'Remove annotation';

  @override
  CommandResult apply(EditorState state) => _annotations(
    state,
    label,
    (list) =>
        list.any((a) => a.id == id) ? [...list.where((a) => a.id != id)] : list,
  );
}
