import 'dart:math' as math;

import '../diagnostics.dart';
import '../document.dart';
import '../interactions.dart';
import '../motion.dart';
import '../nodes/node.dart';
import '../scene.dart';
import '../values/geometry.dart';
import '../values/ids.dart';
import '../values/ir_value.dart';
import 'document_index.dart';
import 'edit_core.dart';
import 'edit_result.dart';

// Pure document edits on authored nodes (architecture §15, §17.1). Every
// helper copies only the path from the root to what it changes, so
// unchanged scenes and subtrees keep their identity and the resolver memo
// hits. None of them throws: problems are diagnostics on the result, and an
// error leaves the document unchanged (see [EditResult]).

/// Replaces node [nodeId] by `change(node)`.
///
/// The node may be a scene or overlay root (then `change` must return a
/// frame). A changed id, or new ids in a replaced subtree, must not clash
/// with the document. Returning the same node is a successful no-op.
EditResult updateNode(
  StageDocument doc,
  String nodeId,
  Node Function(Node node) change,
) {
  final index = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final loc = locateForEdit(index, nodeId, diags);
  if (loc == null) return failed(doc, diags);
  final old = index.node(nodeId)!;
  final next = change(old);
  if (identical(next, old)) return unchanged(doc);
  if (loc.isRoot && next is! FrameNode) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.invalidEdit,
        'Root "$nodeId" must stay a frame.',
        nodeId: nodeId,
      ),
    ]);
  }
  // Ids and child paths are unchanged when the id is kept and a frame keeps
  // its children: the old index then still holds (no subtree walk).
  final sameShape =
      next.id == old.id &&
      (old is! FrameNode ||
          (next is FrameNode && sameElements(next.children, old.children)));
  if (!sameShape) {
    final before = <String>{};
    collectIds(old, before);
    final after = <String>{};
    final clash = _firstDuplicate(next, after);
    if (clash != null) {
      return failed(doc, [_duplicateId(clash)]);
    }
    for (final id in after) {
      if (!before.contains(id) && index.contains(id)) {
        return failed(doc, [_duplicateId(id)]);
      }
    }
  }
  final rw = TreeRewrite(doc, index)..replace[nodeId] = (_) => next;
  final out = rw.apply();
  if (sameShape) {
    final oldRoot = index.rootOf(loc);
    final newRoot = loc.inOverlay
        ? out.overlay!
        : out.scenes[loc.sceneIndex!].root;
    carryRootIndex(oldRoot, newRoot);
  }
  return EditResult(document: out, changed: true);
}

/// Inserts [nodes] into frame [parentId] at child [index] (clamped into
/// `0..children.length`, with a warning when out of range).
///
/// The new subtrees' ids must be unique among themselves and new to the
/// document.
EditResult insertNodes(
  StageDocument doc,
  String parentId,
  int index,
  List<Node> nodes,
) {
  final idx = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final parent = _frameForChildren(idx, parentId, diags);
  if (parent == null) return failed(doc, diags);
  if (nodes.isEmpty) return unchanged(doc);
  final ids = <String>{};
  for (final n in nodes) {
    final clash = _firstDuplicate(n, ids);
    if (clash != null) return failed(doc, [_duplicateId(clash)]);
  }
  for (final id in ids) {
    if (idx.contains(id)) return failed(doc, [_duplicateId(id)]);
  }
  final at = _clampIndex(index, parent.children.length, parentId, diags);
  final rw = TreeRewrite(doc, idx)
    ..children[parentId] = (kids) => [
      ...kids.sublist(0, at),
      ...nodes,
      ...kids.sublist(at),
    ];
  return EditResult(
    document: rw.apply(),
    changed: true,
    diagnostics: diags,
    createdIds: [for (final n in nodes) n.id],
  );
}

