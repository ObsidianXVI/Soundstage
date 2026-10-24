import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Property writes (architecture §15 "SetProperty routing") and resets.

/// Where a property write for one node goes.
enum WriteTarget {
  /// An override on the enclosing authored instance (`overrides[innerPath]`).
  instanceOverride,

  /// The shared base, clearing the path on the primary breakpoints.
  base,

  /// A patch on the edited breakpoint.
  breakpointPatch,
}

/// The routing decision for writing to [nodeId] in [state] (§15):
///
/// 1. (M2) auto-key on and the property animatable → a keyframe at the
///    playhead. Not built in M1: writes route as below.
/// 2. Inside an instance (`<instanceId>/<innerPath>`) → instance override.
/// 3. Else by the effective edit scope: *Both* → base, *This breakpoint* →
///    a patch on the edited artboard's breakpoint.
WriteTarget routeFor(EditorState state, String nodeId) {
  if (nodeId.contains('/')) return WriteTarget.instanceOverride;
  return state.effectiveScope == EditScope.both
      ? WriteTarget.base
      : WriteTarget.breakpointPatch;
}

/// Writes [value] at [path] on [nodeId] as routed by [routeFor].
ir.EditResult writeProperty(
  EditorState state,
  ir.StageDocument doc,
  String nodeId,
  String path,
  ir.IrValue value, {
  ir.PropertyRegistry? registry,
}) {
  final reg = registry ?? ir.PropertyRegistry.standard;
  // ---- M2: auto-key ------------------------------------------------------
  // if (state.autoKey && (reg.lookup(path)?.descriptor.animatable ?? false))
  //   → write a keyframe at `state.playhead` on the node's track for `path`
  //     (AddKeyframe, §15.1). Until the timeline lands, writes fall through
  //     to the routing below.
  // ------------------------------------------------------------------------
  if (reg.lookup(path) == null) {
    return ir.EditResult(
      document: doc,
      changed: false,
      diagnostics: [
        ir.IrDiagnostic(
          ir.IrDiagnosticKind.unknownPath,
          'No property is registered at "$path".',
          nodeId: nodeId,
          path: path,
        ),
      ],
    );
  }
  if (_isNoOp(state, doc, nodeId, path, value, reg)) {
    return ir.EditResult(document: doc, changed: false);
  }
  switch (routeFor(state, nodeId)) {
    case WriteTarget.instanceOverride:
      final slash = nodeId.indexOf('/');
      return setInstanceOverride(
        doc,
        nodeId.substring(0, slash),
        nodeId.substring(slash + 1),
        path,
        value,
      );
    case WriteTarget.base:
      return ir.setPropertyAcrossBreakpoints(
        doc,
        nodeId,
        path,
        value,
        clearPatchesOn: {for (final b in doc.primaryBreakpoints) b.id},
        registry: reg,
      );
    case WriteTarget.breakpointPatch:
      final bp = state.breakpointId;
      if (bp == null) {
        return ir.EditResult(
          document: doc,
          changed: false,
          diagnostics: [
            ir.IrDiagnostic(
              ir.IrDiagnosticKind.missingBreakpoint,
              'The document has no breakpoint to write a patch to.',
              nodeId: nodeId,
              path: path,
            ),
          ],
        );
      }
      return ir.setBreakpointPatchValue(
        doc,
        nodeId,
        bp,
        path,
        value,
        registry: reg,
      );
  }
}

