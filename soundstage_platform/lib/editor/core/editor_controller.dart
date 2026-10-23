import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'command.dart';
import 'commands/property_commands.dart';
import 'editor_state.dart';
import 'history.dart';
import 'selection.dart';
import 'shortcuts.dart';

/// The document the editor opens with. The shell overrides it per route
/// (`/edit/:id`); the default is a blank story with one pinned scene.
final initialDocumentProvider = Provider<ir.StageDocument>((ref) {
  final ids = ir.IdGenerator();
  final doc = ir.StageDocument.empty(ids: ids);
  final scene = ir.Scene.blankPinned(
    ids: ids,
    breakpoint: doc.breakpoints.first,
    name: 'Scene 1',
  );
  return doc.copyWith(scenes: [scene]);
}, dependencies: const []);

/// The editor's state and its mutations (architecture §15).
///
/// Scoped with [initialDocumentProvider]: a `ProviderScope` that overrides
/// the initial document gets its own controller (one per open editor).
final editorControllerProvider =
    NotifierProvider<EditorController, EditorState>(
      EditorController.new,
      dependencies: [initialDocumentProvider],
    );

/// The document resolved for one breakpoint's artboard.
///
/// Compared by identity, never by value: freezed's `==` on a resolved
/// document is a deep walk.
class ResolvedArtboard {
  ResolvedArtboard(this.breakpointId, this.document, this.resolved);

  final String breakpointId;

  /// The editor document [resolved] was produced from.
  final ir.StageDocument document;
  final ir.ResolvedDocument resolved;

  /// The resolved scene [sceneId], or null.
  ir.ResolvedScene? scene(String? sceneId) {
    for (final s in resolved.scenes) {
      if (s.id == sceneId) return s;
    }
    return null;
  }
}

/// [editorControllerProvider]'s document resolved for breakpoint
/// [breakpointId], incrementally: the controller keeps one long-lived
/// [ir.Resolver] per breakpoint, so each side-by-side artboard re-resolves
/// only the path to an edit (a resolver's memo holds one `ResolveContext`;
/// sharing one between breakpoints would drop it on every pass).
final resolvedForProvider = Provider.family<ResolvedArtboard, String>((
  ref,
  breakpointId,
) {
  ref.watch(editorControllerProvider.select((s) => Identity(s.document)));
  return ref.read(editorControllerProvider.notifier).resolvedFor(breakpointId);
}, dependencies: [editorControllerProvider]);

/// A value compared by identity, for `select` over large immutable values
/// (`ref.watch(editorControllerProvider.select((s) => Identity(s.document)))`).
class Identity<T> {
  const Identity(this.value);

  final T value;

  @override
  bool operator ==(Object other) =>
      other is Identity<T> && identical(other.value, value);

  @override
  int get hashCode => identityHashCode(value);
}

/// The editor controller (architecture §15): runs commands through
/// [History], and owns selection, hover, gestures, edit scope, the active
/// scene and artboard.
///
/// Listeners are notified when the state object changes (`identical`), not
/// on deep equality.
class EditorController extends Notifier<EditorState> {
  /// Undo/redo history (cap 200).
  final History history = History();
  int _revisionSerial = 0;
  final Map<String, ir.Resolver> _resolvers = {};
  final Map<String, ResolvedArtboard> _resolved = {};

  @override
  EditorState build() {
    history.clear();
    _revisionSerial = 0;
    _resolved.clear();
    return EditorState.initial(ref.watch(initialDocumentProvider));
  }

  @override
  bool updateShouldNotify(EditorState previous, EditorState next) =>
      !identical(previous, next);

  // ---- Commands and history --------------------------------------------

  /// Applies [command]. A failed or no-op command changes nothing and is
  /// not recorded; a successful one is recorded (coalesced within a
  /// gesture by its `coalesceKey`). Returns the command's result.
  CommandResult execute(EditCommand command) {
    final s = state;
    final r = command.apply(s);
    if (!r.ok || !r.changed) {
      if (r.ok && r.selectionAfter != null) {
        select(r.selectionAfter!);
      }
      return r;
    }
    final doc = r.document;
    final index = ir.DocumentIndex.of(doc);
    final selection =
        r.selectionAfter ??
        {
          for (final id in s.selection)
            if (index.contains(id.split('/').first)) id,
        };
    final scene =
        r.activeSceneAfter ??
        (index.sceneIndexOf(s.activeSceneId ?? '') != null
            ? s.activeSceneId
            : (doc.scenes.isEmpty ? null : doc.scenes.first.id));
    final context = r.selectionAfter != null
        ? _contextFor(index, selection, s.selectionContext)
        : (s.selectionContext != null && index.contains(s.selectionContext!)
              ? s.selectionContext
              : null);
    final rev = ++_revisionSerial;
    history.record(
      label: r.label,
      coalesceKey: r.coalesceKey,
      before: _snapshot(s),
      after: HistorySnapshot(
        document: doc,
        revision: rev,
        selection: selection,
        selectionContext: context,
        activeSceneId: scene,
      ),
    );
    state = s.copyWith(
      document: doc,
      revision: rev,
      selection: selection,
      selectionContext: context,
      activeSceneId: scene,
      textEditId: selection.contains(s.textEditId) ? s.textEditId : null,
      hoverId: s.hoverId != null && index.contains(s.hoverId!.split('/').first)
          ? s.hoverId
          : null,
      history: _status(),
    );
    return r;
  }