/// Removes the nodes [ids] (and their subtrees). Ids under another removed
/// id are covered by it.
///
/// Tracks of the same scene that target a removed node (or a node inside a
/// removed instance) are removed with it. Other references to removed nodes
/// are left as they are and reported as warnings when they are clocks
/// (pointer and behaviour clocks); `validateDocument` reports the rest
/// (e.g. lightbox actions). Scene roots can't be removed (use
/// `removeScene`).
EditResult removeNodes(StageDocument doc, Iterable<String> ids) {
  final index = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final locs = _locateAll(index, ids, diags, allowRoot: false);
  if (locs == null) return failed(doc, diags);
  final top = _topmost(locs);
  if (top.isEmpty) return unchanged(doc);

  final removed = <String>{};
  final byParent = <String, Set<String>>{};
  final perScene = <int, Set<String>>{};
  for (final MapEntry(key: id, value: loc) in top.entries) {
    final sub = <String>{};
    collectIds(index.node(id)!, sub);
    removed.addAll(sub);
    (byParent[loc.parentId!] ??= {}).add(id);
    if (loc.sceneIndex case final si?) (perScene[si] ??= {}).addAll(sub);
  }
  final rw = TreeRewrite(doc, index);
  byParent.forEach((parent, gone) {
    rw.children[parent] = (kids) => [
      for (final k in kids)
        if (!gone.contains(k.id)) k,
    ];
  });
  perScene.forEach((si, gone) {
    rw.sceneEdits[si] = (s) {
      final kept = [
        for (final t in s.tracks)
          if (!gone.contains(_targetHead(t.target))) t,
      ];
      return kept.length == s.tracks.length ? s : s.copyWith(tracks: kept);
    };
  });
  final out = rw.apply();
  for (final s in out.scenes) {
    for (final c in s.clocks) {
      final ref = switch (c) {
        PointerClock(:final frameId) => frameId,
        BehaviorClock(:final nodeId) => nodeId,
        _ => null,
      };
      if (ref != null && removed.contains(ref)) {
        diags.add(
          editWarning(
            IrDiagnosticKind.missingNode,
            'Clock "${c.id}" of scene "${s.id}" refers to removed node "$ref".',
            nodeId: ref,
          ),
        );
      }
    }
  }
  return EditResult(document: out, changed: true, diagnostics: diags);
}