/// Whether writing [value] would leave [nodeId] as it is (so equal-value
/// writes, e.g. a drag that returns to its start, record nothing).
bool _isNoOp(
  EditorState state,
  ir.StageDocument doc,
  String nodeId,
  String path,
  ir.IrValue value,
  ir.PropertyRegistry reg,
) {
  bool overlaps(String k) => k == path || k.startsWith('$path.');
  final index = ir.DocumentIndex.of(doc);
  switch (routeFor(state, nodeId)) {
    case WriteTarget.instanceOverride:
      final slash = nodeId.indexOf('/');
      final inst = index.node(nodeId.substring(0, slash));
      if (inst is! ir.InstanceNode) return false;
      final patch = inst.overrides[nodeId.substring(slash + 1)];
      return patch != null && patch[path] == value;
    case WriteTarget.base:
      final n = index.node(nodeId);
      if (n == null || value is ir.TokenRefValue) return false;
      if (n.common.bindings.keys.any(overlaps)) return false;
      for (final b in doc.primaryBreakpoints) {
        final p = n.common.breakpointOverrides[b.id];
        if (p != null &&
            p.keys.any((k) => overlaps(k) || path.startsWith('$k.'))) {
          return false;
        }
      }
      return reg.get(n, path) == value;
    case WriteTarget.breakpointPatch:
      final bp = state.breakpointId;
      final n = index.node(nodeId);
      if (bp == null || n == null) return false;
      final patch = n.common.breakpointOverrides[bp];
      return patch != null &&
          patch[path] == value &&
          !patch.keys.any(
            (k) =>
                (k != path && k.startsWith('$path.')) || path.startsWith('$k.'),
          );
  }
}

/// Sets `overrides[innerPath][path] = value` on authored instance
/// [instanceId] (keys under [path] in that override are dropped, as they
/// would be overwritten). Instance overrides apply at every breakpoint.
ir.EditResult setInstanceOverride(
  ir.StageDocument doc,
  String instanceId,
  String innerPath,
  String path,
  ir.IrValue value,
) {
  final node = ir.DocumentIndex.of(doc).node(instanceId);
  if (node != null && node is! ir.InstanceNode) {
    return ir.EditResult(
      document: doc,
      changed: false,
      diagnostics: [
        commandError(
          '"$instanceId" is not an instance.',
          nodeId: '$instanceId/$innerPath',
        ),
      ],
    );
  }
  return ir.updateNode(doc, instanceId, (n) {
    final inst = n as ir.InstanceNode;
    final overrides = {...inst.overrides};
    overrides[innerPath] = {
      for (final MapEntry(:key, :value)
          in (overrides[innerPath] ?? const <String, ir.IrValue>{}).entries)
        if (key != path && !key.startsWith('$path.')) key: value,
      path: value,
    };
    return inst.copyWith(overrides: overrides);
  });
}

/// Removes [keys] from `overrides[innerPath]` on instance [instanceId].
ir.EditResult clearInstanceOverride(
  ir.StageDocument doc,
  String instanceId,
  String innerPath,
  Iterable<String> keys,
) => ir.updateNode(doc, instanceId, (n) {
  if (n is! ir.InstanceNode) return n;
  final patch = n.overrides[innerPath];
  if (patch == null || !keys.any(patch.containsKey)) return n;
  final next = {...patch}..removeWhere((k, _) => keys.contains(k));
  final overrides = {...n.overrides};
  if (next.isEmpty) {
    overrides.remove(innerPath);
  } else {
    overrides[innerPath] = next;
  }
  return n.copyWith(overrides: overrides);
});

/// Sets properties on nodes, routed per §15 (see [writeProperty]).
///
/// `SetProperty(ids, path, value)` writes one value to every node (the
/// inspector); `SetProperty.values({id: {path: value}})` writes per-node
/// values (a drag that moves several nodes, a nudge). Multi-selection
/// applies per node; nodes where the property doesn't apply are skipped
/// with a warning.
class SetProperty extends EditCommand {
  SetProperty(Iterable<String> nodeIds, String path, ir.IrValue value)
    : writes = {
        for (final id in nodeIds) id: {path: value},
      };

  SetProperty.values(this.writes);

  /// Node id → (path → value), applied in order.
  final Map<String, Map<String, ir.IrValue>> writes;

  Iterable<String> get paths => {for (final w in writes.values) ...w.keys};

