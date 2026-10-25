import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';
import 'motion_commands.dart';

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

/// The static routing decision for writing to [nodeId] in [state] (§15),
/// once the motion routing ([writeAnimated]) has passed:
///
/// 1. Inside an instance (`<instanceId>/<innerPath>`) → instance override.
/// 2. Else by the effective edit scope: *Both* → base, *This breakpoint* →
///    a patch on the edited artboard's breakpoint.
WriteTarget routeFor(EditorState state, String nodeId) {
  if (nodeId.contains('/')) return WriteTarget.instanceOverride;
  return state.effectiveScope == EditScope.both
      ? WriteTarget.base
      : WriteTarget.breakpointPatch;
}

/// Writes [value] at [path] on [nodeId]: through [writeAnimated] when the
/// property is (or, with auto-key, becomes) animated, else as routed by
/// [routeFor]. [ids] makes new track and keyframe ids (tests).
ir.EditResult writeProperty(
  EditorState state,
  ir.StageDocument doc,
  String nodeId,
  String path,
  ir.IrValue value, {
  ir.PropertyRegistry? registry,
  ir.IdGenerator? ids,
}) {
  final reg = registry ?? ir.PropertyRegistry.standard;
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
  final animated = writeAnimated(
    state,
    doc,
    nodeId,
    path,
    value,
    registry: reg,
    ids: ids,
  );
  if (animated != null) return animated;
  final split = writeSplitAroundTracks(
    state,
    doc,
    nodeId,
    path,
    value,
    registry: reg,
    ids: ids,
  );
  if (split != null) return split;
  return _writeStatic(state, doc, nodeId, path, value, reg);
}

