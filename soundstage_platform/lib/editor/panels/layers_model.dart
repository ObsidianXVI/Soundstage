import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

// The pure parts of the Layers panel: the flattened row list, kind icons,
// role badges, and drop planning for drag-and-drop. No widgets here, so each
// is unit-testable.

/// Which tree nodes are expanded in the Layers panel, by node id.
///
/// Lives in the provider scope, so expansion is remembered across tab
/// switches and scene changes for the session.
final layersExpansionProvider = NotifierProvider<LayersExpansion, Set<String>>(
  LayersExpansion.new,
);

class LayersExpansion extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void set(String id, bool expanded) {
    if (state.contains(id) == expanded) return;
    state = expanded ? {...state, id} : ({...state}..remove(id));
  }

  void toggle(String id) => set(id, !state.contains(id));

  /// Expands every id of [ids] (a new set only when something changes).
  void expandAll(Iterable<String> ids) {
    final missing = ids.where((id) => !state.contains(id)).toList();
    if (missing.isNotEmpty) state = {...state, ...missing};
  }
}

/// One visible row of the Layers tree.
@immutable
class LayerRow {
  const LayerRow({
    required this.node,
    required this.parentId,
    required this.depth,
    required this.indexInParent,
    required this.siblingCount,
    required this.expanded,
    required this.readOnly,
    required this.dimmed,
  });

  final ir.ResolvedNode node;

  /// The parent's id (the scene root's id for top-level rows).
  final String parentId;

  /// 0 for children of the scene root.
  final int depth;

  /// The position in the parent's children (paint order: later is on top).
  final int indexInParent;
  final int siblingCount;
  final bool expanded;

  /// Inside an instance: shown, selectable, not editable here.
  final bool readOnly;

  /// Hidden or locked, itself or through an ancestor.
  final bool dimmed;

  String get id => node.id;
  bool get hasChildren => node.children.isNotEmpty;

  /// An instance's root (the resolved tree shows it as its component's
  /// root frame, under the instance's own id).
  bool get isInstance => node.instanceId == node.id;

  /// Whether dropping into this row makes sense: an authored frame, not an
  /// instance.
  bool get canContain => !readOnly && !isInstance && node.node is ir.FrameNode;
}

/// The visible rows of [root]'s subtree (the root itself is not a row),
/// topmost layer first, descending into the ids of [expanded].
List<LayerRow> flattenLayers(ir.ResolvedNode root, Set<String> expanded) {
  final out = <LayerRow>[];
  void walk(ir.ResolvedNode parent, int depth, bool readOnly, bool dimmed) {
    final kids = parent.children;
    for (var i = kids.length - 1; i >= 0; i--) {
      final n = kids[i];
      final common = n.node.common;
      final ro = readOnly || n.id.contains('/');
      final dim = dimmed || !common.visible || common.locked;
      final open = n.children.isNotEmpty && expanded.contains(n.id);
      out.add(
        LayerRow(
          node: n,
          parentId: parent.id,
          depth: depth,
          indexInParent: i,
          siblingCount: kids.length,
          expanded: open,
          readOnly: ro,
          dimmed: dim,
        ),
      );
      if (open) walk(n, depth + 1, ro, dim);
    }
  }

  walk(root, 0, false, false);
  return out;
}

/// The row label: the node's name, else a name for its kind.
String layerName(ir.Node node, {bool instance = false}) {
  final name = node.common.name.trim();
  if (name.isNotEmpty) return name;
  if (instance) return 'Instance';
  return switch (node) {
    ir.FrameNode() => 'Frame',
    ir.TextNode(:final content) => _textPreview(content) ?? 'Text',
    ir.ShapeNode(:final geometry) => switch (geometry) {
      ir.RectangleGeometry() => 'Rectangle',
      ir.EllipseGeometry() => 'Ellipse',
      ir.LineGeometry() => 'Line',
      ir.PolygonGeometry() => 'Polygon',
      ir.StarGeometry() => 'Star',
    },
    ir.InstanceNode() => 'Instance',
    ir.VideoNode() => 'Video',
    ir.EmbedNode() => 'Embed',
  };
}

String? _textPreview(List<ir.Paragraph> content) {
  final buf = StringBuffer();
  for (final p in content) {
    for (final s in p.spans) {
      buf.write(s.text);
    }
    if (buf.isNotEmpty) break;
  }
  final t = buf.toString().trim();
  if (t.isEmpty) return null;
  return t.length > 40 ? '${t.substring(0, 40)}…' : t;
}

/// The kind icon of a layer: frame (with its auto-layout direction), text,
/// shape, instance, video.
IconData layerIcon(ir.Node node, {bool instance = false}) => instance
    ? SsIcons.component
    : switch (node) {
        ir.FrameNode(:final autoLayout, :final grid) =>
          autoLayout != null
              ? (autoLayout.direction == ir.LayoutDirection.horizontal
                    ? SsIcons.arrowRight
                    : SsIcons.arrowDown)
              : (grid != null ? SsIcons.layoutTemplate : SsIcons.frame),
        ir.TextNode() => SsIcons.type,
        ir.ShapeNode(:final geometry) =>
          geometry is ir.EllipseGeometry ? SsIcons.circle : SsIcons.square,
        ir.InstanceNode() => SsIcons.component,
        ir.VideoNode() => SsIcons.film,
        ir.EmbedNode() => SsIcons.play,
      };

