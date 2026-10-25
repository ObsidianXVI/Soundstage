import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/editor_controller.dart';
import 'timeline_math.dart';

// The timeline's model (m2.md "Timeline lanes"): the rows of the active
// clock's tracks grouped by node, and the per-editor timeline state that is
// not the document (view, keyframe selection, collapsed groups, transport,
// the keyframe clipboard).

/// A keyframe of the active scene: track id plus keyframe id.
typedef KeyframeRef = ({String track, String keyframe});

/// A segment of a track: the keyframe that starts it (the segment runs to
/// the next keyframe in time).
typedef SegmentRef = KeyframeRef;

/// One row of the lanes list.
sealed class TimelineRow {
  const TimelineRow(this.nodeId);

  /// The node the row belongs to (its group's node).
  final String nodeId;
}

/// A node's group header: the node's name; collapsible.
final class GroupRow extends TimelineRow {
  const GroupRow(
    super.nodeId, {
    required this.name,
    required this.tracks,
    required this.collapsed,
  });

  final String name;

  /// The group's tracks, in lane order (for the summary diamonds).
  final List<ir.Track> tracks;
  final bool collapsed;

  /// Whether [other] shows the same thing (same name, state and tracks by
  /// identity), so the previous row object can be kept.
  bool sameAs(GroupRow other) {
    if (other.nodeId != nodeId ||
        other.name != name ||
        other.collapsed != collapsed ||
        other.tracks.length != tracks.length) {
      return false;
    }
    for (var i = 0; i < tracks.length; i++) {
      if (!identical(other.tracks[i], tracks[i])) return false;
    }
    return true;
  }
}

/// One animated property of a node: a track and its keyframes.
final class LaneRow extends TimelineRow {
  const LaneRow(super.nodeId, {required this.track, required this.label});

  final ir.Track track;

  /// The registry's display name, plus the breakpoint for a
  /// breakpoint-specific track ("Opacity · Mobile").
  final String label;

  /// Whether [other] shows the same thing (see [GroupRow.sameAs]).
  bool sameAs(LaneRow other) =>
      other.nodeId == nodeId &&
      identical(other.track, track) &&
      other.label == label;
}

/// [next] with every row that shows the same as a row of [previous]
/// replaced by that previous object, so unchanged rows keep their identity
/// (and their widgets skip rebuilding) across edits.
List<TimelineRow> reuseTimelineRows(
  List<TimelineRow> previous,
  List<TimelineRow> next,
) {
  if (previous.isEmpty) return next;
  final groups = <String, GroupRow>{};
  final lanes = <String, LaneRow>{};
  for (final r in previous) {
    switch (r) {
      case GroupRow():
        groups[r.nodeId] = r;
      case LaneRow():
        lanes[r.track.id] = r;
    }
  }
  return [
    for (final r in next)
      switch (r) {
        GroupRow() =>
          (groups[r.nodeId]?.sameAs(r) ?? false) ? groups[r.nodeId]! : r,
        LaneRow() =>
          (lanes[r.track.id]?.sameAs(r) ?? false) ? lanes[r.track.id]! : r,
      },
  ];
}

/// The name of node [id] (authored, or `<instance> / <inner>` inside an
/// instance), falling back to its id.
String timelineNodeName(ir.DocumentIndex index, String id) {
  String nameOf(String nodeId) {
    final n = index.node(nodeId);
    final name = n?.common.name ?? '';
    return name.isEmpty ? nodeId : name;
  }

  final slash = id.indexOf('/');
  if (slash < 0) return nameOf(id);
  return '${nameOf(id.substring(0, slash))} / ${id.substring(slash + 1)}';
}

/// The lane label of [track]: the registry's display name of its property,
/// plus the breakpoints of a breakpoint-specific track.
String laneLabel(ir.StageDocument doc, ir.Track track) {
  final name =
      ir.PropertyRegistry.standard.lookup(track.property)?.displayName ??
      track.property;
  final only = track.breakpoints;
  if (only == null) return name;
  final names = [
    for (final id in only)
      doc.breakpoints.where((b) => b.id == id).firstOrNull?.name ?? id,
  ];
  return '$name · ${names.join(', ')}';
}

