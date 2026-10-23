import 'package:freezed_annotation/freezed_annotation.dart';

import '../document.dart';
import '../nodes/node.dart';

part 'document_index.freezed.dart';

/// Where an authored node lives in a document (architecture §15, §17.1).
///
/// - `sceneIndex` / `sceneId`: the scene whose root tree holds the node;
///   both null for the document overlay.
/// - `childPath`: child indices from the tree's root to the node (empty for
///   the root itself).
/// - `ancestorIds`: ids from the root down to the parent (empty for a root).
@freezed
abstract class NodeLocation with _$NodeLocation {
  const factory NodeLocation({
    int? sceneIndex,
    String? sceneId,
    required List<int> childPath,
    required List<String> ancestorIds,
  }) = _NodeLocation;

  const NodeLocation._();

  /// The parent's id; null for a root.
  String? get parentId => ancestorIds.isEmpty ? null : ancestorIds.last;

  /// The index among the parent's children; -1 for a root.
  int get index => childPath.isEmpty ? -1 : childPath.last;

  /// Whether this is a scene root (or the overlay root).
  bool get isRoot => childPath.isEmpty;

  /// Whether the node is in the document overlay, not a scene.
  bool get inOverlay => sceneIndex == null;
}

/// `nodeId → child path` for one root tree, cached by the root's identity.
typedef _RootIndex = Map<String, List<int>>;

final Expando<_RootIndex> _rootIndexes = Expando<_RootIndex>('rootIndex');
final Expando<DocumentIndex> _docIndexes = Expando<DocumentIndex>('docIndex');

/// One indexed tree: a scene root, or the overlay (`sceneIndex == null`).
class _Container {
  _Container(this.sceneIndex, this.sceneId, this.root);

  final int? sceneIndex;
  final String? sceneId;
  final FrameNode root;
  late final _RootIndex index = _indexRoot(root);
}

_RootIndex _indexRoot(FrameNode root) {
  final cached = _rootIndexes[root];
  if (cached != null) return cached;
  final out = <String, List<int>>{};
  void walk(Node n, List<int> path) {
    out.putIfAbsent(n.id, () => path);
    if (n is FrameNode) {
      final children = n.children;
      for (var i = 0; i < children.length; i++) {
        walk(children[i], [...path, i]);
      }
    }
  }

  walk(root, const []);
  _rootIndexes[root] = out;
  return out;
}

/// Lets a root tree reuse the index of [from] when the edit that produced
/// [to] kept every node's id and child path (e.g. a property change).
void carryRootIndex(FrameNode from, FrameNode to) {
  if (identical(from, to)) return;
  final cached = _rootIndexes[from];
  if (cached != null && _rootIndexes[to] == null) _rootIndexes[to] = cached;
}

/// A lookup from authored node ids to their place in a document: the scene
/// (or overlay), the child path and the ancestors.
///
/// Built lazily and cheaply: each root tree's index is computed once and
/// cached by the root's *identity*, so after a path-copy edit only the
/// edited scene is re-indexed (O(nodes in that scene)), and a pure property
/// edit reuses the old scene index outright (see [carryRootIndex]).
/// `DocumentIndex.of(doc)` itself is cached per document object.
///
/// Only authored trees are indexed: scene roots and the overlay. Nodes
/// inside instances (resolved ids `<instanceId>/<innerId>`) are not part of
/// the authored tree; component definitions are not indexed. With duplicate
/// ids (an invalid document), the first in tree order wins.
class DocumentIndex {
  DocumentIndex._(this.document)
    : _containers = [
        for (final (i, s) in document.scenes.indexed)
          _Container(i, s.id, s.root),
        if (document.overlay case final o?) _Container(null, null, o),
      ];

  /// The index of [doc] (cached per document object).
  factory DocumentIndex.of(StageDocument doc) =>
      _docIndexes[doc] ??= DocumentIndex._(doc);

  final StageDocument document;
  final List<_Container> _containers;

  _Container? _containerOf(String id) {
    for (final c in _containers) {
      if (c.index.containsKey(id)) return c;
    }
    return null;
  }

  /// Whether an authored node [id] exists.
  bool contains(String id) => _containerOf(id) != null;

  /// Where [id] lives, or null when there is no such authored node.
  NodeLocation? locate(String id) {
    final c = _containerOf(id);
    if (c == null) return null;
    final path = c.index[id]!;
    final ancestors = <String>[];
    Node n = c.root;
    for (final i in path) {
      ancestors.add(n.id);
      n = (n as FrameNode).children[i];
    }
    return NodeLocation(
      sceneIndex: c.sceneIndex,
      sceneId: c.sceneId,
      childPath: path,
      ancestorIds: ancestors,
    );
  }

  /// The authored node [id], or null.
  Node? node(String id) {
    final c = _containerOf(id);
    if (c == null) return null;
    Node n = c.root;
    for (final i in c.index[id]!) {
      n = (n as FrameNode).children[i];
    }
    return n;
  }

  /// The root tree holding [location].
  FrameNode rootOf(NodeLocation location) => location.inOverlay
      ? document.overlay!
      : document.scenes[location.sceneIndex!].root;

  /// Whether [ancestorId] is a strict ancestor of [id].
  bool isAncestor(String ancestorId, String id) =>
      locate(id)?.ancestorIds.contains(ancestorId) ?? false;

  /// The index of the scene [sceneId] in `document.scenes`, or null.
  int? sceneIndexOf(String sceneId) {
    for (final (i, s) in document.scenes.indexed) {
      if (s.id == sceneId) return i;
    }
    return null;
  }

  /// Every indexed node id.
  Iterable<String> get nodeIds sync* {
    for (final c in _containers) {
      yield* c.index.keys;
    }
  }
}
