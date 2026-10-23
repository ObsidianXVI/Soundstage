import 'dart:math' as math;

import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Structural node commands (architecture §15). Each wraps the IR's
// path-copy edit helpers; ids for new nodes come from an injected
// `IdGenerator` (default: one reserved against the document).

ir.IdGenerator _gen(ir.IdGenerator? ids, ir.StageDocument doc) =>
    ids ?? ir.IdGenerator.forDocument(doc);

/// Inserts [nodes] into [parentId] at [index] (null: on top, i.e. last) and
/// selects them.
class InsertNodes extends EditCommand {
  const InsertNodes(this.parentId, this.nodes, {this.index});

  final String parentId;
  final List<ir.Node> nodes;
  final int? index;

  @override
  String get label => 'Insert ${layers(nodes.length)}';

  @override
  CommandResult apply(EditorState state) {
    final parent = ir.DocumentIndex.of(state.document).node(parentId);
    final at = index ?? (parent is ir.FrameNode ? parent.children.length : 0);
    final r = ir.insertNodes(state.document, parentId, at, nodes);
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: r.createdIds.toSet(),
    );
  }
}

/// Deletes nodes and everything that refers to them (see
/// `ir.removeNodes`); the selection becomes empty.
class DeleteNodes extends EditCommand {
  const DeleteNodes(this.nodeIds);

  final List<String> nodeIds;

  @override
  String get label => 'Delete ${layers(nodeIds.length)}';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.removeNodes(state.document, nodeIds),
    label: label,
    selectionAfter: const {},
  );
}

/// Reparents and/or reorders nodes, keeping their visual position by
/// default (see `ir.moveNodes`). [boxes] are the current layout boxes from
/// the canvas, in each scene root's space at the edited breakpoint.
class MoveNodes extends EditCommand {
  const MoveNodes(
    this.nodeIds,
    this.parentId,
    this.index, {
    this.preservePosition = true,
    this.boxes = const {},
    this.ids,
  });

  final List<String> nodeIds;
  final String parentId;
  final int index;
  final bool preservePosition;
  final Map<String, ir.StageRect> boxes;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Move ${layers(nodeIds.length)}';

  @override
  CommandResult apply(EditorState state) {
    final r = ir.moveNodes(
      state.document,
      nodeIds,
      parentId,
      index,
      preservePosition: preservePosition,
      boxes: boxes,
      breakpointId: state.breakpointId,
      idGenerator: ids,
    );
    final loc = ir.DocumentIndex.of(r.document).locate(parentId);
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: nodeIds.toSet(),
      activeSceneAfter: loc?.sceneId,
    );
  }
}

/// Figma's layer-order commands.
enum ReorderDirection {
  /// One step up (Cmd+]).
  forward,

  /// One step down (Cmd+[).
  backward,

  /// To the top of the parent (Cmd+Alt+]).
  front,

  /// To the bottom of the parent (Cmd+Alt+[).
  back,
}

/// Reorders nodes among their siblings (later children paint on top).
/// Nodes of different parents reorder within their own parent.
class ReorderNodes extends EditCommand {
  const ReorderNodes(this.nodeIds, this.direction);

  final List<String> nodeIds;
  final ReorderDirection direction;

  @override
  String get label => switch (direction) {
    ReorderDirection.forward => 'Bring forward',
    ReorderDirection.backward => 'Send backward',
    ReorderDirection.front => 'Bring to front',
    ReorderDirection.back => 'Send to back',
  };

