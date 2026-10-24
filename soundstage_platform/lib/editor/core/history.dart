import 'package:soundstage_platform/ir/ir.dart' as ir;

/// What undo/redo restore: the document and the selection around it
/// (architecture §15). Documents share every untouched subtree with their
/// neighbours (path-copy edits), so a snapshot costs the edited path only.
class HistorySnapshot {
  const HistorySnapshot({
    required this.document,
    required this.revision,
    this.selection = const {},
    this.selectionContext,
    this.activeSceneId,
  });

  final ir.StageDocument document;
  final int revision;
  final Set<String> selection;
  final String? selectionContext;
  final String? activeSceneId;
}

/// One undoable step: the state before and after it.
class HistoryEntry {
  HistoryEntry({
    required this.label,
    required this.before,
    required this.after,
    this.coalesceKey,
    this.gesture,
  });

  final String label;
  final String? coalesceKey;

  /// The gesture the entry was recorded in (null: none).
  final int? gesture;
  final HistorySnapshot before;
  HistorySnapshot after;
}

/// Snapshot-based undo/redo (architecture §15).
///
/// - **Cap:** at most [cap] undo entries; the oldest drop first.
/// - **Coalescing:** between [beginGesture] and [endGesture] (a drag, a
///   scrub, a typing burst), a command whose `coalesceKey` equals that of
///   the entry recorded just before it in the same gesture extends that
///   entry instead of adding one, so the gesture undoes in one step.
///   Outside a gesture nothing coalesces.
/// - **Branching:** recording after an undo drops the redo stack.
class History {
  History({this.cap = 200}) : assert(cap > 0);

  final int cap;
  final List<HistoryEntry> _undo = [];
  final List<HistoryEntry> _redo = [];
  int _gestureSerial = 0;
  int? _gesture;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;
  int get undoDepth => _undo.length;
  int get redoDepth => _redo.length;
  bool get inGesture => _gesture != null;

  /// The undo entries, oldest first (read-only; for tests and benchmarks).
  List<HistoryEntry> get entries => List.unmodifiable(_undo);

  /// Starts a continuous gesture. Nested calls continue the current one.
  void beginGesture() => _gesture ??= ++_gestureSerial;

  /// Ends the current gesture; later commands start new entries. When the
  /// gesture's last entry ends where it began (the same document object),
  /// it is dropped, and true is returned.
  bool endGesture() {
    final g = _gesture;
    _gesture = null;
    if (g == null || _undo.isEmpty) return false;
    final last = _undo.last;
    if (last.gesture == g &&
        identical(last.before.document, last.after.document)) {
      _undo.removeLast();
      return true;
    }
    return false;
  }

  /// Records a step from [before] to [after].
  void record({
    required String label,
    required HistorySnapshot before,
    required HistorySnapshot after,
    String? coalesceKey,
  }) {
    _redo.clear();
    final last = _undo.isEmpty ? null : _undo.last;
    if (_gesture != null &&
        coalesceKey != null &&
        last != null &&
        last.gesture == _gesture &&
        last.coalesceKey == coalesceKey) {
      last.after = after;
      return;
    }
    _undo.add(
      HistoryEntry(
        label: label,
        before: before,
        after: after,
        coalesceKey: coalesceKey,
        gesture: _gesture,
      ),
    );
    if (_undo.length > cap) _undo.removeAt(0);
  }

  /// Steps back; returns the state to restore, or null.
  HistorySnapshot? undo() {
    if (_undo.isEmpty) return null;
    _gesture = null;
    final e = _undo.removeLast();
    _redo.add(e);
    return e.before;
  }

  /// Steps forward again; returns the state to restore, or null.
  HistorySnapshot? redo() {
    if (_redo.isEmpty) return null;
    _gesture = null;
    final e = _redo.removeLast();
    _undo.add(e);
    return e.after;
  }

  /// The most recent undo entry, or null (an anchor for [squashAfter]).
  HistoryEntry? get lastEntry => _undo.isEmpty ? null : _undo.last;

  /// Merges every undo entry recorded after [anchor] (null: all of them)
  /// into one entry labelled [label] (a text-editing session undoes as one
  /// operation once it ends). The redo stack is dropped when anything
  /// merged. Returns whether the history changed. An [anchor] no longer in
  /// the history (capped away) merges from the oldest entry.
  bool squashAfter(HistoryEntry? anchor, String label) {
    final i = anchor == null ? -1 : _undo.indexOf(anchor);
    final from = i + 1;
    if (from >= _undo.length) return false;
    final merged = HistoryEntry(
      label: label,
      before: _undo[from].before,
      after: _undo.last.after,
    );
    _undo
      ..removeRange(from, _undo.length)
      ..add(merged);
    _redo.clear();
    _gesture = null;
    return true;
  }

  /// Forgets everything (e.g. when another document is opened).
  void clear() {
    _undo.clear();
    _redo.clear();
    _gesture = null;
  }
}
