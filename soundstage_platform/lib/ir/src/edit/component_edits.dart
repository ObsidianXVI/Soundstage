import '../components.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../motion.dart';
import '../nodes/node.dart';
import '../nodes/node_common.dart';
import '../registry/patch.dart';
import '../registry/property_registry.dart';
import '../scene.dart';
import '../values/ids.dart';
import '../values/ir_value.dart';
import 'document_index.dart';
import 'edit_core.dart';
import 'edit_result.dart';
import 'node_edits.dart';

// Component edits (architecture §9; m3.md T3.2). A component's main lives in
// `doc.components`; it is edited in the editor's isolation mode. These
// helpers create a component from a frame, detach an instance back into
// plain layers, and edit component properties and variant sets. Motion
// tracks follow: a track on a node that moves into a component targets the
// instance's inner node (`<instanceId>/<innerId>`), and back on detach.

/// Patch keys that place a node in its parent: they stay on the instance
/// when a frame becomes a component (the rest stay on the main's root).
bool _isPlacementKey(String key) =>
    key == 'x' ||
    key == 'y' ||
    key == 'width' ||
    key == 'height' ||
    key == 'rotation' ||
    key == 'visible' ||
    key == 'opacity' ||
    key.startsWith('layoutChild');

Map<String, Patch> _splitPatches(
  Map<String, Patch> m, {
  required bool placement,
}) {
  final out = <String, Patch>{};
  for (final MapEntry(key: bp, value: p) in m.entries) {
    final kept = {
      for (final e in p.entries)
        if (_isPlacementKey(e.key) == placement) e.key: e.value,
    };
    if (kept.isNotEmpty) out[bp] = kept;
  }
  return out;
}

void _collect(Node n, Set<String> out) {
  out.add(n.id);
  if (n is FrameNode) {
    for (final c in n.children) {
      _collect(c, out);
    }
  }
}

/// Turns frame [frameId] into component [componentId] (named [name]) and
/// puts instance [instanceId] in its place. The frame's placement (position,
/// size, rotation, visibility, opacity, layout-child settings and their
/// breakpoint patches) stays on the instance; everything else becomes the
/// main. Tracks on the frame target the instance; tracks on its
/// descendants target the instance's inner nodes.
EditResult createComponent(
  StageDocument doc,
  String frameId, {
  required String componentId,
  required String instanceId,
  String? name,
}) {
  final index = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final loc = locateForEdit(index, frameId, diags);
  if (loc == null) return failed(doc, diags);
  final frame = index.node(frameId);
  if (frame is! FrameNode || loc.isRoot) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.invalidEdit,
        'Only a frame inside a scene can become a component.',
        nodeId: frameId,
      ),
    ]);
  }
  if (doc.components.containsKey(componentId) || index.contains(instanceId)) {
    return failed(doc, [
      editError(IrDiagnosticKind.duplicateId, 'Component ids must be new.'),
    ]);
  }
  final c = frame.common;
  final rootCommon = c.copyWith(
    x: 0,
    y: 0,
    rotation: 0,
    visible: true,
    opacity: c.opacity,
    layoutChild: const LayoutChild(),
    breakpointOverrides: _splitPatches(c.breakpointOverrides, placement: false),
  );
  final def = ComponentDef(
    id: componentId,
    name: name ?? (c.name.isEmpty ? 'Component' : c.name),
    root: frame.copyWith(common: rootCommon.copyWith(opacity: 1)),
  );
  final instance = InstanceNode(
    common: NodeCommon(
      id: instanceId,
      name: def.name,
      x: c.x,
      y: c.y,
      width: c.width,
      height: c.height,
      rotation: c.rotation,
      visible: c.visible,
      opacity: c.opacity,
      layoutChild: c.layoutChild,
      role: c.role,
      readingOrder: c.readingOrder,
      altText: c.altText,
      breakpointOverrides: _splitPatches(
        c.breakpointOverrides,
        placement: true,
      ),
    ),
    source: InstanceSource.component(componentId),
  );
  final r = updateNode(doc, frameId, (_) => instance);
  if (!r.ok) return r;
  final moved = <String>{};
  _collect(frame, moved);
  var next = r.document.copyWith(
    components: {...r.document.components, componentId: def},
  );
  next = _retarget(next, (target) {
    if (target == frameId) return instanceId;
    if (moved.contains(target)) return '$instanceId/$target';
    return null;
  });
  return EditResult(document: next, changed: true, createdIds: [instanceId]);
}