  @override
  String get label {
    final p = paths.toList();
    return p.length == 1 ? 'Change ${p.single}' : 'Change properties';
  }

  @override
  String get coalesceKey =>
      'set:${(writes.keys.toList()..sort()).join(',')}:'
      '${(paths.toList()..sort()).join(',')}';

  @override
  CommandResult apply(EditorState state) {
    final r = perNode(state.document, writes.keys, (doc, id) {
      var current = doc;
      final diags = <ir.IrDiagnostic>[];
      var changed = false;
      for (final MapEntry(key: path, :value) in writes[id]!.entries) {
        final w = writeProperty(state, current, id, path, value);
        if (!w.ok) return w.copyWith(document: doc, changed: false);
        current = w.document;
        changed |= w.changed;
        diags.addAll(w.diagnostics);
      }
      return ir.EditResult(
        document: current,
        changed: changed,
        diagnostics: diags,
      );
    });
    return resultOf(state, r, label: label, coalesceKey: coalesceKey);
  }
}

/// Resets a property to what it inherits: removes the layer that supplies
/// its value in the current scope, found with `Resolver.explain` at the
/// edited breakpoint.
///
/// From the top layer down, derived layers (tokens, styles, the document
/// default, paragraph styles) are passed over, and the first layer that is
/// not derived decides:
///
/// - an override on an authored instance → its keys are removed;
/// - a breakpoint patch on an authored node → *This breakpoint* removes it
///   only when it is the edited breakpoint's own patch (an inherited
///   `inheritsFrom` patch is not this breakpoint's to reset); *Both* removes
///   the keys from the primary breakpoints' patches and the edited
///   breakpoint's;
/// - anything else (the base value, a component default or binding, an
///   instance placement) is the node's own value: nothing to reset.
///
/// [resolver] defaults to a fresh one; pass the long-lived resolver of the
/// edited breakpoint so `explain` reuses its memo.
class ResetProperty extends EditCommand {
  const ResetProperty(this.nodeIds, this.path, {this.resolver});

  final List<String> nodeIds;
  final String path;
  final ir.Resolver? resolver;

  @override
  String get label => 'Reset $path';

  @override
  CommandResult apply(EditorState state) {
    final resolver = this.resolver ?? ir.Resolver();
    final bp = state.breakpointId;
    final ctx = ir.ResolveContext(breakpointId: bp);
    final scope = state.effectiveScope;
    final r = perNode(state.document, nodeIds, (doc, id) {
      final p = resolver.explain(doc, id, ir.PropertyPath(path), ctx);
      if (p.entries.isEmpty) {
        return ir.EditResult(
          document: doc,
          changed: false,
          diagnostics: p.diagnostics.isEmpty
              ? [commandError('"$path" has no value on "$id".', nodeId: id)]
              : p.diagnostics,
        );
      }
      final index = ir.DocumentIndex.of(doc);
      for (final e in p.entries.reversed) {
        switch (e.source) {
          case ir.TokenSource() ||
              ir.PaintStyleSource() ||
              ir.EffectStyleSource() ||
              ir.TextStyleSource() ||
              ir.DocumentDefaultSource() ||
              ir.ParagraphStyleSource() ||
              ir.AnimatedSource():
            continue;
          case ir.InstanceOverrideSource(:final instanceId, :final innerPath)
              when index.contains(instanceId):
            return clearInstanceOverride(doc, instanceId, innerPath, e.keys);
          case ir.BreakpointPatchSource(:final breakpointId)
              when index.contains(e.nodeId):
            final targets = scope == EditScope.both
                ? {...state.primaryBreakpointIds, ?bp}
                : {if (breakpointId == bp) breakpointId};
            if (targets.isEmpty) return _nothing(doc, id);
            var current = doc;
            for (final t in targets) {
              for (final k in e.keys) {
                final c = ir.clearBreakpointPatchValue(current, e.nodeId, t, k);
                if (c.ok) current = c.document;
              }
            }
            return ir.EditResult(
              document: current,
              changed: !identical(current, doc),
            );
          default:
            return _nothing(doc, id);
        }
      }
      return _nothing(doc, id);
    });
    return resultOf(state, r, label: label);
  }

