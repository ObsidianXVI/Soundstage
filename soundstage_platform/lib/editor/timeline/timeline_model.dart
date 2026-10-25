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
    required this.trackIds,
    required this.collapsed,
  });

  final String name;

  /// The group's tracks, in lane order (for the summary diamonds).
  final List<String> trackIds;
  final bool collapsed;
}

/// One animated property of a node: a track and its keyframes.
final class LaneRow extends TimelineRow {
  const LaneRow(super.nodeId, {required this.track, required this.label});

  final ir.Track track;

  /// The registry's display name, plus the breakpoint for a
  /// breakpoint-specific track ("Opacity · Mobile").
  final String label;
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
  final order = <String, int>{};
  var i = 0;
  void walk(ir.Node n) {
    order[n.id] = i++;
    if (n is ir.FrameNode) n.children.forEach(walk);
  }

  walk(scene.root);
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
        trackIds: [for (final t in tracks) t.id],
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