  /// Undoes the last entry, restoring its document and selection. Returns
  /// false when there is nothing to undo.
  bool undo() => _restore(history.undo());

  /// Redoes the last undone entry. Returns false when there is none.
  bool redo() => _restore(history.redo());

  /// Starts a continuous gesture (drag, scrub, typing): commands with the
  /// same coalescing key until [endGesture] become one undo entry.
  void beginGesture() => history.beginGesture();

  void endGesture() => history.endGesture();

  /// Opens [document] fresh: history cleared, revision saved.
  void openDocument(ir.StageDocument document) {
    history.clear();
    final rev = ++_revisionSerial;
    state = EditorState.initial(
      document,
    ).copyWith(revision: rev, savedRevision: rev);
  }

  /// Marks the current revision as saved (autosave, T1.11).
  void markSaved() => state = state.copyWith(savedRevision: state.revision);

  // ---- Selection ----------------------------------------------------------

  /// Sets the selection; [context] defaults to the first node's parent.
  void select(Set<String> ids, {String? context}) {
    final index = ir.DocumentIndex.of(state.document);
    state = state.copyWith(
      selection: ids,
      selectionContext: context ?? _contextFor(index, ids, null),
      textEditId: null,
    );
  }

  /// Applies a result of the selection rules (`selection.dart`).
  void applySelection(SelectionState s) => state = state.copyWith(
    selection: s.selection,
    selectionContext: s.context,
    textEditId: s.textEditId,
  );

  /// The current selection as a [SelectionState].
  SelectionState get selectionState => SelectionState(
    selection: state.selection,
    context: state.selectionContext,
    textEditId: state.textEditId,
  );

  /// The active scene's tree at breakpoint [breakpointId] (default: the
  /// edited one), for the selection rules. Null without an active scene.
  SelectionTree? selectionTree([String? breakpointId]) {
    final bp = breakpointId ?? state.breakpointId;
    if (bp == null) return null;
    final scene = resolvedFor(bp).scene(state.activeSceneId);
    return scene == null ? null : ResolvedSelectionTree.of(scene.root);
  }

  void _withTree(SelectionState Function(SelectionTree t) rule) {
    final t = selectionTree();
    if (t != null) applySelection(rule(t));
  }

  /// A canvas click on [hits] (ids under the pointer, topmost first).
  void click(List<String> hits, SelectionModifiers modifiers) =>
      _withTree((t) => clickSelect(t, hits, modifiers, selectionState));

  void doubleClick(List<String> hits) =>
      _withTree((t) => doubleClickSelect(t, hits, selectionState));

  /// Esc.
  void selectParentOfSelection() =>
      _withTree((t) => selectParent(t, selectionState));

  /// Enter.
  void selectChildrenOfSelection() =>
      _withTree((t) => selectChildren(t, selectionState));

  /// Tab / Shift-Tab.
  void selectNextSibling({bool backwards = false}) =>
      _withTree((t) => selectSibling(t, selectionState, backwards: backwards));

  void marquee(
    ir.StageRect rect,
    Map<String, ir.StageRect> boxes,
    SelectionModifiers modifiers,
  ) => _withTree(
    (t) => marqueeSelect(t, rect, boxes, modifiers, selectionState),
  );

  void selectAllInContext() => _withTree((t) => selectAll(t, selectionState));

  void clearSelection() => applySelection(selectNone(selectionState));

  void hover(String? nodeId) {
    if (state.hoverId != nodeId) state = state.copyWith(hoverId: nodeId);
  }

  // ---- Scope, scene, artboard, tool, playhead ----------------------------

  void setEditScope(EditScope scope) =>
      state = state.copyWith(editScope: scope);

  void toggleEditScope() =>
      state = state.copyWith(editScope: state.editScope.flipped);

  /// Alt held (flips the scope for the edits made while it is down).
  void setScopeFlipped(bool flipped) {
    if (state.scopeFlipped != flipped) {
      state = state.copyWith(scopeFlipped: flipped);
    }
  }

  /// Shows scene [sceneId]; the selection is cleared.
  void setActiveScene(String sceneId) {
    if (state.activeSceneId == sceneId) return;
    if (ir.DocumentIndex.of(state.document).sceneIndexOf(sceneId) == null) {
      return;
    }
    state = state.copyWith(
      activeSceneId: sceneId,
      selection: const {},
      selectionContext: null,
      textEditId: null,
      hoverId: null,
    );
  }

