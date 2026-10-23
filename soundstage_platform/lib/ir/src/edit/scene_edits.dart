import '../diagnostics.dart';
import '../document.dart';
import '../scene.dart';
import 'document_index.dart';
import 'edit_core.dart';
import 'edit_result.dart';

// Pure scene-level edits (architecture §3.2, §15). Untouched scenes keep
// their identity. Errors leave the document unchanged (see [EditResult]).

/// Replaces scene [sceneId] by `change(scene)`. A changed scene id, or new
/// node ids, must not clash with the rest of the document.
EditResult updateScene(
  StageDocument doc,
  String sceneId,
  Scene Function(Scene scene) change,
) {
  final index = DocumentIndex.of(doc);
  final i = index.sceneIndexOf(sceneId);
  if (i == null) return failed(doc, [_missingScene(sceneId)]);
  final old = doc.scenes[i];
  final next = change(old);
  if (identical(next, old)) return unchanged(doc);
  final problem = _clash(doc, index, next, except: i);
  if (problem != null) return failed(doc, [problem]);
  final scenes = [...doc.scenes]..[i] = next;
  if (next.root.id == old.root.id &&
      sameElements(next.root.children, old.root.children)) {
    carryRootIndex(old.root, next.root);
  }
  return EditResult(document: doc.copyWith(scenes: scenes), changed: true);
}

/// Inserts [scene] at [index] (clamped into `0..scenes.length`, with a
/// warning). Its id, node ids and clock ids must be new to the document.
EditResult insertScene(StageDocument doc, int index, Scene scene) {
  final idx = DocumentIndex.of(doc);
  final problem = _clash(doc, idx, scene);
  if (problem != null) return failed(doc, [problem]);
  final diags = <IrDiagnostic>[];
  var at = index;
  if (at < 0 || at > doc.scenes.length) {
    at = at < 0 ? 0 : doc.scenes.length;
    diags.add(
      editWarning(
        IrDiagnosticKind.invalidEdit,
        'Scene index $index is outside 0–${doc.scenes.length}; clamped.',
      ),
    );
  }
  return EditResult(
    document: doc.copyWith(
      scenes: [...doc.scenes.sublist(0, at), scene, ...doc.scenes.sublist(at)],
    ),
    changed: true,
    diagnostics: diags,
    createdIds: [scene.id],
  );
}

/// Removes scene [sceneId]. References to it (scroll-to-scene actions,
/// scene links, other scenes' clocks) are left for `validateDocument` to
/// report.
EditResult removeScene(StageDocument doc, String sceneId) {
  final i = DocumentIndex.of(doc).sceneIndexOf(sceneId);
  if (i == null) return failed(doc, [_missingScene(sceneId)]);
  return EditResult(
    document: doc.copyWith(scenes: [...doc.scenes]..removeAt(i)),
    changed: true,
  );
}

/// Moves scene [sceneId] to insertion point [index] in the current scene
/// list (`0..scenes.length`, counting the scene itself, as a drop indicator
/// shows it; clamped with a warning).
EditResult moveScene(StageDocument doc, String sceneId, int index) {
  final i = DocumentIndex.of(doc).sceneIndexOf(sceneId);
  if (i == null) return failed(doc, [_missingScene(sceneId)]);
  final diags = <IrDiagnostic>[];
  var at = index;
  if (at < 0 || at > doc.scenes.length) {
    at = at < 0 ? 0 : doc.scenes.length;
    diags.add(
      editWarning(
        IrDiagnosticKind.invalidEdit,
        'Scene index $index is outside 0–${doc.scenes.length}; clamped.',
      ),
    );
  }
  final target = at > i ? at - 1 : at;
  if (target == i) return unchanged(doc, diags);
  final scenes = [...doc.scenes];
  final s = scenes.removeAt(i);
  scenes.insert(target, s);
  return EditResult(
    document: doc.copyWith(scenes: scenes),
    changed: true,
    diagnostics: diags,
  );
}

IrDiagnostic _missingScene(String id) =>
    editError(IrDiagnosticKind.missingScene, 'Scene "$id" does not exist.');

/// A clash of [scene] (as scene [except], or a new scene) with the rest of
/// the document: its id, a node id, or a clock id.
IrDiagnostic? _clash(
  StageDocument doc,
  DocumentIndex index,
  Scene scene, {
  int? except,
}) {
  for (final (i, s) in doc.scenes.indexed) {
    if (i == except) continue;
    if (s.id == scene.id) {
      return editError(
        IrDiagnosticKind.invalidEdit,
        'Scene id "${scene.id}" is already used.',
      );
    }
  }
  final otherClocks = {
    for (final (i, s) in doc.scenes.indexed)
      if (i != except) ...s.clocks.map((c) => c.id),
  };
  for (final c in scene.clocks) {
    if (otherClocks.contains(c.id)) {
      return editError(
        IrDiagnosticKind.invalidEdit,
        'Clock id "${c.id}" is already used by another scene.',
      );
    }
  }
  final old = except == null ? null : doc.scenes[except].root;
  if (identical(scene.root, old)) return null;
  final own = <String>{};
  if (old != null) collectIds(old, own);
  final ids = <String>{};
  collectIds(scene.root, ids);
  for (final id in ids) {
    if (!own.contains(id) && index.contains(id)) {
      return editError(
        IrDiagnosticKind.invalidEdit,
        'Node id "$id" is already used in the document.',
        nodeId: id,
      );
    }
  }
  return null;
}