/// Moves [ids] into frame [newParentId] at insertion point [index]
/// (reparent and/or reorder).
///
/// [index] is a position in the new parent's *current* children
/// (`0..children.length`), counting the moved nodes as if they were still
/// there, as a drop indicator shows it; it is clamped into range with a
/// warning. Moved nodes keep their document (tree) order among themselves.
/// Ids under another moved id travel with it. Refused with `editCycle` when
/// the new parent is a moved node or inside one.
///
/// Stored geometry is not converted: a node keeps its `x`/`y` relative to
/// whichever parent holds it (the editor converts positions it wants to
/// keep visually, e.g. with inverse constraints).
///
/// Moving to another scene carries the tracks that target the moved nodes.
/// A carried track bound to the old scene's scroll clock is rebound to the
/// new scene's scroll clock; one bound to any other clock keeps its clock
/// id (dangling in the new scene) with a `missingClock` warning. Tracks of
/// nodes moved into the overlay (which has no tracks) are dropped with a
/// warning.
EditResult moveNodes(
  StageDocument doc,
  Iterable<String> ids,
  String newParentId,
  int index,
) {
  final idx = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final locs = _locateAll(idx, ids, diags, allowRoot: false);
  final parent = _frameForChildren(idx, newParentId, diags);
  if (locs == null || parent == null) return failed(doc, diags);
  final top = _topmost(locs);
  if (top.isEmpty) return unchanged(doc, diags);
  final parentLoc = idx.locate(newParentId)!;
  for (final id in top.keys) {
    if (id == newParentId || parentLoc.ancestorIds.contains(id)) {
      return failed(doc, [
        editError(
          IrDiagnosticKind.editCycle,
          'Cannot move "$id" into "$newParentId": that is the node itself or '
          'one of its descendants.',
          nodeId: id,
        ),
      ]);
    }
  }

  final ordered = top.keys.toList()
    ..sort((a, b) => _treeOrder(top[a]!, top[b]!));
  final moved = [for (final id in ordered) idx.node(id)!];
  final movedIds = ordered.toSet();
  final at = _clampIndex(index, parent.children.length, newParentId, diags);
  final before = parent.children
      .take(at)
      .where((c) => movedIds.contains(c.id))
      .length;
  final insertAt = at - before;

  final rw = TreeRewrite(doc, idx);
  final parents = {for (final l in top.values) l.parentId!, newParentId};
  for (final p in parents) {
    rw.children[p] = (kids) {
      final rest = [
        for (final k in kids)
          if (!movedIds.contains(k.id)) k,
      ];
      if (p != newParentId) return rest;
      return [
        ...rest.sublist(0, insertAt),
        ...moved,
        ...rest.sublist(insertAt),
      ];
    };
  }

  // Tracks follow nodes that change scene.
  final dest = parentLoc.sceneIndex;
  final carried = <int, Set<String>>{}; // source scene → moved subtree ids
  for (final id in ordered) {
    final src = top[id]!.sceneIndex;
    if (src == null || src == dest) continue;
    collectIds(idx.node(id)!, carried[src] ??= {});
  }
  if (carried.isNotEmpty) {
    final incoming = <Track>[];
    carried.forEach((si, gone) {
      final scene = doc.scenes[si];
      final scroll = _scrollClockId(scene);
      final destScroll = dest == null ? null : _scrollClockId(doc.scenes[dest]);
      final kept = <Track>[];
      for (final t in scene.tracks) {
        if (!gone.contains(_targetHead(t.target))) {
          kept.add(t);
          continue;
        }
        if (dest == null) {
          diags.add(
            editWarning(
              IrDiagnosticKind.missingTrackTarget,
              'Track "${t.id}" was dropped: its node moved into the overlay, '
              'which has no tracks.',
              nodeId: t.target,
            ),
          );
          continue;
        }
        if (t.clockId == scroll && destScroll != null) {
          incoming.add(t.copyWith(clockId: destScroll));
        } else {
          incoming.add(t);
          diags.add(
            editWarning(
              IrDiagnosticKind.missingClock,
              'Track "${t.id}" moved to scene "${doc.scenes[dest].id}" but its '
              'clock "${t.clockId}" belongs to scene "${scene.id}".',
              nodeId: t.target,
            ),
          );
        }
      }
      rw.sceneEdits[si] = (s) => s.copyWith(tracks: kept);
    });
    if (dest != null && incoming.isNotEmpty) {
      final destTrackIds = {for (final t in doc.scenes[dest].tracks) t.id};
      for (final t in incoming) {
        if (destTrackIds.contains(t.id)) {
          diags.add(
            editWarning(
              IrDiagnosticKind.duplicateId,
              'Track id "${t.id}" now appears twice in scene '
              '"${doc.scenes[dest].id}".',
            ),
          );
        }
      }
      rw.sceneEdits[dest] = (s) =>
          s.copyWith(tracks: [...s.tracks, ...incoming]);
    }
  }
  final out = rw.apply();
  return EditResult(
    document: out,
    changed: !identical(out, doc),
    diagnostics: diags,
  );
}