/// The rows of [scene]'s tracks on clock [clockId]: a group per node in
/// tree order (pre-order; instance inner targets after their instance),
/// then one lane per track, in the scene's track order. A collapsed group
/// ([collapsed] node ids) shows its header only.
List<TimelineRow> buildTimelineRows(
  ir.StageDocument doc,
  ir.Scene scene,
  String clockId, {
  Set<String> collapsed = const {},
}) {
  final byNode = <String, List<ir.Track>>{};
  for (final t in scene.tracks) {
    if (t.clockId == clockId) (byNode[t.target] ??= []).add(t);
  }
  if (byNode.isEmpty) return const [];
  final order = _treeOrder(scene.root);
  int rank(String id) => order[id.split('/').first] ?? 1 << 30;
  final nodes = byNode.keys.toList()
    ..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      // An instance before its inner nodes, inner nodes by id.
      if (!a.contains('/')) return -1;
      if (!b.contains('/')) return 1;
      return a.compareTo(b);
    });
  final index = ir.DocumentIndex.of(doc);
  final rows = <TimelineRow>[];
  for (final id in nodes) {
    final tracks = byNode[id]!;
    final closed = collapsed.contains(id);
    rows.add(
      GroupRow(
        id,
        name: timelineNodeName(index, id),
        tracks: tracks,
        collapsed: closed,
      ),
    );
    if (closed) continue;
    for (final t in tracks) {
      rows.add(LaneRow(id, track: t, label: laneLabel(doc, t)));
    }
  }
  return rows;
}

final Expando<Map<String, int>> _orders = Expando('tree order');

/// Pre-order positions of the nodes under [root], memoised per root (track
/// edits keep the root, so they don't walk the tree again).
Map<String, int> _treeOrder(ir.FrameNode root) {
  final cached = _orders[root];
  if (cached != null) return cached;
  final order = <String, int>{};
  var i = 0;
  void walk(ir.Node n) {
    order[n.id] = i++;
    if (n is ir.FrameNode) n.children.forEach(walk);
  }

  walk(root);
  return _orders[root] = order;
}

/// A keyframe on the timeline clipboard: where it came from and what it
/// holds. Pasting finds the track by id, else by target and property.
@immutable
class CopiedKeyframe {
  const CopiedKeyframe({
    required this.trackId,
    required this.target,
    required this.property,
    required this.keyframe,
  });

  final String trackId;
  final String target;
  final String property;
  final ir.Keyframe keyframe;
}

/// The timeline's per-editor view state (not the document, not undoable):
///
/// - [views]: the horizontal zoom and pan per scene and clock;
/// - [selection]: the selected keyframes of the active scene;
/// - [collapsed]: collapsed node groups;
/// - [playing] / [loops]: transport; loops per clock (default: the
///   timeline clock's own loop setting);
/// - [easingSegment]: the segment whose easing is being looked at (the hook
///   T2.3's easing editor opens from);
/// - [snapGuide]: the time a drag is snapped to, drawn as a guide;
/// - [clipboard]: copied keyframes (Cmd+C / Cmd+V).
///
/// Each part is its own notifier, so a keyframe selection repaints the lanes
/// only, and a view change repaints the lanes and the ruler only.
class TimelineController {
  final ValueNotifier<Map<String, TimelineView>> views = ValueNotifier(
    const {},
  );
  final ValueNotifier<Set<KeyframeRef>> selection = ValueNotifier(const {});
  final ValueNotifier<Set<String>> collapsed = ValueNotifier(const {});
  final ValueNotifier<bool> playing = ValueNotifier(false);
  final ValueNotifier<Map<String, bool>> loops = ValueNotifier(const {});
  final ValueNotifier<SegmentRef?> easingSegment = ValueNotifier(null);
  final ValueNotifier<double?> snapGuide = ValueNotifier(null);
  List<CopiedKeyframe> clipboard = const [];

  /// The key of a view: scene and clock.
  static String viewKey(String sceneId, String clockId) => '$sceneId/$clockId';

  /// The view of [key], or [fallback] (stored) when there is none yet.
  TimelineView viewOf(String key, TimelineView Function() fallback) {
    final v = views.value[key];
    if (v != null) return v;
    final f = fallback();
    views.value = {...views.value, key: f};
    return f;
  }

  void setView(String key, TimelineView view) {
    if (views.value[key] == view) return;
    views.value = {...views.value, key: view};
  }

  void select(Set<KeyframeRef> refs) {
    if (setEquals(refs, selection.value)) return;
    selection.value = Set.unmodifiable(refs);
  }

  void clearSelection() => select(const {});

  void toggleGroup(String nodeId) {
    final c = collapsed.value;
    collapsed.value = c.contains(nodeId)
        ? (Set.of(c)..remove(nodeId))
        : {...c, nodeId};
  }

  /// Whether transport loops on clock [clock] (see [loops]).
  bool loopsOn(ir.Clock clock) =>
      loops.value[clock.id] ??
      (clock is ir.TimelineClock && clock.loop != ir.TimelineLoop.none);