  @override
  CommandResult apply(EditorState state) {
    final index = ir.DocumentIndex.of(state.document);
    final byParent = <String, List<String>>{};
    final diags = <ir.IrDiagnostic>[];
    for (final id in nodeIds) {
      final loc = index.locate(id);
      if (loc == null || loc.isRoot) {
        diags.add(commandWarning('"$id" cannot be reordered.', nodeId: id));
        continue;
      }
      (byParent[loc.parentId!] ??= []).add(id);
    }
    var doc = state.document;
    byParent.forEach((parentId, ids) {
      final kids = [
        for (final c
            in (ir.DocumentIndex.of(doc).node(parentId)! as ir.FrameNode)
                .children)
          c.id,
      ];
      final set = ids.toSet();
      final order = [...kids];
      switch (direction) {
        case ReorderDirection.front:
          order
            ..removeWhere(set.contains)
            ..addAll(kids.where(set.contains));
        case ReorderDirection.back:
          order
            ..removeWhere(set.contains)
            ..insertAll(0, kids.where(set.contains));
        case ReorderDirection.forward:
          for (var i = order.length - 2; i >= 0; i--) {
            if (set.contains(order[i]) && !set.contains(order[i + 1])) {
              final t = order[i];
              order[i] = order[i + 1];
              order[i + 1] = t;
            }
          }
        case ReorderDirection.backward:
          for (var i = 1; i < order.length; i++) {
            if (set.contains(order[i]) && !set.contains(order[i - 1])) {
              final t = order[i];
              order[i] = order[i - 1];
              order[i - 1] = t;
            }
          }
      }
      final r = ir.updateNode(doc, parentId, (n) {
        final f = n as ir.FrameNode;
        final byId = {for (final c in f.children) c.id: c};
        final next = [for (final id in order) byId[id]!];
        return _sameIds(next, f.children) ? f : f.copyWith(children: next);
      });
      if (r.ok) doc = r.document;
      diags.addAll(r.diagnostics);
    });
    return CommandResult(
      document: doc,
      label: label,
      changed: !identical(doc, state.document),
      selectionAfter: nodeIds.toSet(),
      diagnostics: diags,
    );
  }
}

bool _sameIds(List<ir.Node> a, List<ir.Node> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i].id != b[i].id) return false;
  }
  return true;
}

/// Duplicates nodes (Cmd+D) right above each original and selects the
/// copies.
class DuplicateNodes extends EditCommand {
  const DuplicateNodes(this.nodeIds, {this.ids});

  final List<String> nodeIds;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Duplicate ${layers(nodeIds.length)}';

  @override
  CommandResult apply(EditorState state) {
    final r = ir.duplicateNodes(
      state.document,
      nodeIds,
      _gen(ids, state.document),
    );
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: r.createdIds.toSet(),
    );
  }
}

/// Wraps sibling nodes in a new frame that keeps their visual position
/// (Cmd+Alt+G "Frame selection"; Cmd+G "Group" is the same with
/// [group]: the frame is named "Group" and stays transparent). Soundstage
/// has no separate group node.
class WrapInFrame extends EditCommand {
  const WrapInFrame(
    this.nodeIds, {
    this.group = false,
    this.boxes = const {},
    this.ids,
  });

  final List<String> nodeIds;
  final bool group;
  final Map<String, ir.StageRect> boxes;
  final ir.IdGenerator? ids;

  @override
  String get label => group ? 'Group selection' : 'Frame selection';

  @override
  CommandResult apply(EditorState state) {
    final gen = _gen(ids, state.document);
    final r = ir.wrapInFrame(
      state.document,
      nodeIds,
      (bounds) => ir.FrameNode(
        common: ir.NodeCommon(id: gen.next(), name: group ? 'Group' : 'Frame'),
      ),
      boxes: boxes,
    );
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: r.createdIds.toSet(),
    );
  }
}

/// Removes frames, keeping their children in place (Cmd+Shift+G): the
/// children move to the frame's parent at the frame's position in the
/// layer order, keeping their visual position (from [boxes], else their
/// stored geometry; see `ir.moveNodes`), then the frame is deleted along
/// with what refers to it. Selects the released children.
class UnwrapFrame extends EditCommand {
  const UnwrapFrame(this.frameIds, {this.boxes = const {}});

  final List<String> frameIds;
  final Map<String, ir.StageRect> boxes;

  @override
  String get label => 'Ungroup';