/// Wraps the sibling nodes [ids] in a new frame from [frameFactory], keeping
/// their visual position.
///
/// The factory gets the union of the nodes' boxes (rotated about their
/// centres, as the runtime rotates) in the parent's space, and returns the
/// frame with a new id, no children and any appearance or layout settings;
/// its `x`/`y`/`width`/`height` are set to the bounds. The frame takes the
/// place of the topmost wrapped node; the nodes keep their order inside it,
/// their stored `x`/`y` become relative to it, and the same offset is
/// applied to numeric `x`/`y` breakpoint patches and to `x`/`y` tracks
/// targeting them.
///
/// [boxes] optionally gives each node's actual box in the parent (e.g. the
/// laid-out geometry from the runtime, for children of an auto-layout
/// parent whose stored `x`/`y` are not used); a node with a box gets that
/// box as its stored geometry before the offset. Positions are kept at the
/// parent's reference size: children with right/centre/scale constraints
/// are now constrained to the new frame, as in Figma.
EditResult wrapInFrame(
  StageDocument doc,
  Iterable<String> ids,
  FrameNode Function(StageRect bounds) frameFactory, {
  Map<String, StageRect> boxes = const {},
}) {
  final index = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final locs = _locateAll(index, ids, diags, allowRoot: false);
  if (locs == null) return failed(doc, diags);
  if (locs.isEmpty) {
    return failed(doc, [
      editError(IrDiagnosticKind.invalidEdit, 'Nothing to wrap.'),
    ]);
  }
  final parentId = locs.values.first.parentId!;
  if (locs.values.any((l) => l.parentId != parentId)) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.invalidEdit,
        'Only siblings can be wrapped in a frame.',
      ),
    ]);
  }
  final ordered = locs.keys.toList()
    ..sort((a, b) => locs[a]!.index.compareTo(locs[b]!.index));
  final nodes = <Node>[
    for (final id in ordered) _withBox(index.node(id)!, boxes[id]),
  ];

  var minX = double.infinity, minY = double.infinity;
  var maxX = -double.infinity, maxY = -double.infinity;
  for (final n in nodes) {
    final c = n.common;
    final a = c.rotation * math.pi / 180;
    final cos = math.cos(a).abs(), sin = math.sin(a).abs();
    final hw = (c.width * cos + c.height * sin) / 2;
    final hh = (c.width * sin + c.height * cos) / 2;
    final cx = c.x + c.width / 2, cy = c.y + c.height / 2;
    minX = math.min(minX, cx - hw);
    minY = math.min(minY, cy - hh);
    maxX = math.max(maxX, cx + hw);
    maxY = math.max(maxY, cy + hh);
  }
  final bounds = StageRect(
    x: minX,
    y: minY,
    width: maxX - minX,
    height: maxY - minY,
  );
  final shell = frameFactory(bounds);
  if (shell.children.isNotEmpty) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.invalidEdit,
        'frameFactory must return a frame without children.',
        nodeId: shell.id,
      ),
    ]);
  }
  if (index.contains(shell.id)) return failed(doc, [_duplicateId(shell.id)]);

  final dx = bounds.x, dy = bounds.y;
  final wrappedIds = ordered.toSet();
  final frame = shell.copyWith(
    common: shell.common.copyWith(
      x: bounds.x,
      y: bounds.y,
      width: bounds.width,
      height: bounds.height,
    ),
    children: [for (final n in nodes) _offset(n, dx, dy)],
  );
  final topIndex = locs[ordered.last]!.index;
  final insertAt = topIndex - (ordered.length - 1);
  final rw = TreeRewrite(doc, index)
    ..children[parentId] = (kids) {
      final rest = [
        for (final k in kids)
          if (!wrappedIds.contains(k.id)) k,
      ];
      return [...rest.sublist(0, insertAt), frame, ...rest.sublist(insertAt)];
    };
  final si = locs.values.first.sceneIndex;
  if (si != null) {
    rw.sceneEdits[si] = (s) {
      var changed = false;
      final tracks = [
        for (final t in s.tracks)
          if (wrappedIds.contains(t.target) &&
              (t.property == 'x' || t.property == 'y'))
            () {
              changed = true;
              final d = t.property == 'x' ? dx : dy;
              return t.copyWith(
                keyframes: [
                  for (final k in t.keyframes)
                    k.value is NumberValue
                        ? k.copyWith(
                            value: IrValue.number(
                              (k.value as NumberValue).value - d,
                            ),
                          )
                        : k,
                ],
              );
            }()
          else
            t,
      ];
      return changed ? s.copyWith(tracks: tracks) : s;
    };
  }
  return EditResult(
    document: rw.apply(),
    changed: true,
    diagnostics: diags,
    createdIds: [frame.id],
  );
}