  ir.EditResult _nothing(ir.StageDocument doc, String id) => ir.EditResult(
    document: doc,
    changed: false,
    diagnostics: [
      commandWarning(
        '"$path" on "$id" has nothing to reset in this scope.',
        nodeId: id,
        path: path,
      ),
    ],
  );
}

/// Shows or hides nodes. `visible` is patchable, so this routes like any
/// property (hide on mobile only with *This breakpoint*).
class SetVisible extends SetProperty {
  SetVisible(Iterable<String> nodeIds, bool visible)
    : super(nodeIds, 'visible', ir.IrValue.boolean(visible));

  @override
  String get label =>
      writes.values.first['visible'] == const ir.IrValue.boolean(true)
      ? 'Show ${layers(writes.length)}'
      : 'Hide ${layers(writes.length)}';
}

/// Locks or unlocks nodes (editor-only; written to the base).
class SetLocked extends EditCommand {
  const SetLocked(this.nodeIds, this.locked);

  final List<String> nodeIds;
  final bool locked;

  @override
  String get label => '${locked ? 'Lock' : 'Unlock'} ${layers(nodeIds.length)}';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    perNode(
      state.document,
      nodeIds,
      (doc, id) => ir.updateNode(
        doc,
        id,
        (n) => n.common.locked == locked
            ? n
            : n.copyWith(common: n.common.copyWith(locked: locked)),
      ),
    ),
    label: label,
  );
}

/// Renames a node (written to the base: names are not per breakpoint).
class RenameNode extends EditCommand {
  const RenameNode(this.nodeId, this.name);

  final String nodeId;
  final String name;

  @override
  String get label => 'Rename layer';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateNode(
      state.document,
      nodeId,
      (n) => n.common.name == name
          ? n
          : n.copyWith(common: n.common.copyWith(name: name)),
    ),
    label: label,
  );
}

/// Moves nodes by ([dx], [dy]) (arrow keys; Shift ×10), as each node's
/// position is seen at the edited breakpoint, routed like [SetProperty].
///
/// In-flow children of an auto-layout frame **reorder** instead (Figma):
/// an arrow along the frame's direction moves them one place among their
/// in-flow siblings (left/up earlier, right/down later; Shift does not
/// change the step), and an arrow across it does nothing. Reorders are
/// structural, so they ignore the edit scope. Grid children are skipped.
/// Instance inner nodes are skipped with a warning.
class NudgeNodes extends EditCommand {
  const NudgeNodes(this.nodeIds, this.dx, this.dy);

  final List<String> nodeIds;
  final double dx, dy;

  @override
  String get label => 'Nudge ${layers(nodeIds.length)}';