/// [doc] with every track target that [map] rewrites (null: unchanged).
StageDocument _retarget(
  StageDocument doc,
  String? Function(String target) map,
) {
  var changed = false;
  final scenes = <Scene>[];
  for (final s in doc.scenes) {
    var any = false;
    final tracks = <Track>[];
    for (final t in s.tracks) {
      final to = map(t.target);
      if (to != null && to != t.target) {
        any = true;
        tracks.add(t.copyWith(target: to));
      } else {
        tracks.add(t);
      }
    }
    changed |= any;
    scenes.add(any ? s.copyWith(tracks: tracks) : s);
  }
  return changed ? doc.copyWith(scenes: scenes) : doc;
}

/// Replaces instance [instanceId] with plain layers: a copy of its
/// component's main with fresh ids (from [ids]), its overrides and property
/// values applied, and its placement. Tracks on the instance and its inner
/// nodes follow the copies. Nested instances stay instances (their own
/// overrides are kept).
EditResult detachInstance(
  StageDocument doc,
  String instanceId, {
  required IdGenerator ids,
  PropertyRegistry? registry,
}) {
  final reg = registry ?? PropertyRegistry.standard;
  final index = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final loc = locateForEdit(index, instanceId, diags);
  if (loc == null) return failed(doc, diags);
  final inst = index.node(instanceId);
  if (inst is! InstanceNode) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.invalidEdit,
        '"$instanceId" is not an instance.',
        nodeId: instanceId,
      ),
    ]);
  }
  final def = switch (inst.source) {
    ComponentSource(:final componentId) => doc.components[componentId],
    VariantSource(:final variantSetId, :final variantValues) => () {
      final set = doc.variantSets[variantSetId];
      final v = set?.variants.where(
        (v) => v.values.entries.every(
          (e) => (variantValues[e.key] ?? e.value) == e.value,
        ),
      );
      final id = v == null || v.isEmpty ? null : v.first.componentId;
      return id == null ? null : doc.components[id];
    }(),
  };
  if (def == null) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.missingComponent,
        'The component of "$instanceId" does not exist.',
        nodeId: instanceId,
      ),
    ]);
  }
  final newIds = <String, String>{};
  // Override keys are inner ids (the root's own id for the root).
  Node copy(Node n) {
    final id = ids.next();
    newIds[n.id] = id;
    var out = n;
    // Property values through component bindings.
    for (final MapEntry(key: p, value: propId)
        in n.common.componentBindings.entries) {
      final v = inst.propValues[propId] ?? def.properties[propId]?.defaultValue;
      if (v != null) out = reg.lookup(p)?.trySet(out, v) ?? out;
    }
    final patch = inst.overrides[n.id];
    if (patch != null) out = applyPatch(out, patch, registry: reg);
    out = out.copyWith(
      common: out.common.copyWith(id: id, componentBindings: const {}),
    );
    if (out is FrameNode) {
      out = out.copyWith(children: [for (final c in out.children) copy(c)]);
    }
    return out;
  }

  var root = copy(def.root) as FrameNode;
  final ic = inst.common;
  root = root.copyWith(
    common: root.common.copyWith(
      name: ic.name.isEmpty ? def.name : ic.name,
      x: ic.x,
      y: ic.y,
      width: ic.width,
      height: ic.height,
      rotation: ic.rotation,
      visible: ic.visible,
      opacity: ic.opacity * root.common.opacity,
      layoutChild: ic.layoutChild,
      role: ic.role,
      readingOrder: ic.readingOrder,
      altText: ic.altText,
      interactions: [...root.common.interactions, ...ic.interactions],
      breakpointOverrides: {
        for (final bp in {
          ...root.common.breakpointOverrides.keys,
          ...ic.breakpointOverrides.keys,
        })
          bp: {
            ...?root.common.breakpointOverrides[bp],
            ...?ic.breakpointOverrides[bp],
          },
      },
    ),
  );
  final r = updateNode(doc, instanceId, (_) => root);
  if (!r.ok) return r;
  final rootId = root.id;
  final next = _retarget(r.document, (target) {
    if (target == instanceId) return rootId;
    final prefix = '$instanceId/';
    if (!target.startsWith(prefix)) return null;
    final inner = target.substring(prefix.length).split('/').last;
    return newIds[inner];
  });
  return EditResult(document: next, changed: true, createdIds: [rootId]);
}