  @override
  CommandResult apply(EditorState state) {
    var doc = state.document;
    final diags = <ir.IrDiagnostic>[];
    final released = <String>{};
    var cascade = const ir.EditCascade();
    for (final id in frameIds) {
      final index = ir.DocumentIndex.of(doc);
      final loc = index.locate(id);
      final node = index.node(id);
      if (loc == null || loc.isRoot || node is! ir.FrameNode) {
        diags.add(
          commandError(
            '"$id" is not a frame that can be ungrouped.',
            nodeId: id,
          ),
        );
        continue;
      }
      final kids = [for (final c in node.children) c.id];
      var next = doc;
      if (kids.isNotEmpty) {
        final m = ir.moveNodes(
          next,
          kids,
          loc.parentId!,
          loc.index,
          boxes: boxes,
          breakpointId: state.breakpointId,
        );
        diags.addAll(m.diagnostics);
        if (!m.ok) continue;
        next = m.document;
      }
      final r = ir.removeNodes(next, [id]);
      diags.addAll(r.diagnostics);
      if (!r.ok) continue;
      doc = r.document;
      released.addAll(kids);
      cascade = cascade.copyWith(
        removedTrackIds: [
          ...cascade.removedTrackIds,
          ...r.cascade.removedTrackIds,
        ],
        removedClockIds: [
          ...cascade.removedClockIds,
          ...r.cascade.removedClockIds,
        ],
        removedActions: [
          ...cascade.removedActions,
          ...r.cascade.removedActions,
        ],
        removedInteractions: [
          ...cascade.removedInteractions,
          ...r.cascade.removedInteractions,
        ],
      );
    }
    final ok = released.isNotEmpty || frameIds.isEmpty;
    return CommandResult(
      document: ok ? doc : state.document,
      label: label,
      changed: ok && !identical(doc, state.document),
      selectionAfter: ok ? released : null,
      diagnostics: ok ? [for (final d in diags) asWarning(d)] : diags,
      cascade: cascade,
    );
  }
}

/// An auto-layout setting inferred from children's boxes (Figma Shift+A),
/// and the children in their new flow order.
typedef InferredAutoLayout = ({ir.AutoLayout layout, List<String> order});

/// Infers auto layout from child [boxes] (relative to the frame, in the
/// given order): the direction along which the children spread most, the
/// average gap between neighbours (rounded, at least 0), the counter-axis
/// alignment their edges share, and, when [frame] is given, the padding
/// from the frame's edges to the children (rounded, at least 0).
InferredAutoLayout inferAutoLayout(
  List<(String, ir.StageRect)> boxes, {
  ir.StageSize? frame,
}) {
  if (boxes.isEmpty) {
    return (layout: const ir.AutoLayout(), order: const <String>[]);
  }
  double cx(ir.StageRect r) => r.x + r.width / 2;
  double cy(ir.StageRect r) => r.y + r.height / 2;
  final xs = boxes.map((b) => cx(b.$2)), ys = boxes.map((b) => cy(b.$2));
  final spanX = xs.reduce(math.max) - xs.reduce(math.min);
  final spanY = ys.reduce(math.max) - ys.reduce(math.min);
  final horizontal = spanX >= spanY;
  double start(ir.StageRect r) => horizontal ? r.x : r.y;
  double end(ir.StageRect r) => horizontal ? r.x + r.width : r.y + r.height;
  double cStart(ir.StageRect r) => horizontal ? r.y : r.x;
  double cEnd(ir.StageRect r) => horizontal ? r.y + r.height : r.x + r.width;

  final sorted = [...boxes]
    ..sort((a, b) {
      final c = start(a.$2).compareTo(start(b.$2));
      return c != 0 ? c : cStart(a.$2).compareTo(cStart(b.$2));
    });
  var gap = 0.0;
  if (sorted.length > 1) {
    var sum = 0.0;
    for (var i = 1; i < sorted.length; i++) {
      sum += start(sorted[i].$2) - end(sorted[i - 1].$2);
    }
    gap = math.max(0, (sum / (sorted.length - 1)).roundToDouble());
  }
  bool same(double Function(ir.StageRect) f) {
    final v = sorted.map((b) => f(b.$2));
    return v.reduce(math.max) - v.reduce(math.min) <= 0.5;
  }

  final counter = same(cStart)
      ? ir.CounterAlign.start
      : same((r) => (cStart(r) + cEnd(r)) / 2)
      ? ir.CounterAlign.center
      : same(cEnd)
      ? ir.CounterAlign.end
      : ir.CounterAlign.start;
  var padding = ir.EdgeInsetsValue.zero;
  if (frame != null) {
    double minOf(double Function(ir.StageRect) f) =>
        sorted.map((b) => f(b.$2)).reduce(math.min);
    double maxOf(double Function(ir.StageRect) f) =>
        sorted.map((b) => f(b.$2)).reduce(math.max);
    double clean(double v) => math.max(0, v.roundToDouble());
    padding = ir.EdgeInsetsValue(
      left: clean(minOf((r) => r.x)),
      top: clean(minOf((r) => r.y)),
      right: clean(frame.width - maxOf((r) => r.x + r.width)),
      bottom: clean(frame.height - maxOf((r) => r.y + r.height)),
    );
  }
  return (
    layout: ir.AutoLayout(
      direction: horizontal
          ? ir.LayoutDirection.horizontal
          : ir.LayoutDirection.vertical,
      gap: ir.Gap.fixed(gap),
      padding: padding,
      counterAlign: counter,
    ),
    order: [for (final b in sorted) b.$1],
  );
}