  @override
  String get coalesceKey => 'nudge:${(nodeIds.toList()..sort()).join(',')}';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final index = ir.DocumentIndex.of(doc);
    final chain = state.breakpointId == null
        ? const <ir.Breakpoint>[]
        : ir.breakpointChain(doc.breakpoints, state.breakpointId!).chain;
    final writes = <String, Map<String, ir.IrValue>>{};
    final reorders = <String, List<String>>{}; // parent → in-flow ids
    final steps = <String, int>{}; // parent → -1 / +1
    final diags = <ir.IrDiagnostic>[];
    for (final id in nodeIds) {
      final head = id.split('/').first;
      final node = index.node(head);
      if (node == null) {
        diags.add(commandWarning('Node "$id" does not exist.', nodeId: id));
        continue;
      }
      if (id.contains('/')) {
        // An inner node's position comes from its component; the canvas
        // nudges it with a SetProperty of the resolved value (T1.4).
        diags.add(
          commandWarning(
            'Nudging inside an instance is not supported yet.',
            nodeId: id,
          ),
        );
        continue;
      }
      final loc = index.locate(id)!;
      if (loc.isRoot) continue;
      final parent = index.node(loc.parentId!)! as ir.FrameNode;
      final inFlow =
          parent.grid != null ||
          (parent.autoLayout != null &&
              node.common.layoutChild.positioning == ir.Positioning.auto);
      if (inFlow) {
        final al = parent.autoLayout;
        if (parent.grid != null || al == null) continue;
        final along = al.direction == ir.LayoutDirection.horizontal ? dx : dy;
        if (along == 0) continue;
        (reorders[parent.id] ??= []).add(id);
        steps[parent.id] = along < 0 ? -1 : 1;
        continue;
      }
      var seen = node;
      for (final b in chain) {
        final p = node.common.breakpointOverrides[b.id];
        if (p != null) seen = ir.applyPatch(seen, p);
      }
      writes[id] = {
        if (dx != 0) 'x': ir.IrValue.number(seen.common.x + dx),
        if (dy != 0) 'y': ir.IrValue.number(seen.common.y + dy),
      };
    }
    if (writes.isEmpty && reorders.isEmpty) {
      return CommandResult(document: doc, label: label, diagnostics: diags);
    }
    var r = writes.isEmpty
        ? CommandResult(document: doc, label: label)
        : SetProperty.values(writes).apply(state);
    if (!r.ok) return r.copyWith(label: label);
    var current = r.document;
    for (final MapEntry(key: parentId, value: ids) in reorders.entries) {
      final u = ir.updateNode(
        current,
        parentId,
        (n) => reorderInFlow(n as ir.FrameNode, ids.toSet(), steps[parentId]!),
      );
      if (u.ok) current = u.document;
    }
    final outLabel = writes.isEmpty
        ? 'Reorder ${layers(nodeIds.length)}'
        : label;
    r = r.copyWith(
      document: current,
      changed: !identical(current, doc),
      label: outLabel,
      selectionAfter: nodeIds.toSet(),
      coalesceKey: coalesceKey,
      diagnostics: [...diags, ...r.diagnostics],
    );
    return r;
  }
}

/// [frame] with its in-flow children [ids] moved one place ([step] −1:
/// earlier, +1: later) among the in-flow children; absolute children keep
/// their slots. A moved block stops at either end. [frame] itself when
/// nothing moves.
ir.FrameNode reorderInFlow(ir.FrameNode frame, Set<String> ids, int step) {
  bool flows(ir.Node c) =>
      c.common.layoutChild.positioning == ir.Positioning.auto;
  final flow = [
    for (final c in frame.children)
      if (flows(c)) c,
  ];
  final order = [...flow];
  if (step > 0) {
    for (var i = order.length - 2; i >= 0; i--) {
      if (ids.contains(order[i].id) && !ids.contains(order[i + 1].id)) {
        final t = order[i];
        order[i] = order[i + 1];
        order[i + 1] = t;
      }
    }
  } else {
    for (var i = 1; i < order.length; i++) {
      if (ids.contains(order[i].id) && !ids.contains(order[i - 1].id)) {
        final t = order[i];
        order[i] = order[i - 1];
        order[i - 1] = t;
      }
    }
  }
  var same = true;
  for (var i = 0; i < order.length; i++) {
    if (!identical(order[i], flow[i])) same = false;
  }
  if (same) return frame;
  var k = 0;
  return frame.copyWith(
    children: [for (final c in frame.children) flows(c) ? order[k++] : c],
  );
}

/// Runs [inner] against the shared base whatever the edit scope is (content
/// mode: its edits are about the story's words and media, not about one
/// breakpoint's layout).
class BaseScoped extends EditCommand {
  const BaseScoped(this.inner);

  final EditCommand inner;

  @override
  String get label => inner.label;

  @override
  CommandResult apply(EditorState state) => inner.apply(
    state.copyWith(editScope: EditScope.both, scopeFlipped: false),
  );
}