/// The kind of layer, spoken (icon semantics).
String layerKindName(ir.Node node, {bool instance = false}) => instance
    ? 'Instance'
    : switch (node) {
        ir.FrameNode(:final autoLayout, :final grid) =>
          autoLayout != null
              ? (autoLayout.direction == ir.LayoutDirection.horizontal
                    ? 'Horizontal auto layout'
                    : 'Vertical auto layout')
              : (grid != null ? 'Grid frame' : 'Frame'),
        ir.TextNode() => 'Text',
        ir.ShapeNode() => 'Shape',
        ir.InstanceNode() => 'Instance',
        ir.VideoNode() => 'Video',
        ir.EmbedNode() => 'Embed',
      };

/// The short badge of a role ("H1", "¶"), null for none.
String? roleBadge(ir.NodeRole role) => switch (role) {
  ir.NodeRole.none => null,
  ir.NodeRole.heading1 => 'H1',
  ir.NodeRole.heading2 => 'H2',
  ir.NodeRole.heading3 => 'H3',
  ir.NodeRole.heading4 => 'H4',
  ir.NodeRole.heading5 => 'H5',
  ir.NodeRole.heading6 => 'H6',
  ir.NodeRole.paragraph => '¶',
  ir.NodeRole.quote => '“”',
  ir.NodeRole.caption => 'Cap',
  ir.NodeRole.figure => 'Fig',
  ir.NodeRole.decorative => 'Deco',
};

/// The role, spoken.
String roleName(ir.NodeRole role) => switch (role) {
  ir.NodeRole.none => 'No role',
  ir.NodeRole.heading1 => 'Heading 1',
  ir.NodeRole.heading2 => 'Heading 2',
  ir.NodeRole.heading3 => 'Heading 3',
  ir.NodeRole.heading4 => 'Heading 4',
  ir.NodeRole.heading5 => 'Heading 5',
  ir.NodeRole.heading6 => 'Heading 6',
  ir.NodeRole.paragraph => 'Paragraph',
  ir.NodeRole.quote => 'Quote',
  ir.NodeRole.caption => 'Caption',
  ir.NodeRole.figure => 'Figure',
  ir.NodeRole.decorative => 'Decorative',
};

/// Where a drag would land.
@immutable
class LayerDropPlan {
  const LayerDropPlan({
    required this.parentId,
    required this.index,
    required this.valid,
    this.lineAtRow,
    this.lineDepth = 0,
    this.insideRow,
  });

  /// The new parent and the child index (paint order) to move into.
  final String parentId;
  final int index;

  /// False when the drop would be refused (into itself or a descendant, or
  /// into read-only content).
  final bool valid;

  /// A between-rows drop: the line is drawn at the top edge of the row
  /// with this index in the visible list ([rows.length] for the bottom
  /// edge), indented by [lineDepth].
  final int? lineAtRow;
  final int lineDepth;

  /// An into-a-frame drop: the visible row index to outline.
  final int? insideRow;

  @override
  bool operator ==(Object other) =>
      other is LayerDropPlan &&
      other.parentId == parentId &&
      other.index == index &&
      other.valid == valid &&
      other.lineAtRow == lineAtRow &&
      other.lineDepth == lineDepth &&
      other.insideRow == insideRow;

  @override
  int get hashCode =>
      Object.hash(parentId, index, valid, lineAtRow, lineDepth, insideRow);
}

/// Plans a drop of [dragged] at the pointer's row position [rowPos] (the
/// pointer's y in row units: 2.5 is the middle of the third row).
///
/// The top and bottom quarter of a frame row (half of any other row) drop
/// between rows, as a sibling above or below; the middle drops into the
/// frame, on top. The bottom of an expanded frame drops into it, since its
/// first child is next. Returns null when there are no rows.
///
/// A drop is invalid into a dragged node or its descendants, or into
/// read-only content (an instance's inside).
LayerDropPlan? planLayerDrop({
  required List<LayerRow> rows,
  required String rootId,
  required double rowPos,
  required Set<String> dragged,
}) {
  if (rows.isEmpty) return null;
  final pos = rowPos.clamp(0.0, rows.length - 0.001);
  final i = pos.floor();
  final f = pos - i;
  final r = rows[i];
  final byId = {for (final row in rows) row.id: row};

  bool validParent(String parentId) {
    if (parentId.contains('/')) return false;
    String? p = parentId;
    while (p != null) {
      if (dragged.contains(p)) return false;
      p = byId[p]?.parentId;
    }
    if (parentId != rootId) {
      final row = byId[parentId];
      if (row == null || !row.canContain) return false;
    }
    return true;
  }

  LayerDropPlan inside() => LayerDropPlan(
    parentId: r.id,
    index: r.node.children.length,
    valid: validParent(r.id),
    insideRow: i,
  );
  LayerDropPlan above() => LayerDropPlan(
    parentId: r.parentId,
    index: r.indexInParent + 1,
    valid: validParent(r.parentId),
    lineAtRow: i,
    lineDepth: r.depth,
  );
  LayerDropPlan below() {
    if (r.canContain && r.expanded && r.hasChildren) {
      return LayerDropPlan(
        parentId: r.id,
        index: r.node.children.length,
        valid: validParent(r.id),
        lineAtRow: i + 1,
        lineDepth: r.depth + 1,
      );
    }
    return LayerDropPlan(
      parentId: r.parentId,
      index: r.indexInParent,
      valid: validParent(r.parentId),
      lineAtRow: i + 1,
      lineDepth: r.depth,
    );
  }

  if (r.canContain) {
    if (f < 0.25) return above();
    if (f > 0.75) return below();
    return inside();
  }
  return f < 0.5 ? above() : below();
}