/// Figma's "Add auto layout" (Shift+A).
///
/// One frame without auto layout gets auto layout, with direction, gap,
/// padding and counter alignment inferred from its children's boxes
/// ([boxes] relative to the frame, else stored geometry); its children are
/// reordered to the inferred flow and its size is kept. Anything else (several
/// nodes, a non-frame, or a frame that already has auto layout) is wrapped
/// in a new auto-layout frame that hugs its content, with the gap and
/// alignment inferred from the nodes' boxes ([boxes] in the parent's space,
/// else stored geometry). Selects the frame.
class AddAutoLayout extends EditCommand {
  const AddAutoLayout(this.nodeIds, {this.boxes = const {}, this.ids});

  final List<String> nodeIds;
  final Map<String, ir.StageRect> boxes;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Add auto layout';

  ir.StageRect _box(ir.Node n) =>
      boxes[n.id] ??
      ir.StageRect(
        x: n.common.x,
        y: n.common.y,
        width: n.common.width,
        height: n.common.height,
      );

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final index = ir.DocumentIndex.of(doc);
    if (nodeIds.length == 1) {
      final n = index.node(nodeIds.single);
      if (n is ir.FrameNode && n.autoLayout == null && n.grid == null) {
        final flow = [
          for (final c in n.children)
            if (c.common.layoutChild.positioning == ir.Positioning.auto) c,
        ];
        final inferred = inferAutoLayout([
          for (final c in flow) (c.id, _box(c)),
        ], frame: ir.StageSize(width: n.common.width, height: n.common.height));
        final r = ir.updateNode(doc, n.id, (node) {
          final f = node as ir.FrameNode;
          final byId = {for (final c in f.children) c.id: c};
          final ordered = [for (final id in inferred.order) byId[id]!];
          var k = 0;
          // In-flow children take the inferred order; absolute ones keep
          // their slots.
          final kids = [
            for (final c in f.children)
              c.common.layoutChild.positioning == ir.Positioning.auto
                  ? ordered[k++]
                  : c,
          ];
          return f.copyWith(autoLayout: inferred.layout, children: kids);
        });
        return resultOf(state, r, label: label, selectionAfter: {n.id});
      }
    }
    final gen = _gen(ids, doc);
    late InferredAutoLayout inferred;
    final nodes = [for (final id in nodeIds) ?index.node(id)];
    final r = ir.wrapInFrame(doc, nodeIds, (bounds) {
      inferred = inferAutoLayout([
        for (final n in nodes)
          (
            n.id,
            _box(n).copyWith(x: _box(n).x - bounds.x, y: _box(n).y - bounds.y),
          ),
      ]);
      return ir.FrameNode(
        common: ir.NodeCommon(
          id: gen.next(),
          name: 'Frame',
          layoutChild: const ir.LayoutChild(
            horizontalSizing: ir.Sizing.hug,
            verticalSizing: ir.Sizing.hug,
          ),
        ),
        autoLayout: inferred.layout,
      );
    }, boxes: boxes);
    if (!r.ok) return resultOf(state, r, label: label);
    final frameId = r.createdIds.single;
    final ordered = ir.updateNode(r.document, frameId, (node) {
      final f = node as ir.FrameNode;
      final byId = {for (final c in f.children) c.id: c};
      return f.copyWith(children: [for (final id in inferred.order) byId[id]!]);
    });
    return resultOf(
      state,
      ordered.copyWith(diagnostics: [...r.diagnostics, ...ordered.diagnostics]),
      label: label,
      selectionAfter: {frameId},
    );
  }
}

