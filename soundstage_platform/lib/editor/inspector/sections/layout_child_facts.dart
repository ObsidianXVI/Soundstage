import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';

// Per-node layout facts of the selection at the edited breakpoint: what the
// auto-layout and layout-child sections need beyond [SelectionInfo] (which
// only counts). Kept here rather than in inspector_providers.dart, which is
// shared.

/// The layout facts of one selected node.
@immutable
class NodeLayoutFacts {
  const NodeLayoutFacts({
    required this.id,
    required this.kind,
    this.hasAutoLayout = false,
    this.hasGrid = false,
    this.parentHasAutoLayout = false,
    this.inFlow = true,
    this.isRoot = false,
    this.isInner = false,
  });

  final String id;

  /// The authored kind (an instance stays an instance).
  final ir.NodeKind kind;

  /// The node is a frame with auto layout (or a grid) at this breakpoint.
  final bool hasAutoLayout;
  final bool hasGrid;

  /// The parent is a frame with auto layout at this breakpoint.
  final bool parentHasAutoLayout;

  /// `layoutChild.positioning == auto` (placed by the parent's flow when the
  /// parent has auto layout).
  final bool inFlow;

  /// A scene root (sized by the breakpoint).
  final bool isRoot;

  /// A node inside an instance (`instance/inner` id).
  final bool isInner;

  bool get isFrame => kind == ir.NodeKind.frame;

  @override
  bool operator ==(Object other) =>
      other is NodeLayoutFacts &&
      other.id == id &&
      other.kind == kind &&
      other.hasAutoLayout == hasAutoLayout &&
      other.hasGrid == hasGrid &&
      other.parentHasAutoLayout == parentHasAutoLayout &&
      other.inFlow == inFlow &&
      other.isRoot == isRoot &&
      other.isInner == isInner;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    hasAutoLayout,
    hasGrid,
    parentHasAutoLayout,
    inFlow,
    isRoot,
    isInner,
  );
}

/// [NodeLayoutFacts] of every selected node, in selection order.
@immutable
class LayoutChildFacts {
  const LayoutChildFacts([this.nodes = const []]);

  final List<NodeLayoutFacts> nodes;

  /// Selected frames (authored kind), with and without auto layout.
  Iterable<NodeLayoutFacts> get frames => nodes.where((n) => n.isFrame);
  List<String> get autoLayoutFrameIds => [
    for (final n in frames)
      if (n.hasAutoLayout) n.id,
  ];
  List<String> get freeFrameIds => [
    for (final n in frames)
      if (!n.hasAutoLayout) n.id,
  ];

  @override
  bool operator ==(Object other) =>
      other is LayoutChildFacts && listEquals(other.nodes, nodes);

  @override
  int get hashCode => Object.hashAll(nodes);
}

/// Computes [LayoutChildFacts] of [selection] from a resolved [index].
LayoutChildFacts layoutFactsOf(
  ir.StageDocument doc,
  Map<String, ir.ResolvedNode> index,
  Iterable<String> selection,
) {
  final docIndex = ir.DocumentIndex.of(doc);
  final out = <NodeLayoutFacts>[];
  for (final id in selection) {
    final rn = index[id];
    if (rn == null) continue;
    final node = rn.node;
    final kind = ir.nodeKindOf(docIndex.node(id) ?? node);
    final frame = kind == ir.NodeKind.frame && node is ir.FrameNode
        ? node
        : null;
    final inFlow = node.common.layoutChild.positioning == ir.Positioning.auto;
    final inner = id.contains('/');
    var root = false, parentAuto = false;
    if (!inner) {
      final loc = docIndex.locate(id);
      if (loc != null && loc.isRoot) {
        root = true;
      } else if (loc != null) {
        final parent = index[loc.parentId!]?.node;
        parentAuto = parent is ir.FrameNode && parent.autoLayout != null;
      }
    } else {
      final parentId = id.substring(0, id.lastIndexOf('/'));
      final parent = index[parentId]?.node;
      parentAuto = parent is ir.FrameNode && parent.autoLayout != null;
    }
    out.add(
      NodeLayoutFacts(
        id: id,
        kind: kind,
        hasAutoLayout: frame?.autoLayout != null,
        hasGrid: frame?.grid != null,
        parentHasAutoLayout: parentAuto,
        inFlow: inFlow,
        isRoot: root,
        isInner: inner,
      ),
    );
  }
  return LayoutChildFacts(out);
}

/// [layoutFactsOf] for the live selection, value-compared.
final layoutChildFactsProvider = Provider.autoDispose<LayoutChildFacts>(
  (ref) {
    final ids = ref.watch(selectionIdsProvider);
    final bp = ref.watch(
      editorControllerProvider.select((s) => s.breakpointId),
    );
    if (ids.isEmpty || bp == null) return const LayoutChildFacts();
    final art = ref.watch(resolvedForProvider(bp));
    return layoutFactsOf(art.document, art.resolved.nodeIndex, ids.ids);
  },
  dependencies: [
    editorControllerProvider,
    resolvedForProvider,
    selectionIdsProvider,
  ],
);

/// Narrows the inspector scope to [ids] (a subset of the selection), so the
/// controls below read and write only those nodes (the auto-layout controls
/// act on the selected frames that have auto layout). The subset's writer
/// shares the editor controller, so scope routing and gestures behave the
/// same.
class SubsetScope extends StatefulWidget {
  const SubsetScope({required this.ids, required this.child, super.key});

  final List<String> ids;
  final Widget child;

  @override
  State<SubsetScope> createState() => _SubsetScopeState();
}

class _SubsetScopeState extends State<SubsetScope> {
  IdList? _ids;
  PropertyWriter? _writer;
  PropertyWriter? _parentWriter;

  @override
  Widget build(BuildContext context) {
    final parent = InspectorScope.of(context);
    final ids = IdList(widget.ids);
    if (ids == parent.selection) return widget.child;
    if (_ids != ids || !identical(_parentWriter, parent.writer)) {
      _ids = ids;
      _parentWriter = parent.writer;
      _writer = PropertyWriter(
        parent.writer.controller,
        parent.writer.readState,
        ids.ids,
      );
    }
    return InspectorScope(
      selection: ids,
      writer: _writer!,
      child: widget.child,
    );
  }
}

/// Whether the next edit through the inspector writes the shared base:
/// the effective scope is Both and Alt (which flips it) is not held.
bool editsShareBase(PropertyWriter w) {
  final s = w.readState();
  final alt = HardwareKeyboard.instance.isAltPressed;
  final scope = alt ? s.editScope.flipped : s.effectiveScope;
  return scope == EditScope.both;
}