/// Duplicates the nodes [ids] (deep copies with fresh ids from [ids]),
/// each copy placed right after its original. Ids under another duplicated
/// id are copied with it.
///
/// Remapped inside a copy: every node id; lightbox actions that open a
/// node of the same copy. Tracks of the same scene that target a copied
/// node (or a node inside a copied instance, `<id>/…`) are duplicated with
/// fresh track ids and retargeted to the copy (keyframe ids are kept; they
/// are unique per track).
///
/// Not remapped (they keep pointing at the originals or are shared):
/// references from outside the copy, pointer and behaviour clocks (scene
/// level, not duplicated), instance override paths and component bindings
/// (they address component definitions), token and style references, scene
/// links, and interaction ids (unique per node). `idMap` maps each original
/// id to its copy's id.
EditResult duplicateNodes(
  StageDocument doc,
  Iterable<String> nodeIds,
  IdGenerator ids,
) {
  final index = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final locs = _locateAll(index, nodeIds, diags, allowRoot: false);
  if (locs == null) return failed(doc, diags);
  final top = _topmost(locs);
  if (top.isEmpty) return unchanged(doc);
  final ordered = top.keys.toList()
    ..sort((a, b) => _treeOrder(top[a]!, top[b]!));

  final idMap = <String, String>{};
  String fresh() {
    while (true) {
      final id = ids.next();
      if (!index.contains(id) && !idMap.containsValue(id)) return id;
    }
  }

  for (final id in ordered) {
    _assignIds(index.node(id)!, idMap, fresh);
  }
  final copies = <String, Node>{
    for (final id in ordered) id: _copy(index.node(id)!, idMap),
  };

  final rw = TreeRewrite(doc, index);
  final byParent = <String, Set<String>>{};
  for (final id in ordered) {
    (byParent[top[id]!.parentId!] ??= {}).add(id);
  }
  byParent.forEach((parent, originals) {
    rw.children[parent] = (kids) => [
      for (final k in kids) ...[k, if (originals.contains(k.id)) copies[k.id]!],
    ];
  });
  final scenes = {for (final id in ordered) ?top[id]!.sceneIndex};
  for (final si in scenes) {
    rw.sceneEdits[si] = (s) {
      final trackIds = {for (final t in s.tracks) t.id};
      final added = <Track>[];
      for (final t in s.tracks) {
        final head = _targetHead(t.target);
        final copyId = idMap[head];
        if (copyId == null) continue;
        String id;
        do {
          id = ids.next();
        } while (!trackIds.add(id));
        added.add(
          t.copyWith(
            id: id,
            target: '$copyId${t.target.substring(head.length)}',
          ),
        );
      }
      return added.isEmpty ? s : s.copyWith(tracks: [...s.tracks, ...added]);
    };
  }
  return EditResult(
    document: rw.apply(),
    changed: true,
    diagnostics: diags,
    idMap: idMap,
    createdIds: [for (final id in ordered) idMap[id]!],
  );
}

// ---- Helpers ---------------------------------------------------------------

IrDiagnostic _duplicateId(String id) => editError(
  IrDiagnosticKind.invalidEdit,
  'Node id "$id" is already used in the document.',
  nodeId: id,
);

/// Adds the ids under [n] to [seen]; returns the first id seen twice.
String? _firstDuplicate(Node n, Set<String> seen) {
  if (!seen.add(n.id)) return n.id;
  if (n is FrameNode) {
    for (final c in n.children) {
      final d = _firstDuplicate(c, seen);
      if (d != null) return d;
    }
  }
  return null;
}

/// [parentId] as a frame that can take children, or a diagnostic.
FrameNode? _frameForChildren(
  DocumentIndex index,
  String parentId,
  List<IrDiagnostic> out,
) {
  if (locateForEdit(index, parentId, out) == null) return null;
  final n = index.node(parentId)!;
  if (n is FrameNode) return n;
  out.add(
    n is InstanceNode
        ? editError(
            IrDiagnosticKind.editInsideInstance,
            'Instance "$parentId" takes no children; edit its component.',
            nodeId: parentId,
          )
        : editError(
            IrDiagnosticKind.invalidEdit,
            'Node "$parentId" is not a frame and takes no children.',
            nodeId: parentId,
          ),
  );
  return null;
}

