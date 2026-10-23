// Internal building blocks of the edit helpers: path-copying tree rewrites
// and shared checks. Not exported from `ir.dart`.

import '../diagnostics.dart';
import '../document.dart';
import '../nodes/node.dart';
import '../scene.dart';
import 'document_index.dart';
import 'edit_result.dart';

/// The container key of [loc]: the scene index, or -1 for the overlay.
int containerKey(NodeLocation loc) => loc.sceneIndex ?? -1;

/// A failed (atomic) edit: [doc] unchanged.
EditResult failed(StageDocument doc, List<IrDiagnostic> diagnostics) =>
    EditResult(document: doc, changed: false, diagnostics: diagnostics);

/// An unchanged, successful edit.
EditResult unchanged(
  StageDocument doc, [
  List<IrDiagnostic> diagnostics = const [],
]) => EditResult(document: doc, changed: false, diagnostics: diagnostics);

IrDiagnostic editError(
  IrDiagnosticKind kind,
  String message, {
  String? nodeId,
  String? path,
}) => IrDiagnostic(kind, message, nodeId: nodeId, path: path);

IrDiagnostic editWarning(
  IrDiagnosticKind kind,
  String message, {
  String? nodeId,
  String? path,
}) => IrDiagnostic(
  kind,
  message,
  nodeId: nodeId,
  path: path,
  severity: IrSeverity.warning,
);

/// Locates an authored node [id] for editing, or reports why it can't be:
/// `editInsideInstance` for a resolved instance-inner id
/// (`<instanceId>/<innerId>`), `missingNode` otherwise.
NodeLocation? locateForEdit(
  DocumentIndex index,
  String id,
  List<IrDiagnostic> out,
) {
  final loc = index.locate(id);
  if (loc != null) return loc;
  final slash = id.indexOf('/');
  if (slash > 0 && index.node(id.substring(0, slash)) is InstanceNode) {
    out.add(
      editError(
        IrDiagnosticKind.editInsideInstance,
        'Node "$id" is inside instance "${id.substring(0, slash)}"; edit it '
        'through an instance override.',
        nodeId: id,
      ),
    );
  } else {
    out.add(
      editError(
        IrDiagnosticKind.missingNode,
        'Node "$id" does not exist.',
        nodeId: id,
      ),
    );
  }
  return null;
}

/// Whether [a] and [b] hold the same elements by identity.
bool sameElements<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}

/// Every node id in the subtree of [n], [n] included.
void collectIds(Node n, Set<String> out) {
  out.add(n.id);
  if (n is FrameNode) {
    for (final c in n.children) {
      collectIds(c, out);
    }
  }
}

/// A path-copying rewrite of a document's trees.
///
/// - `replace[id]`: the node with that id is replaced by the function's
///   result (its subtree is not visited further).
/// - `children[id]`: the frame's (already rewritten) children are passed
///   through the function.
///
/// Only the frames on the path from a root to an edited node are copied;
/// every other node, and every untouched scene, keeps its identity. A
/// children edit that returns the same elements leaves the frame as is.
/// `sceneEdits[sceneIndex]` then post-processes a scene (e.g. its tracks);
/// it runs whether or not the scene's root changed.
class TreeRewrite {
  TreeRewrite(this.doc, this.index);

  final StageDocument doc;
  final DocumentIndex index;
  final Map<String, Node Function(Node)> replace = {};
  final Map<String, List<Node> Function(List<Node>)> children = {};
  final Map<int, Scene Function(Scene)> sceneEdits = {};

  /// Applies the rewrite. Ids in [replace]/[children] must be located.
  StageDocument apply() {
    final descend = <int, Set<String>>{};
    void mark(String id, {required bool self}) {
      final loc = index.locate(id)!;
      final set = descend[containerKey(loc)] ??= <String>{};
      set.addAll(loc.ancestorIds);
      if (self) set.add(id);
    }

    for (final id in replace.keys) {
      mark(id, self: false);
    }
    for (final id in children.keys) {
      mark(id, self: true);
    }

    Node visit(Node n, Set<String> down) {
      final r = replace[n.id];
      if (r != null) return r(n);
      if (n is! FrameNode || !down.contains(n.id)) return n;
      final old = n.children;
      var kids = [
        for (final c in old)
          down.contains(c.id) || replace.containsKey(c.id) ? visit(c, down) : c,
      ];
      final edit = children[n.id];
      if (edit != null) kids = edit(kids);
      return sameElements(kids, old) ? n : n.copyWith(children: kids);
    }

    FrameNode root(FrameNode r, int key) {
      final down = descend[key];
      if (down == null && !replace.containsKey(r.id)) return r;
      final out = visit(r, down ?? const {});
      return out is FrameNode ? out : r;
    }

    List<Scene>? scenes;
    for (var i = 0; i < doc.scenes.length; i++) {
      final s = doc.scenes[i];
      final newRoot = root(s.root, i);
      var next = identical(newRoot, s.root) ? s : s.copyWith(root: newRoot);
      final fix = sceneEdits[i];
      if (fix != null) next = fix(next);
      if (!identical(next, s)) (scenes ??= [...doc.scenes])[i] = next;
    }
    final overlay = doc.overlay;
    final newOverlay = overlay == null ? null : root(overlay, -1);
    if (scenes == null && identical(newOverlay, overlay)) return doc;
    return doc.copyWith(scenes: scenes ?? doc.scenes, overlay: newOverlay);
  }
}
