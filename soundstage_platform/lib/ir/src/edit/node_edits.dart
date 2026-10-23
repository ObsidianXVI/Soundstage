import 'dart:math' as math;

import '../behaviors.dart';
import '../breakpoint.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../interactions.dart';
import '../motion.dart';
import '../nodes/node.dart';
import '../nodes/node_common.dart';
import '../nodes/text.dart';
import '../registry/patch.dart';
import '../resolve/breakpoints.dart';
import '../scene.dart';
import '../values/geometry.dart';
import '../values/ids.dart';
import '../values/ir_value.dart';
import 'constraint_math.dart';
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
/// id are covered by it. Scene roots can't be removed (use `removeScene`).
///
/// References to the removed nodes are removed in the same edit
/// (DECISIONS 23/10/26, T1.0 follow-ups) and listed in `cascade`:
///
/// - pointer and behaviour clocks bound to a removed node (in any scene);
/// - tracks that target a removed node (or a node inside a removed
///   instance), and tracks that run on a removed clock;
/// - interaction actions, on the remaining nodes of every scene and the
///   overlay, that open a removed node in the lightbox or drive a removed
///   clock; interactions triggered by a removed clock (`clockReach`), and
///   interactions left with no actions, are removed whole.
///
/// Text reveals and embed inputs bound to a removed clock are left as they
/// are, with a `missingClock` warning.
EditResult removeNodes(StageDocument doc, Iterable<String> ids) {
  final index = DocumentIndex.of(doc);
  final diags = <IrDiagnostic>[];
  final locs = _locateAll(index, ids, diags, allowRoot: false);
  if (locs == null) return failed(doc, diags);
  final top = _topmost(locs);
  if (top.isEmpty) return unchanged(doc);

  final removed = <String>{};
  final byParent = <String, Set<String>>{};
  for (final MapEntry(key: id, value: loc) in top.entries) {
    collectIds(index.node(id)!, removed);
    (byParent[loc.parentId!] ??= {}).add(id);
  }
  final rw = TreeRewrite(doc, index);
  byParent.forEach((parent, gone) {
    rw.children[parent] = (kids) => [
      for (final k in kids)
        if (!gone.contains(k.id)) k,
    ];
  });

  // Clocks bound to removed nodes, then the tracks that lose their target
  // or their clock.
  final goneClocks = <String>{};
  for (final s in doc.scenes) {
    for (final c in s.clocks) {
      if (_clockNodeRef(c) case final ref? when removed.contains(ref)) {
        goneClocks.add(c.id);
      }
    }
  }
  final removedClockIds = <String>[];
  final removedTrackIds = <String>[];
  for (final (si, s) in doc.scenes.indexed) {
    final clocks = <Clock>[];
    for (final c in s.clocks) {
      if (goneClocks.contains(c.id)) {
        removedClockIds.add(c.id);
      } else {
        clocks.add(c);
      }
    }
    final tracks = <Track>[];
    for (final t in s.tracks) {
      if (removed.contains(_targetHead(t.target)) ||
          goneClocks.contains(t.clockId)) {
        removedTrackIds.add(t.id);
      } else {
        tracks.add(t);
      }
    }
    if (clocks.length != s.clocks.length || tracks.length != s.tracks.length) {
      rw.sceneEdits[si] = (sc) => sc.copyWith(clocks: clocks, tracks: tracks);
    }
  }

  // Interactions and behaviours of the remaining nodes.
  final removedActions = <CascadedAction>[];
  final removedInteractions = <CascadedInteraction>[];
  bool actionGone(Action a) => switch (a) {
    OpenLightboxAction(:final nodeId) => removed.contains(nodeId),
    PlayTimelineAction(:final clockId) ||
    PauseTimelineAction(:final clockId) ||
    SeekTimelineAction(:final clockId) ||
    ReverseTimelineAction(:final clockId) => goneClocks.contains(clockId),
    _ => false,
  };
  void visit(Node n) {
    if (removed.contains(n.id)) return;
    final c = n.common;
    if (c.interactions.isNotEmpty) {
      var changed = false;
      final kept = <Interaction>[];
      for (final i in c.interactions) {
        if (i.trigger case ClockReachTrigger(
          :final clockId,
        ) when goneClocks.contains(clockId)) {
          removedInteractions.add(
            CascadedInteraction(nodeId: n.id, interaction: i),
          );
          changed = true;
          continue;
        }
        final actions = <Action>[];
        for (final a in i.actions) {
          if (actionGone(a)) {
            removedActions.add(
              CascadedAction(nodeId: n.id, interactionId: i.id, action: a),
            );
          } else {
            actions.add(a);
          }
        }
        if (actions.length == i.actions.length) {
          kept.add(i);
          continue;
        }
        changed = true;
        if (actions.isEmpty) {
          removedInteractions.add(
            CascadedInteraction(nodeId: n.id, interaction: i),
          );
        } else {
          kept.add(i.copyWith(actions: actions));
        }
      }
      if (changed) {
        rw.replace[n.id] = (m) =>
            m.copyWith(common: m.common.copyWith(interactions: kept));
      }
    }
    if (goneClocks.isNotEmpty) {
      final refs = <String>[
        if (n case FrameNode(behavior: TextRevealBehavior(:final clockId)))
          clockId,
        if (n is EmbedNode) ...n.inputBindings.values,
      ];
      for (final ref in refs) {
        if (goneClocks.contains(ref)) {
          diags.add(
            editWarning(
              IrDiagnosticKind.missingClock,
              'Node "${n.id}" uses clock "$ref", which was removed with the '
              'node it was bound to.',
              nodeId: n.id,
            ),
          );
        }
      }
    }
    if (n is FrameNode) n.children.forEach(visit);
  }

  for (final s in doc.scenes) {
    visit(s.root);
  }
  if (doc.overlay case final o?) visit(o);

  return EditResult(
    document: rw.apply(),
    changed: true,
    diagnostics: diags,
    cascade: EditCascade(
      removedTrackIds: removedTrackIds,
      removedClockIds: removedClockIds,
      removedActions: removedActions,
      removedInteractions: removedInteractions,
    ),
  );
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
/// **Position** (Figma's behaviour; DECISIONS 23/10/26). With
/// [preservePosition] (the default), a node that changes parent keeps its
/// visual position when it lands constraint-placed: in a frame without auto
/// layout or grid, or as an `absolute` child of an auto-layout frame. Its
/// box relative to the new parent is turned back into stored geometry with
/// the inverse of the §4.3 constraint math, against the new parent's
/// reference size at [breakpointId] (default: the first primary breakpoint,
/// else the first). The change goes to the shared base, and the node's
/// numeric `x`/`y`/`width`/`height` breakpoint patches and its `x`/`y`
/// tracks shift by the same amount, so other breakpoints keep their relative
/// placement. In-flow children of an auto-layout or grid parent just
/// reorder (stored geometry doesn't place them), and a reorder within the
/// same parent never converts.
///
/// [boxes] gives actual layout boxes (before `rotation` and `motion`) of the
/// moved nodes and of the new parent, each in the space of its scene root
/// at [breakpointId], e.g. the runtime's laid-out geometry on the edited
/// artboard; give both or neither. A missing box is derived from stored
/// geometry at that breakpoint, which is exact for free frames at their
/// design size. When the derivation crosses an in-flow child of an
/// auto-layout or grid frame (whose stored `x`/`y` don't place it), the node
/// moves without conversion and an `invalidEdit` warning says so. Rotated
/// ancestors are not accounted for. Across scenes, each box is relative to
/// its own scene root.
///
/// **Tracks and clocks.** Moving to another scene carries the tracks that
/// target the moved nodes. A carried track on the old scene's own scroll
/// clock is rebound to the new scene's scroll clock; any other clock it runs
/// on is copied into the new scene with a fresh id from [idGenerator]
/// (default: `IdGenerator.forDocument(doc)`), once per clock, and the track
/// is rebound to the copy (DECISIONS 23/10/26). Clock references inside the
/// moved subtrees (clock-reach triggers, timeline actions, text reveals,
/// embed inputs) follow the same rebinding. `cascade.clockIdMap` lists the
/// copies. A track whose clock doesn't exist keeps its clock id with a
/// `missingClock` warning. Tracks of nodes moved into the overlay (which
/// has no tracks) are dropped with a warning.
EditResult moveNodes(
  StageDocument doc,
  Iterable<String> ids,
  String newParentId,
  int index, {
  bool preservePosition = true,
  Map<String, StageRect> boxes = const {},
  String? breakpointId,
  IdGenerator? idGenerator,
}) {
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
  final movedIds = ordered.toSet();
  final at = _clampIndex(index, parent.children.length, newParentId, diags);
  final before = parent.children
      .take(at)
      .where((c) => movedIds.contains(c.id))
      .length;
  final insertAt = at - before;

  // Geometry deltas for nodes that keep their visual position.
  final deltas = <String, _GeometryDelta>{};
  if (preservePosition) {
    final geo = _MoveGeometry(doc, idx, breakpointId, boxes);
    for (final id in ordered) {
      if (top[id]!.parentId == newParentId) continue;
      final node = idx.node(id)!;
      final mode = node.common.layoutChild.positioning;
      final inFlow =
          (parent.autoLayout != null && mode == Positioning.auto) ||
          parent.grid != null;
      if (inFlow) continue;
      final d = geo.delta(id, newParentId);
      if (d == null) {
        diags.add(
          editWarning(
            IrDiagnosticKind.invalidEdit,
            'The position of "$id" could not be kept: its box or the new '
            'parent\'s depends on auto layout; pass boxes.',
            nodeId: id,
          ),
        );
      } else if (!d.isZero) {
        deltas[id] = d;
      }
    }
  }

  // Tracks (and the clocks they run on) follow nodes that change scene.
  final dest = parentLoc.sceneIndex;
  final carried = <int, Set<String>>{}; // source scene → moved subtree ids
  for (final id in ordered) {
    final src = top[id]!.sceneIndex;
    if (src == null || src == dest) continue;
    collectIds(idx.node(id)!, carried[src] ??= {});
  }
  final clockIdMap = <String, String>{}; // copies only
  final rebind = <String, String>{}; // every clock rebinding
  final incoming = <Track>[];
  final newClocks = <Clock>[];
  final rw = TreeRewrite(doc, idx);
  if (carried.isNotEmpty) {
    final destScene = dest == null ? null : doc.scenes[dest];
    final destScroll = destScene == null ? null : _scrollClockId(destScene);
    final usedClockIds = {
      for (final s in doc.scenes) ...s.clocks.map((c) => c.id),
    };
    var gen = idGenerator;
    String freshClockId() {
      gen ??= IdGenerator.forDocument(doc);
      while (true) {
        final id = gen!.next();
        if (usedClockIds.add(id)) return id;
      }
    }

    carried.forEach((si, gone) {
      final scene = doc.scenes[si];
      final scroll = _scrollClockId(scene);
      final clocks = {for (final c in scene.clocks) c.id: c};
      final kept = <Track>[];
      for (final t in scene.tracks) {
        if (!gone.contains(_targetHead(t.target))) {
          kept.add(t);
          continue;
        }
        if (destScene == null) {
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
        final clock = clocks[t.clockId];
        if (t.clockId == scroll && destScroll != null) {
          rebind[t.clockId] = destScroll;
          incoming.add(t.copyWith(clockId: destScroll));
        } else if (clock != null) {
          final copyId = clockIdMap[clock.id] ??= () {
            final id = freshClockId();
            newClocks.add(switch (clock) {
              // The scene's own scroll clock becomes the new scene's.
              SceneScrollClock() when clock.id == scroll => clock.copyWith(
                id: id,
                sceneId: destScene.id,
              ),
              _ => clock.copyWith(id: id),
            });
            return id;
          }();
          rebind[clock.id] = copyId;
          incoming.add(t.copyWith(clockId: copyId));
        } else {
          incoming.add(t);
          diags.add(
            editWarning(
              IrDiagnosticKind.missingClock,
              'Track "${t.id}" moved to scene "${destScene.id}" but its '
              'clock "${t.clockId}" does not exist in scene "${scene.id}".',
              nodeId: t.target,
            ),
          );
        }
      }
      rw.sceneEdits[si] = (s) => s.copyWith(tracks: _shiftTracks(kept, deltas));
    });
    if (destScene != null && incoming.isNotEmpty) {
      final destTrackIds = {for (final t in destScene.tracks) t.id};
      for (final t in incoming) {
        if (destTrackIds.contains(t.id)) {
          diags.add(
            editWarning(
              IrDiagnosticKind.duplicateId,
              'Track id "${t.id}" now appears twice in scene '
              '"${destScene.id}".',
            ),
          );
        }
      }
    }
  }
  // Same-scene x/y tracks of nodes whose position was converted, and the
  // destination's new tracks and clocks.
  if (deltas.isNotEmpty || incoming.isNotEmpty || newClocks.isNotEmpty) {
    final scenes = <int>{
      ?dest,
      for (final id in deltas.keys) ?top[id]!.sceneIndex,
    };
    for (final si in scenes) {
      final prior = rw.sceneEdits[si];
      rw.sceneEdits[si] = (s) {
        var next = prior == null ? s : prior(s);
        if (si == dest && (incoming.isNotEmpty || newClocks.isNotEmpty)) {
          next = next.copyWith(
            tracks: [...next.tracks, ...incoming],
            clocks: [...next.clocks, ...newClocks],
          );
        }
        if (prior != null && si != dest) return next; // already shifted
        final shifted = _shiftTracks(next.tracks, deltas);
        return identical(shifted, next.tracks)
            ? next
            : next.copyWith(tracks: shifted);
      };
    }
  }

  final moved = [
    for (final id in ordered)
      _rebindClocks(_shift(idx.node(id)!, deltas[id]), rebind),
  ];
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
  final out = rw.apply();
  return EditResult(
    document: out,
    changed: !identical(out, doc),
    diagnostics: diags,
    cascade: EditCascade(clockIdMap: clockIdMap),
  );
}

/// A change of stored geometry that keeps a node's visual position.
class _GeometryDelta {
  const _GeometryDelta(this.dx, this.dy, this.dw, this.dh);

  final double dx, dy, dw, dh;

  bool get isZero => dx == 0 && dy == 0 && dw == 0 && dh == 0;

  double of(String path) => switch (path) {
    'x' => dx,
    'y' => dy,
    'width' => dw,
    'height' => dh,
    _ => 0,
  };
}

/// Boxes and reference sizes for `moveNodes` at one breakpoint.
class _MoveGeometry {
  _MoveGeometry(this.doc, this.index, String? breakpointId, this.boxes)
    : breakpoint = _pickBreakpoint(doc, breakpointId) {
    final bp = breakpoint;
    chain = bp == null
        ? const []
        : breakpointChain(doc.breakpoints, bp.id).chain;
  }

  final StageDocument doc;
  final DocumentIndex index;
  final Map<String, StageRect> boxes;
  final Breakpoint? breakpoint;
  late final List<Breakpoint> chain;
  final Map<String, StageRect?> _derived = {};

  static Breakpoint? _pickBreakpoint(StageDocument doc, String? id) {
    if (id != null) {
      for (final b in doc.breakpoints) {
        if (b.id == id) return b;
      }
    }
    for (final b in doc.breakpoints) {
      if (b.primary) return b;
    }
    return doc.breakpoints.isEmpty ? null : doc.breakpoints.first;
  }

  /// [n]'s common properties as [breakpoint] sees them.
  NodeCommon seen(Node n) {
    var out = n;
    for (final b in chain) {
      final p = n.common.breakpointOverrides[b.id];
      if (p != null) out = applyPatch(out, p);
    }
    return out.common;
  }

  /// The reference size children of frame [id] are designed against.
  StageSize reference(String id) {
    final loc = index.locate(id)!;
    final c = seen(index.node(id)!);
    if (!loc.isRoot || loc.inOverlay) {
      return StageSize(width: c.width, height: c.height);
    }
    final scene = doc.scenes[loc.sceneIndex!];
    final design = breakpoint?.designSize;
    if (design == null) return StageSize(width: c.width, height: c.height);
    return scene.kind == SceneKind.pinned
        ? design
        : StageSize(width: design.width, height: c.height);
  }

  /// The box of [id] in its scene root's space, or null when only auto
  /// layout knows it.
  StageRect? box(String id) => boxes[id] ?? _derive(id);

  StageRect? _derive(String id) {
    if (_derived.containsKey(id)) return _derived[id];
    final loc = index.locate(id)!;
    StageRect? out;
    if (loc.isRoot) {
      final r = reference(id);
      out = StageRect(width: r.width, height: r.height);
    } else {
      final parentId = loc.parentId!;
      final parent = index.node(parentId)! as FrameNode;
      final node = index.node(id)!;
      final flows =
          parent.grid != null ||
          (parent.autoLayout != null &&
              node.common.layoutChild.positioning == Positioning.auto);
      final pb = flows ? null : box(parentId);
      if (pb != null) {
        final c = seen(node);
        out = StageRect(
          x: pb.x + c.x,
          y: pb.y + c.y,
          width: c.width,
          height: c.height,
        );
      }
    }
    return _derived[id] = out;
  }

  /// The stored-geometry change that keeps [id]'s box when it moves into
  /// [parentId], or null when a box is unknown.
  _GeometryDelta? delta(String id, String parentId) {
    final b = box(id), pb = box(parentId);
    if (b == null || pb == null) return null;
    final node = index.node(id)!;
    final c = seen(node);
    final lc = c.layoutChild;
    final r = reference(parentId);
    final hugX =
        (node is FrameNode &&
            node.autoLayout != null &&
            lc.horizontalSizing == Sizing.hug) ||
        (node is TextNode && node.autoResize == TextAutoResize.widthAndHeight);
    final hugY =
        (node is FrameNode &&
            node.autoLayout != null &&
            lc.verticalSizing == Sizing.hug) ||
        (node is TextNode &&
            (node.autoResize == TextAutoResize.widthAndHeight ||
                node.autoResize == TextAutoResize.height));
    final h = inverseResolveAxisConstraint(
      constraint: horizontalAxisConstraint(lc.constraints.horizontal),
      offset: b.x - pb.x,
      size: b.width,
      reference: r.width,
      parent: pb.width,
      min: lc.minWidth,
      max: lc.maxWidth,
      contentSize: hugX ? b.width : null,
    );
    final v = inverseResolveAxisConstraint(
      constraint: verticalAxisConstraint(lc.constraints.vertical),
      offset: b.y - pb.y,
      size: b.height,
      reference: r.height,
      parent: pb.height,
      min: lc.minHeight,
      max: lc.maxHeight,
      contentSize: hugY ? b.height : null,
    );
    return _GeometryDelta(
      h.position - c.x,
      v.position - c.y,
      h.size - c.width,
      v.size - c.height,
    );
  }
}

/// [n] with [d] added to its base geometry and numeric geometry patches.
Node _shift(Node n, _GeometryDelta? d) {
  if (d == null) return n;
  final c = n.common;
  final patches = {
    for (final MapEntry(key: bp, value: p) in c.breakpointOverrides.entries)
      bp: {
        for (final MapEntry(key: path, :value) in p.entries)
          path: value is NumberValue && d.of(path) != 0
              ? IrValue.number(value.value + d.of(path))
              : value,
      },
  };
  return n.copyWith(
    common: c.copyWith(
      x: c.x + d.dx,
      y: c.y + d.dy,
      width: c.width + d.dw,
      height: c.height + d.dh,
      breakpointOverrides: patches,
    ),
  );
}

/// [tracks] with the `x`/`y` keyframes of nodes in [deltas] shifted, or
/// [tracks] itself when none is affected.
List<Track> _shiftTracks(
  List<Track> tracks,
  Map<String, _GeometryDelta> deltas,
) {
  if (deltas.isEmpty) return tracks;
  var changed = false;
  final out = [
    for (final t in tracks)
      if (deltas[t.target] case final d?
          when (t.property == 'x' || t.property == 'y') &&
              d.of(t.property) != 0)
        () {
          changed = true;
          final by = d.of(t.property);
          return t.copyWith(
            keyframes: [
              for (final k in t.keyframes)
                if (k.value case NumberValue(:final value))
                  k.copyWith(value: IrValue.number(value + by))
                else
                  k,
            ],
          );
        }()
      else
        t,
  ];
  return changed ? out : tracks;
}

/// [n]'s subtree with clock references in [map] rebound; [n] itself when
/// nothing refers to them.
Node _rebindClocks(Node n, Map<String, String> map) {
  if (map.isEmpty) return n;
  String re(String id) => map[id] ?? id;
  final c = n.common;
  var interactions = c.interactions;
  if (c.interactions.any(
    (i) =>
        (i.trigger is ClockReachTrigger &&
            map.containsKey((i.trigger as ClockReachTrigger).clockId)) ||
        i.actions.any((a) => map.containsKey(_actionClock(a))),
  )) {
    interactions = [
      for (final i in c.interactions)
        i.copyWith(
          trigger: switch (i.trigger) {
            ClockReachTrigger(:final clockId, :final value) =>
              InteractionTrigger.clockReach(clockId: re(clockId), value: value),
            final t => t,
          },
          actions: [
            for (final a in i.actions)
              switch (a) {
                PlayTimelineAction(:final clockId) => Action.playTimeline(
                  clockId: re(clockId),
                ),
                PauseTimelineAction(:final clockId) => Action.pauseTimeline(
                  clockId: re(clockId),
                ),
                ReverseTimelineAction(:final clockId) => Action.reverseTimeline(
                  clockId: re(clockId),
                ),
                SeekTimelineAction(:final clockId, :final time) =>
                  Action.seekTimeline(clockId: re(clockId), time: time),
                _ => a,
              },
          ],
        ),
    ];
  }
  final common = identical(interactions, c.interactions)
      ? c
      : c.copyWith(interactions: interactions);
  switch (n) {
    case FrameNode():
      final kids = [for (final k in n.children) _rebindClocks(k, map)];
      final behavior = switch (n.behavior) {
        TextRevealBehavior(:final clockId) && final b
            when map.containsKey(clockId) =>
          b.copyWith(clockId: re(clockId)),
        final b => b,
      };
      if (identical(common, c) &&
          identical(behavior, n.behavior) &&
          sameElements(kids, n.children)) {
        return n;
      }
      return n.copyWith(common: common, children: kids, behavior: behavior);
    case EmbedNode() when n.inputBindings.values.any(map.containsKey):
      return n.copyWith(
        common: common,
        inputBindings: {
          for (final MapEntry(:key, :value) in n.inputBindings.entries)
            key: re(value),
        },
      );
    default:
      return identical(common, c) ? n : n.copyWith(common: common);
  }
}

String? _actionClock(Action a) => switch (a) {
  PlayTimelineAction(:final clockId) ||
  PauseTimelineAction(:final clockId) ||
  SeekTimelineAction(:final clockId) ||
  ReverseTimelineAction(:final clockId) => clockId,
  _ => null,
};

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

/// The node a pointer or behaviour clock is bound to, or null.
String? _clockNodeRef(Clock c) => switch (c) {
  PointerClock(:final frameId) => frameId,
  BehaviorClock(:final nodeId) => nodeId,
  _ => null,
};

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
