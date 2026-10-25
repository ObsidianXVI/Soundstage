import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Motion commands (architecture §10, §15.1; m2.md): one command per motion
// edit helper. Playhead changes are not commands (they are view state, see
// `EditorController.setPlayhead`).
//
// Keyframe drags coalesce: `MoveKeyframes` takes absolute times (the drag
// computes them from the gesture's start), and every step of one drag has
// the same coalescing key, so the drag undoes in one step.

/// A new id not in [used]. Track ids only need to be unique in their scene
/// and keyframe ids in their track, so this avoids the document-wide
/// reservation of `IdGenerator.forDocument` (a JSON walk of the whole
/// story), which per-step auto-key writes can't afford.
String freshMotionId(Set<String> used, [ir.IdGenerator? ids]) {
  final gen = ids ?? ir.IdGenerator();
  while (true) {
    final id = gen.next();
    if (!used.contains(id)) return id;
  }
}

/// The ids of every track of scene [sceneId] in [doc].
Set<String> trackIdsOf(ir.StageDocument doc, String sceneId) {
  for (final s in doc.scenes) {
    if (s.id == sceneId) return {for (final t in s.tracks) t.id};
  }
  return const {};
}

String _sorted(Iterable<String> ids) => (ids.toList()..sort()).join(',');

String _keyframesKey(Map<String, Iterable<String>> byTrack) => _sorted([
  for (final e in byTrack.entries)
    for (final k in e.value) '${e.key}/$k',
]);

String _kfLabel(int n, String verb) =>
    '$verb ${n == 1 ? 'keyframe' : '$n keyframes'}';

int _count(Map<String, Iterable<Object?>> byTrack) =>
    byTrack.values.fold(0, (n, l) => n + l.length);

// ---- Tracks ---------------------------------------------------------------------

/// Adds [track] to scene [sceneId] (see `ir.addTrack`).
class AddTrack extends EditCommand {
  const AddTrack(this.sceneId, this.track);

  final String sceneId;
  final ir.Track track;

  @override
  String get label => 'Animate ${track.property}';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.addTrack(state.document, sceneId, track),
    label: label,
  );
}

/// Replaces track [trackId] by `change(track)` (see `ir.updateTrack`).
class UpdateTrack extends EditCommand {
  const UpdateTrack(
    this.sceneId,
    this.trackId,
    this.change, {
    this.label = 'Change track',
  });

  final String sceneId;
  final String trackId;
  final ir.Track Function(ir.Track track) change;

  @override
  final String label;

  @override
  String get coalesceKey => 'track:$sceneId:$trackId';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateTrack(state.document, sceneId, trackId, change),
    label: label,
    coalesceKey: coalesceKey,
  );
}

/// Removes tracks (see `ir.removeTracks`).
class RemoveTracks extends EditCommand {
  const RemoveTracks(this.sceneId, this.trackIds);

  final String sceneId;
  final List<String> trackIds;

  @override
  String get label => trackIds.length == 1
      ? 'Delete track'
      : 'Delete ${trackIds.length} tracks';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.removeTracks(state.document, sceneId, trackIds),
    label: label,
  );
}

/// Moves tracks onto another clock of their scene (see
/// `ir.moveTracksToClock`).
class MoveTracksToClock extends EditCommand {
  const MoveTracksToClock(this.sceneId, this.trackIds, this.clockId);

  final String sceneId;
  final List<String> trackIds;
  final String clockId;

  @override
  String get label => 'Change clock';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.moveTracksToClock(state.document, sceneId, trackIds, clockId),
    label: label,
  );
}

// ---- Keyframes ------------------------------------------------------------------

/// Adds keyframes (`byTrack[trackId]`; see `ir.addKeyframes`). Pasting at
/// the playhead and Alt-drag duplicates build on this.
class AddKeyframes extends EditCommand {
  const AddKeyframes(this.sceneId, this.byTrack);

  final String sceneId;
  final Map<String, List<ir.Keyframe>> byTrack;

  @override
  String get label => _kfLabel(_count(byTrack), 'Add');

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.addKeyframes(state.document, sceneId, byTrack),
    label: label,
  );
}

/// Writes [value] at time [t] (default: the playhead of the track's clock)
/// on track [trackId]: the inspector's keyframe toggle (◇) and writes to
/// an animated property. Replaces the keyframe at that time, else adds one.
class WriteKeyframe extends EditCommand {
  const WriteKeyframe(
    this.sceneId,
    this.trackId,
    this.value, {
    this.t,
    this.ids,
  });

  final String sceneId;
  final String trackId;
  final ir.IrValue value;
  final double? t;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Set keyframe';

  @override
  String get coalesceKey => 'kfwrite:$sceneId:$trackId';