/// Removes auto layout from frames, keeping their children where they are:
/// in-flow children get their laid-out box ([boxes], relative to the frame;
/// else a fixed-size estimate of the flow) as stored geometry. A hugging
/// frame becomes fixed at its current size ([boxes][frameId] if given).
/// Auto-layout patches on every breakpoint are cleared with it.
class RemoveAutoLayout extends EditCommand {
  const RemoveAutoLayout(this.frameIds, {this.boxes = const {}});

  final List<String> frameIds;
  final Map<String, ir.StageRect> boxes;

  @override
  String get label => 'Remove auto layout';

  @override
  CommandResult apply(EditorState state) {
    final r = perNode(state.document, frameIds, (doc, id) {
      final n = ir.DocumentIndex.of(doc).node(id);
      if (n is! ir.FrameNode || n.autoLayout == null) {
        return ir.EditResult(
          document: doc,
          changed: false,
          diagnostics: [commandError('"$id" has no auto layout.', nodeId: id)],
        );
      }
      final estimate = _estimateFlow(n);
      final cleared = ir.setPropertyAcrossBreakpoints(
        doc,
        id,
        'autoLayout',
        const ir.IrValue.boolean(false),
        clearPatchesOn: {for (final b in doc.breakpoints) b.id},
      );
      if (!cleared.ok) return cleared;
      return ir.updateNode(cleared.document, id, (node) {
        final f = node as ir.FrameNode;
        final own = boxes[id];
        final lc = f.common.layoutChild;
        return f.copyWith(
          common: f.common.copyWith(
            width: own?.width ?? f.common.width,
            height: own?.height ?? f.common.height,
            layoutChild: lc.copyWith(
              horizontalSizing: lc.horizontalSizing == ir.Sizing.hug
                  ? ir.Sizing.fixed
                  : lc.horizontalSizing,
              verticalSizing: lc.verticalSizing == ir.Sizing.hug
                  ? ir.Sizing.fixed
                  : lc.verticalSizing,
            ),
          ),
          children: [
            for (final c in f.children)
              if (boxes[c.id] ?? estimate[c.id] case final b?)
                c.copyWith(
                  common: c.common.copyWith(
                    x: b.x,
                    y: b.y,
                    width: b.width,
                    height: b.height,
                  ),
                )
              else
                c,
          ],
        );
      });
    });
    return resultOf(state, r, label: label);
  }

  /// In-flow children placed as a fixed-size flow (no fill, hug or wrap).
  static Map<String, ir.StageRect> _estimateFlow(ir.FrameNode f) {
    final al = f.autoLayout!;
    final horizontal = al.direction == ir.LayoutDirection.horizontal;
    final gap = switch (al.gap) {
      ir.FixedGap(:final value) => value,
      _ => 0.0,
    };
    final pad = al.padding;
    var pos = horizontal ? pad.left : pad.top;
    final out = <String, ir.StageRect>{};
    final contentCounter = horizontal
        ? f.common.height - pad.top - pad.bottom
        : f.common.width - pad.left - pad.right;
    for (final c in f.children) {
      final cc = c.common;
      if (!cc.visible || cc.layoutChild.positioning != ir.Positioning.auto) {
        continue;
      }
      final size = horizontal ? cc.width : cc.height;
      final cross = horizontal ? cc.height : cc.width;
      final crossStart = horizontal ? pad.top : pad.left;
      final offset = switch (al.counterAlign) {
        ir.CounterAlign.center => (contentCounter - cross) / 2,
        ir.CounterAlign.end => contentCounter - cross,
        _ => 0.0,
      };
      out[c.id] = horizontal
          ? ir.StageRect(
              x: pos,
              y: crossStart + offset,
              width: cc.width,
              height: cc.height,
            )
          : ir.StageRect(
              x: crossStart + offset,
              y: pos,
              width: cc.width,
              height: cc.height,
            );
      pos += size + gap;
    }
    return out;
  }
}