/// The static part of [writeProperty]: [value] at [path] on [nodeId] as
/// routed by [routeFor] (no motion routing).
ir.EditResult _writeStatic(
  EditorState state,
  ir.StageDocument doc,
  String nodeId,
  String path,
  ir.IrValue value,
  ir.PropertyRegistry reg,
) {
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

// ---- Motion routing (m2.md "Writing values while animated") -------------------

/// The track of [scene] that animates [path] of [nodeId] at breakpoint
/// [breakpointId]: a breakpoint-specific track wins over an all-breakpoints
/// one (as in the resolver and runtime). Null when none applies.
ir.Track? animatingTrack(
  ir.Scene scene,
  String nodeId,
  String path,
  String? breakpointId,
) {
  ir.Track? all;
  for (final t in scene.tracks) {
    if (t.target != nodeId || t.property != path) continue;
    final only = t.breakpoints;
    if (only == null) {
      all ??= t;
    } else if (breakpointId != null && only.contains(breakpointId)) {
      return t;
    }
  }
  return all;
}

/// The motion part of the `SetProperty` routing, or null when the write is
/// static (then [routeFor] decides):
///
/// 1. The property has a track that applies at the edited artboard's
///    breakpoint ([animatingTrack]) → the keyframe at the playhead of that
///    track's clock is written or replaced, whether or not auto-key is on
///    (After Effects behaviour).
/// 2. Else, auto-key on and the property animatable → a new track on the
///    scene's active clock, following the edit scope (*Both* → all
///    breakpoints, *This breakpoint* → the edited breakpoint only), with a
///    keyframe at the playhead. When the playhead is not at the clock's
///    start (0, also for a pointer clock, whose 0 is its rest position:
///    DECISIONS 26/10/26 T2.0-1), a keyframe at the start holds
///    the previous static value, so the change animates rather than jumps.
///    Writing the static value itself creates nothing.
///
/// Nodes in the document overlay have no tracks.
ir.EditResult? writeAnimated(
  EditorState state,
  ir.StageDocument doc,
  String nodeId,
  String path,
  ir.IrValue value, {
  ir.PropertyRegistry? registry,
  ir.IdGenerator? ids,
}) {
  final reg = registry ?? ir.PropertyRegistry.standard;
  final index = ir.DocumentIndex.of(doc);
  final loc = index.locate(nodeId.split('/').first);
  final si = loc?.sceneIndex;
  if (si == null) return null;
  final scene = doc.scenes[si];
  final bp = state.breakpointId;
  final track = animatingTrack(scene, nodeId, path, bp);
  if (track != null) {
    return ir.writeKeyframeAt(
      doc,
      scene.id,
      track.id,
      t: state.playheadOf(scene.id, track.clockId),
      value: value,
      newId: freshMotionId({for (final k in track.keyframes) k.id}, ids),
      registry: reg,
    );
  }
  if (!state.autoKey) return null;
  // Sub-paths with their own tracks: the write is split instead
  // ([writeSplitAroundTracks]), never a competing whole-value track.
  final prefix = '$path.';
  if (scene.tracks.any(
    (t) => t.target == nodeId && t.property.startsWith(prefix),
  )) {
    return null;
  }
  final match = reg.lookup(path);
  if (match == null || !match.descriptor.animatable) return null;
  final thisBreakpoint = state.effectiveScope == EditScope.thisBreakpoint;
  if (thisBreakpoint && bp == null) return null;
  final clockId = state.activeClockOf(scene.id);
  if (clockId == null) return null;
  final t = state.playheadOf(scene.id, clockId);
  final old = staticValueAt(doc, nodeId, path, bp, registry: reg);
  if (old == value) return null;
  // Every clock starts at 0 (a pointer clock's rest position; T2.0-1).
  const start = 0.0;
  final used = <String>{};
  String next() {
    final id = freshMotionId(used, ids);
    used.add(id);
    return id;
  }

  return ir.addTrack(
    doc,
    scene.id,
    ir.Track(
      id: freshMotionId(trackIdsOf(doc, scene.id), ids),
      target: nodeId,
      property: path,
      clockId: clockId,
      breakpoints: thisBreakpoint ? [bp!] : null,
      keyframes: [
        if (old != null && (t - start).abs() > ir.kKeyframeTimeEpsilon)
          ir.Keyframe(id: next(), t: start, value: old),
        ir.Keyframe(id: next(), t: t, value: value),
      ],
    ),
    registry: reg,
  );
}

/// The value of [path] on [nodeId] at the playhead when a track animates
/// it at the edited breakpoint ([animatingTrack]), else null.
ir.IrValue? animatedValueAt(
  EditorState state,
  ir.StageDocument doc,
  String nodeId,
  String path,
) {
  final si = ir.DocumentIndex.of(
    doc,
  ).locate(nodeId.split('/').first)?.sceneIndex;
  if (si == null) return null;
  final scene = doc.scenes[si];
  final t = animatingTrack(scene, nodeId, path, state.breakpointId);
  if (t == null) return null;
  return ir.evaluateTrack(t, state.playheadOf(scene.id, t.clockId));
}

/// A write of a whole value (a paint stack, a paint, an effect list) whose
/// sub-paths have tracks at the edited breakpoint (DECISIONS 26/10/26
/// T2.0-2): the write is split so no part of it looks ignored.
///
/// - Each animated sub-path (`fills.p1.color` under `fills`) gets a
///   keyframe at the playhead of its track's clock, holding that part of
///   [value] (sub-paths [value] no longer has, a removed paint, are left
///   alone).
/// - The rest goes to the static value through the M1 routing, with the
///   animated sub-paths keeping their previous static values (they are
///   hidden under their tracks).
///
/// Auto-key creates no track here: a track on the whole path would compete
/// with the sub-path tracks. Null when no sub-path of [path] is animated
/// (then the write is plain static), and for nodes inside instances.
ir.EditResult? writeSplitAroundTracks(
  EditorState state,
  ir.StageDocument doc,
  String nodeId,
  String path,
  ir.IrValue value, {
  ir.PropertyRegistry? registry,
  ir.IdGenerator? ids,
}) {
  if (nodeId.contains('/')) return null;
  final reg = registry ?? ir.PropertyRegistry.standard;
  final index = ir.DocumentIndex.of(doc);
  final si = index.locate(nodeId)?.sceneIndex;
  if (si == null) return null;
  final scene = doc.scenes[si];
  final bp = state.breakpointId;
  final prefix = '$path.';
  final subPaths = <String>{
    for (final t in scene.tracks)
      if (t.target == nodeId && t.property.startsWith(prefix)) t.property,
  };
  final tracks = <ir.Track>[
    for (final p in subPaths) ?animatingTrack(scene, nodeId, p, bp),
  ];
  if (tracks.isEmpty) return null;
  final node = index.node(nodeId);
  if (node == null) return null;
  var seen = node;
  if (bp != null) {
    for (final b in ir.breakpointChain(doc.breakpoints, bp).chain) {
      final p = node.common.breakpointOverrides[b.id];
      if (p != null) seen = ir.applyPatch(seen, p);
    }
  }
  final written = reg.trySet(seen, path, value);
  if (written == null) return null;
  var current = doc;
  var changed = false;
  final diags = <ir.IrDiagnostic>[];
  var rest = written;
  for (final t in tracks) {
    final part = reg.get(written, t.property);
    final old = reg.get(seen, t.property);
    if (old != null) rest = reg.trySet(rest, t.property, old) ?? rest;
    if (part == null) continue;
    // Each track is written once, so its keyframes are still [t]'s.
    final kfs = t.keyframes;
    final r = ir.writeKeyframeAt(
      current,
      scene.id,
      t.id,
      t: state.playheadOf(scene.id, t.clockId),
      value: part,
      newId: freshMotionId({for (final k in kfs) k.id}, ids),
      registry: reg,
    );
    if (!r.ok) return r.copyWith(document: doc, changed: false);
    current = r.document;
    changed |= r.changed;
    diags.addAll(r.diagnostics);
  }
  final restValue = reg.get(rest, path);
  if (restValue != null) {
    final r = _writeStatic(state, current, nodeId, path, restValue, reg);
    if (!r.ok) return r.copyWith(document: doc, changed: false);
    current = r.document;
    changed |= r.changed;
    diags.addAll(r.diagnostics);
  }
  return ir.EditResult(document: current, changed: changed, diagnostics: diags);
}

/// The static (unanimated) value of [path] on [nodeId] at [breakpointId]:
/// for an authored node without a token binding on the path, its base with
/// the breakpoint chain's patches applied; otherwise (instance inner
/// nodes, bindings, inherited text styles) through `Resolver.explain`,
/// which resolves the node's scene once.
ir.IrValue? staticValueAt(
  ir.StageDocument doc,
  String nodeId,
  String path,
  String? breakpointId, {
  ir.PropertyRegistry? registry,
}) {
  final reg = registry ?? ir.PropertyRegistry.standard;
  bool overlaps(String k) =>
      k == path || k.startsWith('$path.') || path.startsWith('$k.');
  if (!nodeId.contains('/')) {
    final n = ir.DocumentIndex.of(doc).node(nodeId);
    if (n != null && !n.common.bindings.keys.any(overlaps)) {
      var seen = n;
      if (breakpointId != null) {
        for (final b
            in ir.breakpointChain(doc.breakpoints, breakpointId).chain) {
          final p = n.common.breakpointOverrides[b.id];
          if (p != null) seen = ir.applyPatch(seen, p);
        }
      }
      final v = reg.get(seen, path);
      if (v != null && v is! ir.NoneValue) return v;
    }
  }
  return ir.Resolver(registry: reg)
      .explain(
        doc,
        nodeId,
        ir.PropertyPath(path),
        ir.ResolveContext(breakpointId: breakpointId),
      )
      .finalValue;
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
  SetProperty(
    Iterable<String> nodeIds,
    String path,
    ir.IrValue value, {
    this.ids,
  }) : writes = {
         for (final id in nodeIds) id: {path: value},
       };

  SetProperty.values(this.writes, {this.ids});

  /// Makes new track and keyframe ids for animated writes (tests; default:
  /// random).
  final ir.IdGenerator? ids;

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
        final w = writeProperty(state, current, id, path, value, ids: ids);
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
      // Animated positions nudge from the value shown at the playhead.
      double at(String path, double fallback) =>
          switch (animatedValueAt(state, doc, id, path)) {
            ir.NumberValue(:final value) => value,
            _ => fallback,
          };
      writes[id] = {
        if (dx != 0) 'x': ir.IrValue.number(at('x', seen.common.x) + dx),
        if (dy != 0) 'y': ir.IrValue.number(at('y', seen.common.y) + dy),
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

// ---- Inspector keyframe toggles (m2.md "Inspector") ---------------------------

/// Where the keyframes of [path] on the nodes [ids] stand at the playheads
/// (the inspector's ◇ / ◆ / half-filled toggle).
enum KeyframeMark {
  /// No track animates the property: ◇.
  none,

  /// Every node has a keyframe at its track's playhead: ◆.
  atPlayhead,

  /// A track exists but not every node has a keyframe at the playhead:
  /// half-filled.
  elsewhere,
}

/// The keyframe mark of [path] on [ids], plus the previous and next
/// keyframe times around the playhead (for ‹ ›), on the clock of the first
/// node's track at the edited breakpoint ([animatingTrack]).
({KeyframeMark mark, String? clockId, double? prev, double? next})
keyframeNavFor(EditorState state, Iterable<String> ids, String path) {
  final doc = state.document;
  final index = ir.DocumentIndex.of(doc);
  var any = false, all = true;
  String? clockId;
  double? prev, next;
  for (final id in ids) {
    final si = index.locate(id.split('/').first)?.sceneIndex;
    final scene = si == null ? null : doc.scenes[si];
    final t = scene == null
        ? null
        : animatingTrack(scene, id, path, state.breakpointId);
    if (t == null) {
      all = false;
      continue;
    }
    any = true;
    final ph = state.playheadOf(scene!.id, t.clockId);
    if (!t.keyframes.any((k) => (k.t - ph).abs() <= ir.kKeyframeTimeEpsilon)) {
      all = false;
    }
    if (clockId != null && t.clockId != clockId) continue;
    clockId = t.clockId;
    for (final k in t.keyframes) {
      if (k.t < ph - ir.kKeyframeTimeEpsilon && (prev == null || k.t > prev)) {
        prev = k.t;
      }
      if (k.t > ph + ir.kKeyframeTimeEpsilon && (next == null || k.t < next)) {
        next = k.t;
      }
    }
  }
  final mark = !any
      ? KeyframeMark.none
      : (all ? KeyframeMark.atPlayhead : KeyframeMark.elsewhere);
  return (mark: mark, clockId: clockId, prev: prev, next: next);
}

/// The inspector's keyframe toggle on [path] for the nodes of [values]
/// (`node id → the value shown at the playhead`):
///
/// - every node has a keyframe at its track's playhead → those keyframes
///   are removed (a track goes with its last keyframe);
/// - else each node without one gets a keyframe at the playhead holding
///   its shown value: on its track, or on a new track on the scene's
///   active clock that follows the edit scope (*Both* → all breakpoints,
///   *This breakpoint* → the edited one), whatever auto-key says.
class ToggleKeyframes extends EditCommand {
  ToggleKeyframes(this.path, this.values, {this.ids});

  final String path;
  final Map<String, ir.IrValue> values;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Toggle keyframe';

  @override
  CommandResult apply(EditorState state) {
    final mark = keyframeNavFor(state, values.keys, path).mark;
    final bp = state.breakpointId;
    final reg = ir.PropertyRegistry.standard;
    final match = reg.lookup(path);
    if (match == null || !match.descriptor.animatable) {
      return failedCommand(state, label, [
        commandError('"$path" cannot be animated.', path: path),
      ]);
    }
    var doc = state.document;
    final diags = <ir.IrDiagnostic>[];
    for (final MapEntry(key: id, :value) in values.entries) {
      final index = ir.DocumentIndex.of(doc);
      final si = index.locate(id.split('/').first)?.sceneIndex;
      if (si == null) continue;
      final scene = doc.scenes[si];
      final t = animatingTrack(scene, id, path, bp);
      ir.EditResult r;
      if (mark == KeyframeMark.atPlayhead) {
        final ph = state.playheadOf(scene.id, t!.clockId);
        r = ir.removeKeyframes(doc, scene.id, {
          t.id: {
            for (final k in t.keyframes)
              if ((k.t - ph).abs() <= ir.kKeyframeTimeEpsilon) k.id,
          },
        });
      } else if (t != null) {
        r = ir.writeKeyframeAt(
          doc,
          scene.id,
          t.id,
          t: state.playheadOf(scene.id, t.clockId),
          value: value,
          newId: freshMotionId({for (final k in t.keyframes) k.id}, ids),
        );
      } else {
        final clockId = state.activeClockOf(scene.id);
        if (clockId == null) continue;
        final thisBreakpoint = state.effectiveScope == EditScope.thisBreakpoint;
        if (thisBreakpoint && bp == null) continue;
        r = ir.addTrack(
          doc,
          scene.id,
          ir.Track(
            id: freshMotionId(trackIdsOf(doc, scene.id), ids),
            target: id,
            property: path,
            clockId: clockId,
            breakpoints: thisBreakpoint ? [bp!] : null,
            keyframes: [
              ir.Keyframe(
                id: freshMotionId(const {}, ids),
                t: state.playheadOf(scene.id, clockId),
                value: value,
              ),
            ],
          ),
        );
      }
      if (!r.ok) {
        diags.addAll(r.diagnostics.map(asWarning));
        continue;
      }
      doc = r.document;
      diags.addAll(r.diagnostics);
    }
    return CommandResult(
      document: doc,
      label: mark == KeyframeMark.atPlayhead
          ? 'Delete keyframe'
          : 'Add keyframe',
      changed: !identical(doc, state.document),
      diagnostics: diags,
    );
  }
}