  @override
  CommandResult apply(EditorState state) {
    final track = _track(state.document, sceneId, trackId);
    if (track == null) {
      return failedCommand(state, label, [
        commandError('Track "$trackId" does not exist.'),
      ]);
    }
    return resultOf(
      state,
      ir.writeKeyframeAt(
        state.document,
        sceneId,
        trackId,
        t: t ?? state.playheadOf(sceneId, track.clockId),
        value: value,
        newId: freshMotionId({for (final k in track.keyframes) k.id}, ids),
      ),
      label: label,
      coalesceKey: coalesceKey,
    );
  }
}

/// Moves keyframes to absolute times (`times[trackId][keyframeId]`; see
/// `ir.moveKeyframes`). Every step of one drag coalesces into one undo
/// entry (same keyframes, same key).
class MoveKeyframes extends EditCommand {
  const MoveKeyframes(this.sceneId, this.times);

  final String sceneId;
  final Map<String, Map<String, double>> times;

  @override
  String get label =>
      _kfLabel(_count(times.map((k, v) => MapEntry(k, v.keys))), 'Move');

  @override
  String get coalesceKey =>
      'kfmove:$sceneId:${_keyframesKey(times.map((k, v) => MapEntry(k, v.keys)))}';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.moveKeyframes(state.document, sceneId, times),
    label: label,
    coalesceKey: coalesceKey,
  );
}

/// Replaces keyframes (`changes[trackId][keyframeId]`; see
/// `ir.updateKeyframes`): value edits, nudges.
class UpdateKeyframes extends EditCommand {
  const UpdateKeyframes(
    this.sceneId,
    this.changes, {
    this.label = 'Change keyframe',
  });

  final String sceneId;
  final Map<String, Map<String, ir.Keyframe Function(ir.Keyframe)>> changes;

  @override
  final String label;

  @override
  String get coalesceKey =>
      'kfupdate:$sceneId:${_keyframesKey(changes.map((k, v) => MapEntry(k, v.keys)))}';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateKeyframes(state.document, sceneId, changes),
    label: label,
    coalesceKey: coalesceKey,
  );
}

/// Removes keyframes (and tracks with their last keyframe; see
/// `ir.removeKeyframes`).
class RemoveKeyframes extends EditCommand {
  const RemoveKeyframes(this.sceneId, this.byTrack);

  final String sceneId;
  final Map<String, Set<String>> byTrack;

  @override
  String get label => _kfLabel(_count(byTrack), 'Delete');

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.removeKeyframes(state.document, sceneId, byTrack),
    label: label,
  );
}

/// Sets [easing] on segments (`segments[trackId]` = the keyframes starting
/// them; see `ir.setSegmentEasing`). An easing editor's handle drag
/// coalesces.
class SetSegmentEasing extends EditCommand {
  const SetSegmentEasing(this.sceneId, this.segments, this.easing);

  final String sceneId;
  final Map<String, Set<String>> segments;
  final ir.Easing easing;

  @override
  String get label => 'Change easing';

  @override
  String get coalesceKey => 'easing:$sceneId:${_keyframesKey(segments)}';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.setSegmentEasing(state.document, sceneId, segments, easing),
    label: label,
    coalesceKey: coalesceKey,
  );
}

// ---- Clocks ---------------------------------------------------------------------

/// Adds [clock] to scene [sceneId] (see `ir.addClock`).
class AddClock extends EditCommand {
  const AddClock(this.sceneId, this.clock);

  final String sceneId;
  final ir.Clock clock;

  @override
  String get label => 'Add clock';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.addClock(state.document, sceneId, clock),
    label: label,
  );
}

/// Replaces clock [clockId] by `change(clock)` (see `ir.updateClock`).
/// Field scrubs coalesce.
class UpdateClock extends EditCommand {
  const UpdateClock(this.sceneId, this.clockId, this.change);

  final String sceneId;
  final String clockId;
  final ir.Clock Function(ir.Clock clock) change;

  @override
  String get label => 'Change clock';

  @override
  String get coalesceKey => 'clock:$sceneId:$clockId';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateClock(state.document, sceneId, clockId, change),
    label: label,
    coalesceKey: coalesceKey,
  );
}

/// Removes clock [clockId], deleting its tracks or moving them to another
/// clock ([tracks]; see `ir.removeClock`). The editor asks which when
/// tracks use the clock (m2.md "Clocks UI").
class RemoveClock extends EditCommand {
  const RemoveClock(
    this.sceneId,
    this.clockId, {
    this.tracks = const ir.ClockRemoval.deleteTracks(),
  });

  final String sceneId;
  final String clockId;
  final ir.ClockRemoval tracks;

  @override
  String get label => 'Delete clock';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.removeClock(state.document, sceneId, clockId, tracks: tracks),
    label: label,
  );
}

ir.Track? _track(ir.StageDocument doc, String sceneId, String trackId) {
  for (final s in doc.scenes) {
    if (s.id != sceneId) continue;
    for (final t in s.tracks) {
      if (t.id == trackId) return t;
    }
  }
  return null;
}