/// Replaces component [componentId]'s definition by `change(def)` (its id
/// and root id cannot change; the root is edited in isolation mode).
EditResult updateComponent(
  StageDocument doc,
  String componentId,
  ComponentDef Function(ComponentDef def) change,
) {
  final old = doc.components[componentId];
  if (old == null) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.missingComponent,
        'Component "$componentId" does not exist.',
      ),
    ]);
  }
  final next = change(old);
  if (next == old) return unchanged(doc);
  if (next.id != old.id || next.root.id != old.root.id) {
    return failed(doc, [
      editError(IrDiagnosticKind.invalidEdit, 'A component id cannot change.'),
    ]);
  }
  if (next.name.trim().isEmpty) {
    return failed(doc, [
      editError(IrDiagnosticKind.invalidEdit, 'A component needs a name.'),
    ]);
  }
  return EditResult(
    document: doc.copyWith(components: {...doc.components, componentId: next}),
    changed: true,
  );
}

/// Removes component [componentId]; every instance of it is detached first
/// (fresh ids from [ids]).
EditResult removeComponent(
  StageDocument doc,
  String componentId, {
  required IdGenerator ids,
}) {
  if (!doc.components.containsKey(componentId)) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.missingComponent,
        'Component "$componentId" does not exist.',
      ),
    ]);
  }
  var next = doc;
  final index = DocumentIndex.of(doc);
  for (final id in index.nodeIds.toList()) {
    final n = DocumentIndex.of(next).node(id);
    if (n is InstanceNode &&
        n.source is ComponentSource &&
        (n.source as ComponentSource).componentId == componentId) {
      final r = detachInstance(next, id, ids: ids);
      if (!r.ok) return failed(doc, r.diagnostics);
      next = r.document;
    }
  }
  return EditResult(
    document: next.copyWith(
      components: {...next.components}..remove(componentId),
      variantSets: {
        for (final e in next.variantSets.entries)
          e.key: e.value.copyWith(
            variants: [
              for (final v in e.value.variants)
                if (v.componentId != componentId) v,
            ],
          ),
      },
    ),
    changed: true,
  );
}

/// Sets property value [propId] on instance [instanceId] (null clears it
/// back to the component's default).
EditResult setInstanceProp(
  StageDocument doc,
  String instanceId,
  String propId,
  IrValue? value,
) {
  final failures = <IrDiagnostic>[];
  final r = updateNode(doc, instanceId, (n) {
    if (n is! InstanceNode) {
      failures.add(
        editError(
          IrDiagnosticKind.invalidEdit,
          '"$instanceId" is not an instance.',
          nodeId: instanceId,
        ),
      );
      return n;
    }
    final values = {...n.propValues};
    if (value == null) {
      values.remove(propId);
    } else {
      values[propId] = value;
    }
    return n.copyWith(propValues: values);
  });
  return failures.isEmpty ? r : failed(doc, failures);
}

/// Copies [n] with fresh ids from [ids] (component bindings kept).
Node _freshIds(Node n, IdGenerator ids) {
  final out = n.copyWith(common: n.common.copyWith(id: ids.next()));
  return out is FrameNode
      ? out.copyWith(
          children: [for (final c in out.children) _freshIds(c, ids)],
        )
      : out;
}

