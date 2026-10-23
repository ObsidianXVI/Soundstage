import 'dart:math' as math;

import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';
import 'property_commands.dart';

// Align and distribute (the inspector's alignment row). Both work on the
// design-time geometry as seen at the edited breakpoint (stored x/y/w/h with
// the breakpoint patches applied) and write x/y through [SetProperty], so
// the edit scope routes them like any other geometry edit.
//
// Boxes are the rotated axis-aligned bounds (Figma aligns what you see).
// Ancestors' rotation and flips are ignored: nodes are compared in the
// scene's design space by summing their ancestors' offsets. In-flow
// children of auto-layout and grid parents are skipped (their stored x/y
// place nothing), as are nodes inside instances.

/// Which edge or centre line [AlignNodes] aligns to.
enum AlignEdge {
  left,
  horizontalCenter,
  right,
  top,
  verticalCenter,
  bottom;

  bool get horizontal =>
      this == left || this == horizontalCenter || this == right;

  String get label => switch (this) {
    left => 'Align left',
    horizontalCenter => 'Align horizontal centres',
    right => 'Align right',
    top => 'Align top',
    verticalCenter => 'Align vertical centres',
    bottom => 'Align bottom',
  };
}

/// A node's geometry as seen at the edited breakpoint, in scene design
/// space.
class _Box {
  _Box(
    this.id,
    this.x,
    this.y,
    this.w,
    this.h,
    this.rotation,
    this.ox,
    this.oy,
  );

  final String id;

  /// Stored x/y/w/h (parent space), rotation in degrees.
  final double x, y, w, h, rotation;

  /// The parent's origin in scene space.
  final double ox, oy;

  late final double _cw = w * _cos + h * _sin;
  late final double _ch = w * _sin + h * _cos;
  double get _cos => math.cos(rotation * math.pi / 180).abs();
  double get _sin => math.sin(rotation * math.pi / 180).abs();

  /// Rotated bounds in scene space.
  double get left => ox + x + w / 2 - _cw / 2;
  double get top => oy + y + h / 2 - _ch / 2;
  double get width => _cw;
  double get height => _ch;
  double get right => left + width;
  double get bottom => top + height;
}

class _Gathered {
  _Gathered(this.boxes, this.diagnostics, this.parentSizes);

  final List<_Box> boxes;
  final List<ir.IrDiagnostic> diagnostics;

  /// Parent size in parent space, by node id (single-node alignment).
  final Map<String, ir.StageSize> parentSizes;
}

ir.Node _seen(ir.Node node, List<ir.Breakpoint> chain) {
  var seen = node;
  for (final b in chain) {
    final p = node.common.breakpointOverrides[b.id];
    if (p != null) seen = ir.applyPatch(seen, p);
  }
  return seen;
}

_Gathered _gather(EditorState state, List<String> nodeIds) {
  final doc = state.document;
  final index = ir.DocumentIndex.of(doc);
  final bpId = state.breakpointId;
  final chain = bpId == null
      ? const <ir.Breakpoint>[]
      : ir.breakpointChain(doc.breakpoints, bpId).chain;
  ir.StageSize? design;
  for (final b in doc.breakpoints) {
    if (b.id == bpId) design = b.designSize;
  }
  final boxes = <_Box>[];
  final diags = <ir.IrDiagnostic>[];
  final parentSizes = <String, ir.StageSize>{};
  for (final id in nodeIds) {
    final node = id.contains('/') ? null : index.node(id);
    final loc = node == null ? null : index.locate(id);
    if (node == null || loc == null) {
      diags.add(
        commandWarning(
          '"$id" cannot be aligned (inside an instance).',
          nodeId: id,
        ),
      );
      continue;
    }
    if (loc.isRoot) continue;
    final parent = index.node(loc.parentId!)! as ir.FrameNode;
    if (parent.grid != null ||
        (parent.autoLayout != null &&
            _seen(node, chain).common.layoutChild.positioning ==
                ir.Positioning.auto)) {
      diags.add(
        commandWarning(
          '"${node.common.name.isEmpty ? id : node.common.name}" is placed by '
          'its auto-layout parent.',
          nodeId: id,
        ),
      );
      continue;
    }
    // The parent's origin: its ancestors' offsets (the scene root sits at 0).
    var ox = 0.0, oy = 0.0;
    for (final a in loc.ancestorIds.skip(1)) {
      final c = _seen(index.node(a)!, chain).common;
      ox += c.x;
      oy += c.y;
    }
    final s = _seen(node, chain).common;
    boxes.add(_Box(id, s.x, s.y, s.width, s.height, s.rotation, ox, oy));
    final ps = _seen(parent, chain).common;
    parentSizes[id] = loc.ancestorIds.length == 1 && design != null
        ? design
        : ir.StageSize(width: ps.width, height: ps.height);
  }
  return _Gathered(boxes, diags, parentSizes);
}

