import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// The inspiration board's edits (DECISIONS 26/10/26 #11): undoable like
// any other change; moving or resizing an item in one drag, or typing in a
// note, is one step.

CommandResult _board(
  EditorState state,
  String label,
  List<ir.BoardItem> Function(List<ir.BoardItem> items) change, {
  String? coalesceKey,
}) {
  final doc = state.document;
  // Read once: freezed hands out a new list view on every read.
  final current = doc.board.items;
  final items = change(current);
  if (identical(items, current)) {
    return CommandResult(document: doc, label: label);
  }
  return resultOf(
    state,
    ir.EditResult(
      document: doc.copyWith(board: doc.board.copyWith(items: items)),
      changed: true,
    ),
    label: label,
    coalesceKey: coalesceKey,
  );
}

/// Pins [item] on top of the board.
class AddBoardItem extends EditCommand {
  const AddBoardItem(this.item);

  final ir.BoardItem item;

  @override
  String get label => switch (item.kind) {
    ir.BoardItemKind.note => 'Add note to board',
    ir.BoardItemKind.image => 'Add image to board',
    ir.BoardItemKind.link => 'Add link to board',
  };

  @override
  CommandResult apply(EditorState state) => _board(
    state,
    label,
    (items) => [...items.where((i) => i.id != item.id), item],
  );
}

/// Replaces the board item with [item]'s id (a move, a resize, its words).
class UpdateBoardItem extends EditCommand {
  const UpdateBoardItem(this.item);

  final ir.BoardItem item;

  @override
  String get label => 'Edit board';

  @override
  String get coalesceKey => 'board:${item.id}';

  @override
  CommandResult apply(EditorState state) => _board(state, label, (items) {
    final i = items.indexWhere((x) => x.id == item.id);
    if (i < 0 || items[i] == item) return items;
    return [...items]..[i] = item;
  }, coalesceKey: coalesceKey);
}

/// Takes item [id] off the board.
class RemoveBoardItem extends EditCommand {
  const RemoveBoardItem(this.id);

  final String id;

  @override
  String get label => 'Remove from board';

  @override
  CommandResult apply(EditorState state) => _board(
    state,
    label,
    (items) => items.any((i) => i.id == id)
        ? [...items.where((i) => i.id != id)]
        : items,
  );
}

/// Moves item [id] to the top of the board.
class BringBoardItemToFront extends EditCommand {
  const BringBoardItemToFront(this.id);

  final String id;

  @override
  String get label => 'Bring to front';

  @override
  CommandResult apply(EditorState state) => _board(state, label, (items) {
    final i = items.indexWhere((x) => x.id == id);
    if (i < 0 || i == items.length - 1) return items;
    return [...items]
      ..removeAt(i)
      ..add(items[i]);
  });
}