/// Adds a variant to component [componentId]: a copy of it (fresh ids, id
/// [newComponentId]) as a new value of the set's first axis. When the
/// component is in no set yet, set [setId] is created with axis "Variant"
/// (values "Default" and the new one) and its instances keep pointing at it
/// directly. Returns the new component's id in `createdIds`.
EditResult addVariant(
  StageDocument doc,
  String componentId, {
  required String newComponentId,
  required String setId,
  required IdGenerator ids,
}) {
  final def = doc.components[componentId];
  if (def == null) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.missingComponent,
        'Component "$componentId" does not exist.',
      ),
    ]);
  }
  if (doc.components.containsKey(newComponentId)) {
    return failed(doc, [
      editError(IrDiagnosticKind.duplicateId, 'Component ids must be new.'),
    ]);
  }
  VariantSet? set;
  for (final s in doc.variantSets.values) {
    if (s.variants.any((v) => v.componentId == componentId)) set = s;
  }
  set ??= VariantSet(
    id: setId,
    name: def.name,
    axes: const {
      'Variant': ['Default'],
    },
    variants: [
      Variant(componentId: componentId, values: const {'Variant': 'Default'}),
    ],
  );
  final axis = set.axes.keys.first;
  final taken = set.axes[axis]!.toSet();
  var value = 'Variant ${taken.length + 1}';
  for (var i = taken.length + 2; taken.contains(value); i++) {
    value = 'Variant $i';
  }
  final copy = ComponentDef(
    id: newComponentId,
    name: '${set.name} / $value',
    root: _freshIds(def.root, ids) as FrameNode,
    properties: def.properties,
    description: def.description,
  );
  final base = set.variants
      .firstWhere((v) => v.componentId == componentId)
      .values;
  final nextSet = set.copyWith(
    axes: {
      ...set.axes,
      axis: [...set.axes[axis]!, value],
    },
    variants: [
      ...set.variants,
      Variant(componentId: newComponentId, values: {...base, axis: value}),
    ],
  );
  return EditResult(
    document: doc.copyWith(
      components: {...doc.components, newComponentId: copy},
      variantSets: {...doc.variantSets, nextSet.id: nextSet},
    ),
    changed: true,
    createdIds: [newComponentId],
  );
}

/// The variant set holding component [componentId], or null.
VariantSet? variantSetOf(StageDocument doc, String componentId) {
  for (final s in doc.variantSets.values) {
    if (s.variants.any((v) => v.componentId == componentId)) return s;
  }
  return null;
}

/// The component an instance shows: its component, or the variant of its
/// set matching its values (null when missing).
String? instanceComponentId(StageDocument doc, InstanceNode n) =>
    switch (n.source) {
      ComponentSource(:final componentId) => componentId,
      VariantSource(:final variantSetId, :final variantValues) => () {
        final set = doc.variantSets[variantSetId];
        if (set == null) return null;
        for (final v in set.variants) {
          if (v.values.entries.every(
            (e) => (variantValues[e.key] ?? e.value) == e.value,
          )) {
            return v.componentId;
          }
        }
        return null;
      }(),
    };

/// Points instance [instanceId] at the variant of set [setId] with [values]
/// (switching variants keeps its overrides and property values).
EditResult setInstanceVariant(
  StageDocument doc,
  String instanceId,
  String setId,
  Map<String, String> values,
) {
  final set = doc.variantSets[setId];
  if (set == null) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.missingVariantSet,
        'Variant set "$setId" does not exist.',
      ),
    ]);
  }
  final failures = <IrDiagnostic>[];
  final r = updateNode(doc, instanceId, (n) {
    if (n is! InstanceNode) {
      failures.add(
        editError(
          IrDiagnosticKind.invalidEdit,
          '"$instanceId" is not an instance.',
          nodeId: instanceId,
        ),
      );
      return n;
    }
    return n.copyWith(
      source: InstanceSource.variant(
        variantSetId: setId,
        variantValues: values,
      ),
    );
  });
  return failures.isEmpty ? r : failed(doc, failures);
}