CommandResult _write(
  EditorState state,
  String label,
  Map<String, Map<String, ir.IrValue>> writes,
  List<ir.IrDiagnostic> diags,
) {
  final effective = {
    for (final MapEntry(:key, :value) in writes.entries)
      if (value.isNotEmpty) key: value,
  };
  if (effective.isEmpty) {
    return CommandResult(
      document: state.document,
      label: label,
      diagnostics: diags,
    );
  }
  final r = SetProperty.values(effective).apply(state);
  return r.copyWith(
    label: label,
    coalesceKey: null,
    diagnostics: [...diags, ...r.diagnostics],
  );
}

double _snap(double v) => (v * 1e4).roundToDouble() / 1e4;

/// Aligns nodes to [edge]. One node aligns to its parent's bounds; several
/// align to their common bounds (Figma).
class AlignNodes extends EditCommand {
  const AlignNodes(this.nodeIds, this.edge);

  final List<String> nodeIds;
  final AlignEdge edge;

  @override
  String get label => edge.label;

  @override
  CommandResult apply(EditorState state) {
    final g = _gather(state, nodeIds);
    if (g.boxes.isEmpty) {
      return CommandResult(
        document: state.document,
        label: label,
        diagnostics: g.diagnostics,
      );
    }
    // The target line, in scene space.
    final double Function(_Box) pick;
    final double target;
    if (g.boxes.length == 1) {
      final b = g.boxes.single;
      final ps = g.parentSizes[b.id]!;
      target = switch (edge) {
        AlignEdge.left => b.ox,
        AlignEdge.horizontalCenter => b.ox + ps.width / 2,
        AlignEdge.right => b.ox + ps.width,
        AlignEdge.top => b.oy,
        AlignEdge.verticalCenter => b.oy + ps.height / 2,
        AlignEdge.bottom => b.oy + ps.height,
      };
    } else {
      final l = g.boxes.map((b) => b.left).reduce(math.min);
      final r = g.boxes.map((b) => b.right).reduce(math.max);
      final t = g.boxes.map((b) => b.top).reduce(math.min);
      final bo = g.boxes.map((b) => b.bottom).reduce(math.max);
      target = switch (edge) {
        AlignEdge.left => l,
        AlignEdge.horizontalCenter => (l + r) / 2,
        AlignEdge.right => r,
        AlignEdge.top => t,
        AlignEdge.verticalCenter => (t + bo) / 2,
        AlignEdge.bottom => bo,
      };
    }
    pick = switch (edge) {
      AlignEdge.left => (b) => b.left,
      AlignEdge.horizontalCenter => (b) => b.left + b.width / 2,
      AlignEdge.right => (b) => b.right,
      AlignEdge.top => (b) => b.top,
      AlignEdge.verticalCenter => (b) => b.top + b.height / 2,
      AlignEdge.bottom => (b) => b.bottom,
    };
    final writes = <String, Map<String, ir.IrValue>>{};
    for (final b in g.boxes) {
      final d = target - pick(b);
      if (d.abs() < 1e-9) continue;
      writes[b.id] = edge.horizontal
          ? {'x': ir.IrValue.number(_snap(b.x + d))}
          : {'y': ir.IrValue.number(_snap(b.y + d))};
    }
    return _write(state, label, writes, g.diagnostics);
  }
}

/// Distributes at least three nodes so the gaps between their bounds are
/// equal along [horizontal]; the outermost two stay put.
class DistributeNodes extends EditCommand {
  const DistributeNodes(this.nodeIds, {required this.horizontal});

  final List<String> nodeIds;
  final bool horizontal;

  @override
  String get label => horizontal
      ? 'Distribute horizontal spacing'
      : 'Distribute vertical spacing';

  @override
  CommandResult apply(EditorState state) {
    final g = _gather(state, nodeIds);
    if (g.boxes.length < 3) {
      return CommandResult(
        document: state.document,
        label: label,
        diagnostics: [
          ...g.diagnostics,
          commandWarning('Distribute needs at least three layers.'),
        ],
      );
    }
    double start(_Box b) => horizontal ? b.left : b.top;
    double size(_Box b) => horizontal ? b.width : b.height;
    final sorted = [...g.boxes]..sort((a, b) => start(a).compareTo(start(b)));
    final first = start(sorted.first);
    final last = start(sorted.last) + size(sorted.last);
    final total = sorted.fold<double>(0, (s, b) => s + size(b));
    final gap = (last - first - total) / (sorted.length - 1);
    var cursor = first;
    final writes = <String, Map<String, ir.IrValue>>{};
    for (final b in sorted) {
      final d = cursor - start(b);
      if (d.abs() > 1e-9) {
        writes[b.id] = horizontal
            ? {'x': ir.IrValue.number(_snap(b.x + d))}
            : {'y': ir.IrValue.number(_snap(b.y + d))};
      }
      cursor += size(b) + gap;
    }
    return _write(state, label, writes, g.diagnostics);
  }
}
