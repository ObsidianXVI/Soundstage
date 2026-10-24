import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../canvas/canvas_controller.dart';
import '../interaction/snapping.dart';
import '../interaction/transform_math.dart';

/// Where on the canvas a new node goes (T1.9): the frame under the pointer
/// and, when that frame has auto layout, the place in its flow.
class InsertTarget {
  const InsertTarget({
    required this.breakpointId,
    required this.parentId,
    required this.toParent,
    this.flowIndex,
  });

  /// The artboard (primary breakpoint) the pointer is on.
  final String breakpointId;

  /// The frame that takes the node.
  final String parentId;

  /// World → the parent's local space.
  final Matrix4 toParent;

  /// The child index in the parent's flow, set when the parent has auto
  /// layout (the new node is placed by the flow, not by x/y).
  final int? flowIndex;

  bool get inFlow => flowIndex != null;

  /// A world point in the parent's space.
  Offset local(Offset world) => MatrixUtils.transformPoint(toParent, world);
}

/// Finds insert targets on the canvas from the live render tree.
class InsertPlacement {
  InsertPlacement(this.canvas, this.document);

  final CanvasController canvas;
  final ir.StageDocument document;

  /// The deepest frame under [screen] (never inside an instance, never
  /// locked or hidden: the overlay's hit test skips those), the scene root
  /// when the pointer is on bare artboard, or null off every artboard.
  ///
  /// If that frame has auto layout (not grid), the target carries the
  /// insertion index under the pointer.
  InsertTarget? targetAt(Offset screen) {
    final g = canvas.overlay;
    final hits = g.hitTest(screen);
    if (hits.isEmpty) return null;
    final index = ir.DocumentIndex.of(document);
    for (final h in hits) {
      if (h.nodeId.contains('/')) continue;
      final node = index.node(h.nodeId);
      if (node is! ir.FrameNode) continue;
      final toWorld = g.worldTransformFor(h.nodeId, h.breakpointId);
      final inv = toWorld == null ? null : Matrix4.tryInvert(toWorld);
      if (inv == null) continue;
      final world = canvas.camera.value.toWorld(screen);
      return InsertTarget(
        breakpointId: h.breakpointId,
        parentId: h.nodeId,
        toParent: inv,
        flowIndex: node.grid == null && node.autoLayout != null
            ? _flowIndex(h.breakpointId, node, toWorld!, world)
            : null,
      );
    }
    return null;
  }

  /// A target for an explicit [parentId] on [breakpointId] (the frame is
  /// laid out there), or null.
  InsertTarget? targetFor(String parentId, String breakpointId) {
    final toWorld = canvas.overlay.worldTransformFor(parentId, breakpointId);
    final inv = toWorld == null ? null : Matrix4.tryInvert(toWorld);
    if (inv == null) return null;
    return InsertTarget(
      breakpointId: breakpointId,
      parentId: parentId,
      toParent: inv,
    );
  }

  int _flowIndex(String bp, ir.FrameNode frame, Matrix4 toWorld, Offset world) {
    final inv = Matrix4.tryInvert(toWorld);
    final box = canvas.artboards[bp]?.registry[frame.id];
    if (inv == null || box is! RenderStageFrame) return frame.children.length;
    final local = MatrixUtils.transformPoint(inv, world);
    final order = {for (final (i, c) in frame.children.indexed) c.id: i};
    final siblings = <FlowSibling>[];
    box.visitChildren((k) {
      if (k is! RenderStageBox) return;
      final c = k.common;
      if (!c.visible || c.layoutChild.positioning != ir.Positioning.auto) {
        return;
      }
      final i = order[k.nodeId];
      if (i == null) return;
      siblings.add((
        index: i,
        box: (k.parentData! as BoxParentData).offset & k.size,
      ));
    });
    siblings.sort((a, b) => a.index.compareTo(b.index));
    final al = frame.autoLayout!;
    final pad = al.padding;
    final sz = box.size;
    return flowSlot(
      siblings: siblings,
      pointer: local,
      horizontal: al.direction == ir.LayoutDirection.horizontal,
      wrap: al.wrap,
      content: Rect.fromLTRB(
        pad.left,
        pad.top,
        sz.width - pad.right,
        sz.height - pad.bottom,
      ),
      childCount: frame.children.length,
    ).index;
  }

  /// Candidate boxes for snapping a new node inside [parentId] on [bp].
  SnapIndex snapIndex(String bp, String parentId) {
    final g = canvas.overlay;
    final siblings = <Rect>[];
    final parent = canvas.artboards[bp]?.registry[parentId];
    parent?.visitChildren((k) {
      if (k is! RenderStageBox || !k.common.visible) return;
      final r = g.worldRectFor(k.nodeId, bp);
      if (r != null) siblings.add(r);
    });
    return SnapIndex(
      siblings: siblings,
      parent: g.worldRectFor(parentId, bp),
      artboard: canvas.artboards[bp]?.worldRect,
    );
  }
}
