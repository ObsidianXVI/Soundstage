import 'package:flutter/rendering.dart';

import '../render/render_stage_box.dart';

/// Receives registry changes (the animator binds and unbinds its tracks).
abstract interface class StageNodeListener {
  void nodeAttached(RenderStageBox box);
  void nodeDetached(RenderStageBox box);
}

/// `nodeId → RenderStageBox` for the nodes currently in the render tree
/// (architecture §14). Render objects register themselves on attach and
/// unregister on detach, so the animator resolves each track's target once
/// per attach instead of searching per frame, and lazily built scenes bind
/// as they appear.
///
/// In edit mode this is also the `NodeGeometryRegistry` the editor overlay
/// reads node geometry from ([boxOf]).
class StageNodeRegistry {
  final Map<String, RenderStageBox> _nodes = {};

  /// Notified of every attach and detach.
  StageNodeListener? listener;

  /// The attached render object of node [id] (namespaced), if any.
  RenderStageBox? operator [](String id) => _nodes[id];

  /// The render box of node [id] for geometry queries (edit overlay).
  RenderBox? boxOf(String id) => _nodes[id];

  /// Ids of every attached node.
  Iterable<String> get ids => _nodes.keys;

  int get length => _nodes.length;

  void attachNode(RenderStageBox box) {
    _nodes[box.nodeId] = box;
    listener?.nodeAttached(box);
  }

  void detachNode(RenderStageBox box) {
    final id = box.nodeId;
    if (identical(_nodes[id], box)) _nodes.remove(id);
    listener?.nodeDetached(box);
  }
}