/// Locates every id; null (with diagnostics) when any is missing or a root
/// where roots aren't allowed. Duplicated ids are taken once.
Map<String, NodeLocation>? _locateAll(
  DocumentIndex index,
  Iterable<String> ids,
  List<IrDiagnostic> out, {
  required bool allowRoot,
}) {
  final locs = <String, NodeLocation>{};
  var ok = true;
  for (final id in ids) {
    if (locs.containsKey(id)) continue;
    final loc = locateForEdit(index, id, out);
    if (loc == null) {
      ok = false;
      continue;
    }
    if (!allowRoot && loc.isRoot) {
      out.add(
        editError(
          IrDiagnosticKind.invalidEdit,
          '"$id" is a root; edit its scene instead.',
          nodeId: id,
        ),
      );
      ok = false;
      continue;
    }
    locs[id] = loc;
  }
  return ok ? locs : null;
}

/// [locs] without the ids that have an ancestor in [locs].
Map<String, NodeLocation> _topmost(Map<String, NodeLocation> locs) => {
  for (final MapEntry(key: id, value: l) in locs.entries)
    if (!l.ancestorIds.any(locs.containsKey)) id: l,
};

/// Document tree order: scenes in order, the overlay last, then child paths.
int _treeOrder(NodeLocation a, NodeLocation b) {
  final sa = a.sceneIndex ?? 1 << 30, sb = b.sceneIndex ?? 1 << 30;
  if (sa != sb) return sa.compareTo(sb);
  final pa = a.childPath, pb = b.childPath;
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return pa.length.compareTo(pb.length);
}

int _clampIndex(
  int index,
  int length,
  String parentId,
  List<IrDiagnostic> out,
) {
  if (index >= 0 && index <= length) return index;
  out.add(
    editWarning(
      IrDiagnosticKind.invalidEdit,
      'Index $index is outside 0–$length for "$parentId"; clamped.',
      nodeId: parentId,
    ),
  );
  return index < 0 ? 0 : length;
}

/// The node id a track target names: the target itself, or the instance id
/// before the first `/` of an instance-inner target.
String _targetHead(String target) {
  final i = target.indexOf('/');
  return i < 0 ? target : target.substring(0, i);
}

String? _scrollClockId(Scene s) {
  for (final c in s.clocks) {
    if (c is SceneScrollClock) return c.id;
  }
  return null;
}

Node _withBox(Node n, StageRect? box) => box == null
    ? n
    : n.copyWith(
        common: n.common.copyWith(
          x: box.x,
          y: box.y,
          width: box.width,
          height: box.height,
        ),
      );

/// [n] moved by (−dx, −dy), including numeric `x`/`y` breakpoint patches.
Node _offset(Node n, double dx, double dy) {
  final c = n.common;
  final patches = {
    for (final MapEntry(key: bp, value: p) in c.breakpointOverrides.entries)
      bp: {
        for (final MapEntry(key: path, :value) in p.entries)
          path: switch ((path, value)) {
            ('x', NumberValue(:final value)) => IrValue.number(value - dx),
            ('y', NumberValue(:final value)) => IrValue.number(value - dy),
            _ => value,
          },
      },
  };
  return n.copyWith(
    common: c.copyWith(x: c.x - dx, y: c.y - dy, breakpointOverrides: patches),
  );
}

void _assignIds(Node n, Map<String, String> map, String Function() fresh) {
  map[n.id] = fresh();
  if (n is FrameNode) {
    for (final c in n.children) {
      _assignIds(c, map, fresh);
    }
  }
}

/// A deep copy of [n] with ids from [map] and intra-copy lightbox targets
/// remapped.
Node _copy(Node n, Map<String, String> map) {
  final c = n.common;
  final interactions = [
    for (final i in c.interactions)
      i.copyWith(
        actions: [
          for (final a in i.actions)
            if (a case OpenLightboxAction(
              :final nodeId,
            ) when map.containsKey(nodeId))
              Action.openLightbox(nodeId: map[nodeId]!)
            else
              a,
        ],
      ),
  ];
  final common = c.copyWith(id: map[c.id]!, interactions: interactions);
  return switch (n) {
    FrameNode() => n.copyWith(
      common: common,
      children: [for (final k in n.children) _copy(k, map)],
    ),
    _ => n.copyWith(common: common),
  };
}
