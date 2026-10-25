import 'dart:math' as math;

import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/command.dart';
import '../core/commands/motion_commands.dart';
import '../core/editor_controller.dart';
import '../core/editor_state.dart';
import 'timeline_math.dart';
import 'timeline_model.dart';

// Keyframe edits of the timeline panel (m2.md "Timeline lanes"): delete,
// arrow nudge, copy and paste at the playhead, select all. Each is one
// command (one undo step); the keyframe selection follows.

/// A command from an edit function (the timeline's composite edits).
class TimelineEdit extends EditCommand {
  TimelineEdit(this.label, this.edit, {this.coalesceKey});

  @override
  final String label;

  @override
  final String? coalesceKey;

  final ir.EditResult Function(EditorState state) edit;

  @override
  CommandResult apply(EditorState state) =>
      resultOf(state, edit(state), label: label, coalesceKey: coalesceKey);
}

/// [refs] grouped by track (`trackId → keyframe ids`).
Map<String, Set<String>> keyframesByTrack(Iterable<KeyframeRef> refs) {
  final out = <String, Set<String>>{};
  for (final r in refs) {
    (out[r.track] ??= {}).add(r.keyframe);
  }
  return out;
}

/// The keyframe of [ref] in [scene], or null.
ir.Keyframe? keyframeOf(ir.Scene scene, KeyframeRef ref) {
  for (final t in scene.tracks) {
    if (t.id != ref.track) continue;
    for (final k in t.keyframes) {
      if (k.id == ref.keyframe) return k;
    }
  }
  return null;
}

/// The refs of [refs] that still exist in [scene].
Set<KeyframeRef> existingKeyframes(ir.Scene scene, Set<KeyframeRef> refs) => {
  for (final r in refs)
    if (keyframeOf(scene, r) != null) r,
};

/// The timeline's keyframe actions on an editor.
class TimelineActions {
  TimelineActions(this.editor, this.timeline, this.readState);

  final EditorController editor;
  final TimelineController timeline;

  /// Reads the editor state (`ref.read(editorControllerProvider)`).
  final EditorState Function() readState;

  EditorState get _st => readState();

  ({ir.Scene scene, ir.Clock clock, ClockSpan span})? _active() {
    final scene = _st.activeScene;
    final clockId = _st.activeClockId;
    if (scene == null || clockId == null) return null;
    final clock = scene.clocks.firstWhere((c) => c.id == clockId);
    return (
      scene: scene,
      clock: clock,
      span: clockSpan(_st.document, scene, clock),
    );
  }

  /// Delete / Backspace: removes the selected keyframes (and tracks left
  /// without any).
  bool deleteSelected() {
    final a = _active();
    final sel = timeline.selection.value;
    if (a == null || sel.isEmpty) return false;
    final r = editor.execute(
      RemoveKeyframes(
        a.scene.id,
        keyframesByTrack(existingKeyframes(a.scene, sel)),
      ),
    );
    if (r.ok) timeline.clearSelection();
    return r.ok;
  }

  /// Arrow keys: moves the selected keyframes by [direction] nudge steps
  /// (Shift: [big] steps), kept inside the clock's span.
  bool nudgeSelected(int direction, {bool big = false}) {
    final a = _active();
    if (a == null) return false;
    final sel = existingKeyframes(a.scene, timeline.selection.value);
    if (sel.isEmpty) return false;
    final times = [for (final r in sel) keyframeOf(a.scene, r)!.t];
    final delta = limitDelta(
      direction * nudgeStep(a.span.unit, big: big),
      times,
      a.span,
    );
    if (delta == 0) return true;
    final moves = <String, Map<String, double>>{};
    for (final r in sel) {
      (moves[r.track] ??= {})[r.keyframe] = keyframeOf(a.scene, r)!.t + delta;
    }
    editor.execute(_NudgeKeyframes(a.scene.id, moves));
    return true;
  }