  void setLoop(String clockId, bool on) =>
      loops.value = {...loops.value, clockId: on};

  void dispose() {
    views.dispose();
    selection.dispose();
    collapsed.dispose();
    playing.dispose();
    loops.dispose();
    easingSegment.dispose();
    snapGuide.dispose();
  }
}

/// The timeline state of one editor (scoped like the canvas controller).
final timelineControllerProvider = Provider<TimelineController>((ref) {
  ref.watch(initialDocumentProvider);
  final c = TimelineController();
  ref.onDispose(c.dispose);
  return c;
}, dependencies: [initialDocumentProvider]);

// ---- Structure (T2.1-6) ------------------------------------------------------------

final Expando<Map<String, ir.Track>> _tracksById = Expando('tracks by id');

/// The track [id] of [scene] (looked up through a per-scene map, so a
/// lookup is O(1) while the scene object is unchanged: row tiles select
/// their own track on every state change, scrubbing included).
ir.Track? trackById(ir.Scene? scene, String id) {
  if (scene == null) return null;
  final byId = _tracksById[scene] ??= {for (final t in scene.tracks) t.id: t};
  return byId[id];
}

/// The rows of a scene on a clock, memoised per scene object.
class _RowsMemo {
  _RowsMemo(this.clockId, this.collapsed, this.breakpoints, this.rows);

  final String clockId;
  final Set<String> collapsed;
  final List<ir.Breakpoint> breakpoints;
  final List<TimelineRow> rows;
}

final Expando<_RowsMemo> _rowsMemo = Expando('timeline rows');

/// [buildTimelineRows], memoised per scene object, clock, collapsed groups
/// and breakpoints (their names label breakpoint-specific lanes).
List<TimelineRow> timelineRowsFor(
  ir.StageDocument doc,
  ir.Scene scene,
  String clockId, {
  Set<String> collapsed = const {},
}) {
  final m = _rowsMemo[scene];
  if (m != null &&
      m.clockId == clockId &&
      setEquals(m.collapsed, collapsed) &&
      listEquals(m.breakpoints, doc.breakpoints)) {
    return m.rows;
  }
  final rows = buildTimelineRows(doc, scene, clockId, collapsed: collapsed);
  _rowsMemo[scene] = _RowsMemo(clockId, collapsed, doc.breakpoints, rows);
  return rows;
}

/// What the lane list is made of: the scene, the clock and the rows' shape
/// (groups, lanes, names, labels, collapse), but not the keyframes. Equal
/// across keyframe edits, so those don't rebuild the list; each row tile
/// watches its own tracks.
@immutable
class TimelineStructure {
  const TimelineStructure(this.sceneId, this.clock, this.rows);

  final String sceneId;
  final ir.Clock clock;

  /// The rows as last built (their tracks may be older than the document's;
  /// read current tracks with [trackById]).
  final List<TimelineRow> rows;

  static bool _sameShape(TimelineRow a, TimelineRow b) => switch ((a, b)) {
    (final GroupRow x, final GroupRow y) =>
      x.nodeId == y.nodeId &&
          x.name == y.name &&
          x.collapsed == y.collapsed &&
          listEquals(
            [for (final t in x.tracks) t.id],
            [for (final t in y.tracks) t.id],
          ),
    (final LaneRow x, final LaneRow y) =>
      x.nodeId == y.nodeId && x.track.id == y.track.id && x.label == y.label,
    _ => false,
  };

  @override
  bool operator ==(Object other) {
    if (other is! TimelineStructure ||
        other.sceneId != sceneId ||
        other.clock != clock ||
        other.rows.length != rows.length) {
      return false;
    }
    if (identical(other.rows, rows)) return true;
    for (var i = 0; i < rows.length; i++) {
      if (!_sameShape(rows[i], other.rows[i])) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(sceneId, clock.id, rows.length);
}

/// The lane structure of scene [sceneId] on clock [clockId], or null when
/// either is missing.
TimelineStructure? timelineStructureOf(
  ir.StageDocument doc,
  String? sceneId,
  String? clockId, {
  Set<String> collapsed = const {},
}) {
  ir.Scene? scene;
  for (final s in doc.scenes) {
    if (s.id == sceneId) scene = s;
  }
  if (scene == null || clockId == null) return null;
  ir.Clock? clock;
  for (final c in scene.clocks) {
    if (c.id == clockId) clock = c;
  }
  if (clock == null) return null;
  return TimelineStructure(
    scene.id,
    clock,
    timelineRowsFor(doc, scene, clockId, collapsed: collapsed),
  );
}