  /// The artboard being edited (its breakpoint receives *This breakpoint*
  /// writes).
  void setEditingBreakpoint(String breakpointId) {
    if (state.document.breakpoints.any((b) => b.id == breakpointId)) {
      state = state.copyWith(editingBreakpointId: breakpointId);
    }
  }

  void setTool(EditorTool tool) => state = state.copyWith(tool: tool);

  void setPlayhead(String sceneId, double t) =>
      state = state.copyWith(playheads: {...state.playheads, sceneId: t});

  /// Auto-key (M2: no effect on writes in M1).
  void setAutoKey(bool on) => state = state.copyWith(autoKey: on);

  // ---- Resolution ---------------------------------------------------------

  /// The long-lived resolver of breakpoint [breakpointId].
  ir.Resolver resolverFor(String breakpointId) =>
      _resolvers[breakpointId] ??= ir.Resolver();

  /// The current document resolved for [breakpointId] (cached until the
  /// document changes; see [resolvedForProvider]).
  ResolvedArtboard resolvedFor(String breakpointId) {
    final doc = state.document;
    final last = _resolved[breakpointId];
    if (last != null && identical(last.document, doc)) return last;
    return _resolved[breakpointId] = ResolvedArtboard(
      breakpointId,
      doc,
      resolverFor(
        breakpointId,
      ).resolve(doc, ir.ResolveContext(breakpointId: breakpointId)),
    );
  }

  // ---- Inspector ----------------------------------------------------------

  /// How [path] of [nodeId] gets its value at [breakpointId] (default: the
  /// edited breakpoint), for the inspector's value-source badge. Uses that
  /// breakpoint's long-lived resolver, so only the node's path is traced.
  ir.Provenance provenanceFor(
    String nodeId,
    String path, [
    String? breakpointId,
  ]) {
    final bp = breakpointId ?? state.breakpointId;
    final ctx = ir.ResolveContext(breakpointId: bp);
    if (bp == null) {
      return ir.Resolver().explain(
        state.document,
        nodeId,
        ir.PropertyPath(path),
        ctx,
      );
    }
    resolvedFor(bp); // brings the memo up to date
    return resolverFor(
      bp,
    ).explain(state.document, nodeId, ir.PropertyPath(path), ctx);
  }

  /// Resets [path] on [nodeIds] (default: the selection) to what it
  /// inherits in the current scope (see [ResetProperty]).
  CommandResult resetProperty(String path, [List<String>? nodeIds]) {
    final bp = state.breakpointId;
    if (bp != null) resolvedFor(bp);
    return execute(
      ResetProperty(
        nodeIds ?? state.selection.toList(),
        path,
        resolver: bp == null ? null : resolverFor(bp),
      ),
    );
  }

  // ---- Shortcuts ----------------------------------------------------------

  /// Performs a keyboard [intent] (see `shortcuts.dart`). Returns the
  /// action taken, so the shell can handle UI-only ones ([BeginRename]).
  EditorAction perform(EditorIntent intent) {
    final action = actionForIntent(intent, state, tree: selectionTree());
    switch (action) {
      case RunCommand(:final command):
        execute(command);
      case UndoAction():
        undo();
      case RedoAction():
        redo();
      case ApplySelection(:final selection):
        applySelection(selection);
      case BeginRename() || NoAction():
        break;
    }
    return action;
  }

  // ---- Internals ----------------------------------------------------------

  HistorySnapshot _snapshot(EditorState s) => HistorySnapshot(
    document: s.document,
    revision: s.revision,
    selection: s.selection,
    selectionContext: s.selectionContext,
    activeSceneId: s.activeSceneId,
  );

  bool _restore(HistorySnapshot? snap) {
    if (snap == null) return false;
    state = state.copyWith(
      document: snap.document,
      revision: snap.revision,
      selection: snap.selection,
      selectionContext: snap.selectionContext,
      activeSceneId: snap.activeSceneId,
      textEditId: null,
      hoverId: null,
      history: _status(),
    );
    return true;
  }

  HistoryStatus _status() => HistoryStatus(
    canUndo: history.canUndo,
    canRedo: history.canRedo,
    undoLabel: history.undoLabel,
    redoLabel: history.redoLabel,
  );

  /// The parent of the first authored node of [ids] (null for a root's
  /// children); [fallback] for instance inner ids.
  static String? _contextFor(
    ir.DocumentIndex index,
    Set<String> ids,
    String? fallback,
  ) {
    if (ids.isEmpty) return null;
    final first = ids.first;
    if (first.contains('/')) return fallback;
    final loc = index.locate(first);
    if (loc == null || loc.ancestorIds.length < 2) return null;
    return loc.parentId;
  }
}