  /// Cmd+C: copies the selected keyframes.
  bool copySelected() {
    final scene = _st.activeScene;
    if (scene == null) return false;
    final sel = existingKeyframes(scene, timeline.selection.value);
    if (sel.isEmpty) return false;
    timeline.clipboard = [
      for (final t in scene.tracks)
        for (final k in t.keyframes)
          if (sel.contains((track: t.id, keyframe: k.id)))
            CopiedKeyframe(
              trackId: t.id,
              target: t.target,
              property: t.property,
              keyframe: k,
            ),
    ];
    return true;
  }

  /// Cmd+V: pastes the copied keyframes at the playhead, keeping their
  /// relative times (the earliest lands on the playhead). Each goes to its
  /// own track when that track is on the active clock, else to the active
  /// clock's track of the same node and property; others are skipped. A
  /// pasted keyframe at the time of an existing one replaces its value and
  /// easing. The pasted keyframes become the selection.
  bool paste() {
    final a = _active();
    final clip = timeline.clipboard;
    if (a == null || clip.isEmpty) return false;
    final minT = clip.map((c) => c.keyframe.t).reduce(math.min);
    final playhead = _st.playhead;
    ir.Track? trackFor(CopiedKeyframe c) {
      for (final t in a.scene.tracks) {
        if (t.id == c.trackId && t.clockId == a.clock.id) return t;
      }
      for (final t in a.scene.tracks) {
        if (t.clockId == a.clock.id &&
            t.target == c.target &&
            t.property == c.property) {
          return t;
        }
      }
      return null;
    }

    final adds = <String, List<ir.Keyframe>>{};
    final updates = <String, Map<String, ir.Keyframe Function(ir.Keyframe)>>{};
    final pasted = <KeyframeRef>{};
    for (final c in clip) {
      final track = trackFor(c);
      if (track == null) continue;
      final t = a.span.clamp(playhead + (c.keyframe.t - minT));
      final at = track.keyframes
          .where((k) => (k.t - t).abs() <= ir.kKeyframeTimeEpsilon)
          .firstOrNull;
      if (at != null) {
        final value = c.keyframe.value, easing = c.keyframe.easing;
        (updates[track.id] ??= {})[at.id] = (k) =>
            k.copyWith(value: value, easing: easing);
        pasted.add((track: track.id, keyframe: at.id));
        continue;
      }
      final used = {
        for (final k in track.keyframes) k.id,
        for (final k in adds[track.id] ?? const <ir.Keyframe>[]) k.id,
      };
      final id = freshMotionId(used);
      (adds[track.id] ??= []).add(c.keyframe.copyWith(id: id, t: t));
      pasted.add((track: track.id, keyframe: id));
    }
    if (pasted.isEmpty) return false;
    final sceneId = a.scene.id;
    final n = pasted.length;
    final r = editor.execute(
      TimelineEdit('Paste ${n == 1 ? 'keyframe' : '$n keyframes'}', (st) {
        var doc = st.document;
        if (adds.isNotEmpty) {
          final r = ir.addKeyframes(doc, sceneId, adds);
          if (!r.ok) return r;
          doc = r.document;
        }
        if (updates.isNotEmpty) {
          final r = ir.updateKeyframes(doc, sceneId, updates);
          if (!r.ok) return r.copyWith(document: st.document);
          doc = r.document;
        }
        return ir.EditResult(
          document: doc,
          changed: !identical(doc, st.document),
        );
      }),
    );
    if (r.ok) timeline.select(pasted);
    return r.ok;
  }

  /// Cmd+A: selects every keyframe on the active clock.
  bool selectAll() {
    final a = _active();
    if (a == null) return false;
    timeline.select({
      for (final t in a.scene.tracks)
        if (t.clockId == a.clock.id)
          for (final k in t.keyframes) (track: t.id, keyframe: k.id),
    });
    return true;
  }
}

/// A keyframe nudge (arrow keys): one undo step per press.
class _NudgeKeyframes extends EditCommand {
  _NudgeKeyframes(this.sceneId, this.times);

  final String sceneId;
  final Map<String, Map<String, double>> times;

  @override
  String get label {
    final n = times.values.fold(0, (s, m) => s + m.length);
    return 'Nudge ${n == 1 ? 'keyframe' : '$n keyframes'}';
  }

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.moveKeyframes(state.document, sceneId, times),
    label: label,
  );
}
