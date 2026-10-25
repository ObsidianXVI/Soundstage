import '../behaviors.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../interactions.dart';
import '../motion.dart';
import '../nodes/node.dart';
import '../registry/property_descriptor.dart';
import '../registry/property_registry.dart';
import '../scene.dart';
import '../validate/validate.dart' show hasErrors;
import '../values/ir_value.dart';
import 'document_index.dart';
import 'edit_core.dart';
import 'edit_result.dart';

// Pure motion edits (architecture §10, m2.md "Keyframe semantics"): tracks,
// keyframes, segment easing and scene clocks.
//
// - Path copy: an edit copies the document, the edited scene and the edited
//   tracks only. Every other scene, track, keyframe and clock keeps its
//   identity, and the scene's node tree is never touched.
// - Atomic: an error leaves the document unchanged (see [EditResult]).
// - Keyframes are stored sorted by `t` (ties keep their order). Keyframe ids
//   are supplied by the caller and stay stable across moves and updates.
// - A track is created by its first keyframe and deleted with its last: an
//   edit that leaves a track without keyframes removes it, listed in
//   `cascade.removedTrackIds`.
// - Referential integrity: a track's `clockId` is a clock of its scene, its
//   `target` is a node of that scene (or `<instanceId>/<innerPath>` under an
//   instance of that scene), its `property` is registered, animatable and
//   applies to the target's kind, its keyframe values fit the property, and
//   its `breakpoints` exist.

/// Keyframes within this distance in clock units are "at the same time"
/// ([writeKeyframeAt]).
const double kKeyframeTimeEpsilon = 1e-9;

/// What [removeClock] does with the tracks that run on the removed clock.
sealed class ClockRemoval {
  const ClockRemoval();

  /// Removes the clock's tracks with it.
  const factory ClockRemoval.deleteTracks() = DeleteClockTracks;

  /// Moves the clock's tracks to clock [clockId] of the same scene.
  const factory ClockRemoval.moveTracksTo(String clockId) = MoveClockTracks;
}

final class DeleteClockTracks extends ClockRemoval {
  const DeleteClockTracks();
}

final class MoveClockTracks extends ClockRemoval {
  const MoveClockTracks(this.clockId);
  final String clockId;
}

// ---- Tracks ---------------------------------------------------------------------

/// Adds [track] to scene [sceneId]. It needs at least one keyframe (a track
/// is created by its first keyframe), a new id within the scene, and must
/// pass the integrity checks above. Keyframes are stored sorted by `t`.
EditResult addTrack(
  StageDocument doc,
  String sceneId,
  Track track, {
  PropertyRegistry? registry,
}) => _sceneEdit(doc, sceneId, (scene, diags) {
  if (scene.tracks.any((t) => t.id == track.id)) {
    diags.add(
      editError(
        IrDiagnosticKind.duplicateId,
        'Track id "${track.id}" is already used in scene "${scene.id}".',
        path: track.property,
      ),
    );
    return null;
  }
  if (track.keyframes.isEmpty) {
    diags.add(
      editError(
        IrDiagnosticKind.invalidEdit,
        'Track "${track.id}" has no keyframes; a track is created by its '
        'first keyframe.',
        path: track.property,
      ),
    );
    return null;
  }
  final t = _withSortedKeyframes(track);
  if (!_checkTrack(doc, scene, t, registry, diags)) return null;
  return _MotionChange(scene.copyWith(tracks: [...scene.tracks, t]));
});

/// Replaces track [trackId] of scene [sceneId] by `change(track)`. The
/// result is checked like [addTrack] (its id may change if it stays unique);
/// a result without keyframes removes the track. Returning the same track
/// is a no-op.
EditResult updateTrack(
  StageDocument doc,
  String sceneId,
  String trackId,
  Track Function(Track track) change, {
  PropertyRegistry? registry,
}) => _sceneEdit(doc, sceneId, (scene, diags) {
  final i = _trackIndex(scene, trackId, diags);
  if (i == null) return null;
  final old = scene.tracks[i];
  final next = change(old);
  if (identical(next, old)) return const _MotionChange.none();
  if (next.keyframes.isEmpty) {
    return _MotionChange(
      scene.copyWith(tracks: [...scene.tracks]..removeAt(i)),
      removedTrackIds: [old.id],
    );
  }
  if (next.id != old.id && scene.tracks.any((t) => t.id == next.id)) {
    diags.add(
      editError(
        IrDiagnosticKind.duplicateId,
        'Track id "${next.id}" is already used in scene "${scene.id}".',
      ),
    );
    return null;
  }
  final t = _withSortedKeyframes(next);
  if (!_checkTrack(doc, scene, t, registry, diags)) return null;
  return _MotionChange(scene.copyWith(tracks: [...scene.tracks]..[i] = t));
});

/// Removes the tracks [trackIds] from scene [sceneId]. Every id must exist.
EditResult removeTracks(
  StageDocument doc,
  String sceneId,
  Iterable<String> trackIds,
) => _sceneEdit(doc, sceneId, (scene, diags) {
  final ids = trackIds.toSet();
  for (final id in ids) {
    if (_trackIndex(scene, id, diags) == null) return null;
  }
  if (ids.isEmpty) return const _MotionChange.none();
  return _MotionChange(
    scene.copyWith(
      tracks: [
        for (final t in scene.tracks)
          if (!ids.contains(t.id)) t,
      ],
    ),
    removedTrackIds: [
      for (final t in scene.tracks)
        if (ids.contains(t.id)) t.id,
    ],
  );
});

/// Removes track [trackId] from scene [sceneId].
EditResult removeTrack(StageDocument doc, String sceneId, String trackId) =>
    removeTracks(doc, sceneId, [trackId]);

/// Moves the tracks [trackIds] of scene [sceneId] onto clock [clockId] (a
/// clock of the same scene). Moving to a clock of another kind remaps
/// keyframe times linearly from the source clock's range to the target's
/// (see [clockTimeRange]); the same kind keeps them as they are.
EditResult moveTracksToClock(
  StageDocument doc,
  String sceneId,
  Iterable<String> trackIds,
  String clockId,
) => _sceneEdit(doc, sceneId, (scene, diags) {
  if (!scene.clocks.any((c) => c.id == clockId)) {
    diags.add(_missingClock(clockId, scene.id));
    return null;
  }
  final ids = trackIds.toSet();
  for (final id in ids) {
    if (_trackIndex(scene, id, diags) == null) return null;
  }
  var changed = false;
  final target = scene.clocks.firstWhere((c) => c.id == clockId);
  final tracks = [
    for (final t in scene.tracks)
      if (ids.contains(t.id) && t.clockId != clockId)
        () {
          changed = true;
          final from = scene.clocks.where((c) => c.id == t.clockId);
          return _retime(
            doc,
            t.copyWith(clockId: clockId),
            from.isEmpty ? null : from.first,
            target,
          );
        }()
      else
        t,
  ];
  if (!changed) return const _MotionChange.none();
  return _MotionChange(scene.copyWith(tracks: tracks));
});

// ---- Keyframes ------------------------------------------------------------------

/// Adds keyframes to tracks of scene [sceneId]: `byTrack[trackId]` lists
/// the keyframes for that track. Ids must be new within their track; values
/// must fit the property.
EditResult addKeyframes(
  StageDocument doc,
  String sceneId,
  Map<String, List<Keyframe>> byTrack, {
  PropertyRegistry? registry,
}) => _editTracks(doc, sceneId, byTrack.keys, registry, (track, diags) {
  final add = byTrack[track.id]!;
  if (add.isEmpty) return track;
  final ids = {for (final k in track.keyframes) k.id};
  for (final k in add) {
    if (!ids.add(k.id)) {
      diags.add(
        editError(
          IrDiagnosticKind.duplicateId,
          'Keyframe id "${k.id}" is already used in track "${track.id}".',
          path: track.property,
        ),
      );
      return null;
    }
  }
  return track.copyWith(keyframes: [...track.keyframes, ...add]);
});

/// Adds [keyframe] to track [trackId] of scene [sceneId].
EditResult addKeyframe(
  StageDocument doc,
  String sceneId,
  String trackId,
  Keyframe keyframe, {
  PropertyRegistry? registry,
}) => addKeyframes(doc, sceneId, {
  trackId: [keyframe],
}, registry: registry);

/// Writes [value] at time [t] on track [trackId] of scene [sceneId]: the
/// keyframe already at [t] (within [kKeyframeTimeEpsilon]) gets the value,
/// keeping its id and easing; otherwise a keyframe [newId] is added (with
/// [easing], default linear). This is what a property write at the playhead
/// does (m2.md "Writing values while animated").
EditResult writeKeyframeAt(
  StageDocument doc,
  String sceneId,
  String trackId, {
  required double t,
  required IrValue value,
  required String newId,
  Easing easing = const Easing.linear(),
  PropertyRegistry? registry,
}) => _editTracks(doc, sceneId, [trackId], registry, (track, diags) {
  final kfs = track.keyframes;
  for (var i = 0; i < kfs.length; i++) {
    final k = kfs[i];
    if ((k.t - t).abs() <= kKeyframeTimeEpsilon) {
      if (k.value == value) return track;
      return track.copyWith(
        keyframes: [...kfs]..[i] = k.copyWith(value: value),
      );
    }
  }
  if (kfs.any((k) => k.id == newId)) {
    diags.add(
      editError(
        IrDiagnosticKind.duplicateId,
        'Keyframe id "$newId" is already used in track "${track.id}".',
        path: track.property,
      ),
    );
    return null;
  }
  return track.copyWith(
    keyframes: [
      ...kfs,
      Keyframe(id: newId, t: t, value: value, easing: easing),
    ],
  );
});

/// Moves keyframes in time: `times[trackId][keyframeId] = new t`. Ids are
/// kept; the track's keyframes are re-sorted (a keyframe moved onto another
/// one's time sorts after it when it came later before the move).
EditResult moveKeyframes(
  StageDocument doc,
  String sceneId,
  Map<String, Map<String, double>> times, {
  PropertyRegistry? registry,
}) => _editTracks(doc, sceneId, times.keys, registry, (track, diags) {
  final moves = times[track.id]!;
  if (!_allKeyframes(track, moves.keys, diags)) return null;
  var changed = false;
  final kfs = [
    for (final k in track.keyframes)
      if (moves[k.id] case final t? when t != k.t)
        () {
          changed = true;
          return k.copyWith(t: t);
        }()
      else
        k,
  ];
  return changed ? track.copyWith(keyframes: kfs) : track;
});

/// Replaces keyframes by `changes[trackId][keyframeId](keyframe)`. A change
/// may set the time, value and easing, but not the id.
EditResult updateKeyframes(
  StageDocument doc,
  String sceneId,
  Map<String, Map<String, Keyframe Function(Keyframe)>> changes, {
  PropertyRegistry? registry,
}) => _editTracks(doc, sceneId, changes.keys, registry, (track, diags) {
  final edits = changes[track.id]!;
  if (!_allKeyframes(track, edits.keys, diags)) return null;
  var changed = false;
  final kfs = <Keyframe>[];
  for (final k in track.keyframes) {
    final f = edits[k.id];
    if (f == null) {
      kfs.add(k);
      continue;
    }
    final next = f(k);
    if (next.id != k.id) {
      diags.add(
        editError(
          IrDiagnosticKind.invalidEdit,
          'Keyframe "${k.id}" of track "${track.id}" cannot change its id.',
          path: track.property,
        ),
      );
      return null;
    }
    if (!identical(next, k)) changed = true;
    kfs.add(next);
  }
  return changed ? track.copyWith(keyframes: kfs) : track;
});

/// Replaces keyframe [keyframeId] of track [trackId] by `change(keyframe)`.
EditResult updateKeyframe(
  StageDocument doc,
  String sceneId,
  String trackId,
  String keyframeId,
  Keyframe Function(Keyframe keyframe) change, {
  PropertyRegistry? registry,
}) => updateKeyframes(doc, sceneId, {
  trackId: {keyframeId: change},
}, registry: registry);

/// Removes keyframes: `byTrack[trackId]` names the keyframes to remove from
/// that track. A track left without keyframes is removed
/// (`cascade.removedTrackIds`).
EditResult removeKeyframes(
  StageDocument doc,
  String sceneId,
  Map<String, Set<String>> byTrack,
) => _editTracks(doc, sceneId, byTrack.keys, null, (track, diags) {
  final gone = byTrack[track.id]!;
  if (!_allKeyframes(track, gone, diags)) return null;
  if (gone.isEmpty) return track;
  return track.copyWith(
    keyframes: [
      for (final k in track.keyframes)
        if (!gone.contains(k.id)) k,
    ],
  );
}, check: false);

/// Removes keyframe [keyframeId] from track [trackId] (and the track with
/// its last keyframe).
EditResult removeKeyframe(
  StageDocument doc,
  String sceneId,
  String trackId,
  String keyframeId,
) => removeKeyframes(doc, sceneId, {
  trackId: {keyframeId},
});

/// Sets [easing] on segments: `segments[trackId]` names the keyframes that
/// start them (a segment runs from a keyframe to the next one in time). The
/// last keyframe of a track starts no segment: it is skipped with a
/// warning.
EditResult setSegmentEasing(
  StageDocument doc,
  String sceneId,
  Map<String, Set<String>> segments,
  Easing easing,
) {
  final warnings = <IrDiagnostic>[];
  final r = _editTracks(doc, sceneId, segments.keys, null, (track, diags) {
    final ids = segments[track.id]!;
    if (!_allKeyframes(track, ids, diags)) return null;
    // Stored keyframes are sorted, so the last one in time is last.
    final last = track.keyframes.last.id;
    var changed = false;
    final kfs = [
      for (final k in track.keyframes)
        if (ids.contains(k.id) && k.id != last && k.easing != easing)
          () {
            changed = true;
            return k.copyWith(easing: easing);
          }()
        else
          k,
    ];
    if (ids.contains(last)) {
      warnings.add(
        editWarning(
          IrDiagnosticKind.invalidEdit,
          'Keyframe "$last" is the last of track "${track.id}" and starts no '
          'segment; its easing was not set.',
          path: track.property,
        ),
      );
    }
    return changed ? track.copyWith(keyframes: kfs) : track;
  }, check: false);
  if (!r.ok || warnings.isEmpty) return r;
  return r.copyWith(diagnostics: [...r.diagnostics, ...warnings]);
}

// ---- Clocks ---------------------------------------------------------------------

/// Adds [clock] to scene [sceneId]. Its id must be new to the document
/// (clock ids are document-wide); what it is bound to must exist (a
/// pointer clock's frame, an audio clock's track, a behaviour clock's node,
/// a scroll clock's scene).
EditResult addClock(StageDocument doc, String sceneId, Clock clock) =>
    _sceneEdit(doc, sceneId, (scene, diags) {
      if (_clockIdUsed(doc, clock.id)) {
        diags.add(_clockIdTaken(clock.id));
        return null;
      }
      if (!_checkClock(doc, clock, diags)) return null;
      return _MotionChange(scene.copyWith(clocks: [...scene.clocks, clock]));
    });

/// Replaces clock [clockId] of scene [sceneId] by `change(clock)`, checked
/// like [addClock]. Changing the id rebinds the scene's tracks (and
/// text reveals) that use the clock.
EditResult updateClock(
  StageDocument doc,
  String sceneId,
  String clockId,
  Clock Function(Clock clock) change,
) => _sceneEdit(doc, sceneId, (scene, diags) {
  final i = scene.clocks.indexWhere((c) => c.id == clockId);
  if (i < 0) {
    diags.add(_missingClock(clockId, scene.id));
    return null;
  }
  final old = scene.clocks[i];
  final next = change(old);
  if (identical(next, old) || next == old) return const _MotionChange.none();
  if (next.id != old.id && _clockIdUsed(doc, next.id)) {
    diags.add(_clockIdTaken(next.id));
    return null;
  }
  if (old is SceneScrollClock &&
      old.sceneId == scene.id &&
      !(next is SceneScrollClock && next.sceneId == scene.id) &&
      !_hasOtherOwnScrollClock(scene, old.id)) {
    diags.add(_scrollClockRequired(scene.id));
    return null;
  }
  if (!_checkClock(doc, next, diags)) return null;
  var out = scene.copyWith(clocks: [...scene.clocks]..[i] = next);
  if (next.id != old.id) out = _rebindClock(out, old.id, next.id);
  return _MotionChange(out);
});

/// Removes clock [clockId] from scene [sceneId]. Its tracks are removed with
/// it ([ClockRemoval.deleteTracks], the default) or moved to another clock
/// of the scene ([ClockRemoval.moveTracksTo]), listed in
/// `cascade.removedTrackIds` / `removedClockIds`.
///
/// The scene's own scroll clock always exists (m2.md "Clocks UI"): removing
/// its last one is an error. Text reveals of the scene that use the clock
/// follow its tracks when they move; otherwise they, and interactions that
/// name the clock, are left for the validator with a `missingClock`
/// warning.
EditResult removeClock(
  StageDocument doc,
  String sceneId,
  String clockId, {
  ClockRemoval tracks = const ClockRemoval.deleteTracks(),
}) => _sceneEdit(doc, sceneId, (scene, diags) {
  final i = scene.clocks.indexWhere((c) => c.id == clockId);
  if (i < 0) {
    diags.add(_missingClock(clockId, scene.id));
    return null;
  }
  final clock = scene.clocks[i];
  if (clock is SceneScrollClock &&
      clock.sceneId == scene.id &&
      !_hasOtherOwnScrollClock(scene, clock.id)) {
    diags.add(_scrollClockRequired(scene.id));
    return null;
  }
  final clocks = [...scene.clocks]..removeAt(i);
  switch (tracks) {
    case MoveClockTracks(clockId: final to):
      if (to == clockId || !clocks.any((c) => c.id == to)) {
        diags.add(_missingClock(to, scene.id));
        return null;
      }
      final target = clocks.firstWhere((c) => c.id == to);
      var out = _rebindClock(scene.copyWith(clocks: clocks), clockId, to);
      out = out.copyWith(
        tracks: [
          for (final t in out.tracks)
            if (scene.tracks.any((o) => o.id == t.id && o.clockId == clockId))
              _retime(doc, t, clock, target)
            else
              t,
        ],
      );
      if (_referencesClock(doc, clockId, exceptScene: scene.id) ||
          _sceneReferencesClock(out, clockId)) {
        diags.add(_dangling(clockId));
      }
      return _MotionChange(out, removedClockIds: [clockId]);
    case DeleteClockTracks():
      final removed = [
        for (final t in scene.tracks)
          if (t.clockId == clockId) t.id,
      ];
      final out = scene.copyWith(
        clocks: clocks,
        tracks: [
          for (final t in scene.tracks)
            if (t.clockId != clockId) t,
        ],
      );
      if (_referencesClock(doc, clockId, exceptScene: scene.id) ||
          _sceneReferencesClock(out, clockId)) {
        diags.add(_dangling(clockId));
      }
      return _MotionChange(
        out,
        removedTrackIds: removed,
        removedClockIds: [clockId],
      );
  }
});

// ---- Internals ------------------------------------------------------------------

/// What one scene edit produced: the new scene (null: unchanged) and what
/// it removed.
class _MotionChange {
  const _MotionChange(
    Scene this.scene, {
    this.removedTrackIds = const [],
    this.removedClockIds = const [],
  });

  const _MotionChange.none()
    : scene = null,
      removedTrackIds = const [],
      removedClockIds = const [];

  final Scene? scene;
  final List<String> removedTrackIds;
  final List<String> removedClockIds;
}

/// Runs [edit] on scene [sceneId]: null (with errors in the list) fails the
/// edit; otherwise the scene is replaced by path copy.
EditResult _sceneEdit(
  StageDocument doc,
  String sceneId,
  _MotionChange? Function(Scene scene, List<IrDiagnostic> diags) edit,
) {
  final i = DocumentIndex.of(doc).sceneIndexOf(sceneId);
  if (i == null) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.missingScene,
        'Scene "$sceneId" does not exist.',
      ),
    ]);
  }
  final diags = <IrDiagnostic>[];
  final r = edit(doc.scenes[i], diags);
  if (r == null || hasErrors(diags)) {
    return failed(
      doc,
      diags.isEmpty ? [_invalid('Motion edit failed.')] : diags,
    );
  }
  final next = r.scene;
  if (next == null || identical(next, doc.scenes[i])) {
    return unchanged(doc, diags);
  }
  return EditResult(
    document: doc.copyWith(scenes: [...doc.scenes]..[i] = next),
    changed: true,
    diagnostics: diags,
    cascade: EditCascade(
      removedTrackIds: r.removedTrackIds,
      removedClockIds: r.removedClockIds,
    ),
  );
}

/// Edits the tracks [trackIds] of scene [sceneId] with [edit] (null fails
/// the edit; the same track is no change). Edited tracks are re-sorted and,
/// when [check], re-checked; tracks left without keyframes are removed.
EditResult _editTracks(
  StageDocument doc,
  String sceneId,
  Iterable<String> trackIds,
  PropertyRegistry? registry,
  Track? Function(Track track, List<IrDiagnostic> diags) edit, {
  bool check = true,
}) => _sceneEdit(doc, sceneId, (scene, diags) {
  final ids = trackIds.toSet();
  for (final id in ids) {
    if (_trackIndex(scene, id, diags) == null) return null;
  }
  var changed = false;
  final removed = <String>[];
  final tracks = <Track>[];
  for (final t in scene.tracks) {
    if (!ids.contains(t.id)) {
      tracks.add(t);
      continue;
    }
    final next = edit(t, diags);
    if (next == null) return null;
    if (identical(next, t)) {
      tracks.add(t);
      continue;
    }
    changed = true;
    if (next.keyframes.isEmpty) {
      removed.add(t.id);
      continue;
    }
    final sorted = _withSortedKeyframes(next);
    if (check && !_checkTrack(doc, scene, sorted, registry, diags)) {
      return null;
    }
    tracks.add(sorted);
  }
  if (!changed) return const _MotionChange.none();
  return _MotionChange(
    scene.copyWith(tracks: tracks),
    removedTrackIds: removed,
  );
});

int? _trackIndex(Scene scene, String trackId, List<IrDiagnostic> diags) {
  final i = scene.tracks.indexWhere((t) => t.id == trackId);
  if (i >= 0) return i;
  diags.add(
    editError(
      IrDiagnosticKind.missingTrack,
      'Track "$trackId" does not exist in scene "${scene.id}".',
    ),
  );
  return null;
}

bool _allKeyframes(
  Track track,
  Iterable<String> ids,
  List<IrDiagnostic> diags,
) {
  for (final id in ids) {
    if (!track.keyframes.any((k) => k.id == id)) {
      diags.add(
        editError(
          IrDiagnosticKind.missingKeyframe,
          'Keyframe "$id" does not exist in track "${track.id}".',
          path: track.property,
        ),
      );
      return false;
    }
  }
  return true;
}

/// [t] with its keyframes sorted by time (stable); [t] itself when sorted.
Track _withSortedKeyframes(Track t) {
  final kfs = t.keyframes;
  var sorted = true;
  for (var i = 1; i < kfs.length; i++) {
    if (kfs[i].t < kfs[i - 1].t) {
      sorted = false;
      break;
    }
  }
  if (sorted) return t;
  final indexed = [for (var i = 0; i < kfs.length; i++) (i, kfs[i])]
    ..sort((x, y) {
      final c = x.$2.t.compareTo(y.$2.t);
      return c != 0 ? c : x.$1.compareTo(y.$1);
    });
  return t.copyWith(keyframes: [for (final (_, k) in indexed) k]);
}

/// The integrity checks of a track in [scene] (see the file comment).
bool _checkTrack(
  StageDocument doc,
  Scene scene,
  Track t,
  PropertyRegistry? registry,
  List<IrDiagnostic> diags,
) {
  final reg = registry ?? PropertyRegistry.standard;
  final before = diags.length;
  if (!scene.clocks.any((c) => c.id == t.clockId)) {
    diags.add(_missingClock(t.clockId, scene.id));
  }
  // The target: a node of this scene, or a path under one of its instances.
  final parts = t.target.split('/');
  final index = DocumentIndex.of(doc);
  final loc = index.locate(parts.first);
  Node? node;
  if (loc == null || loc.sceneId != scene.id) {
    diags.add(
      editError(
        IrDiagnosticKind.missingTrackTarget,
        'Track "${t.id}" targets "${t.target}", which is not a node of scene '
        '"${scene.id}".',
        nodeId: t.target,
        path: t.property,
      ),
    );
  } else {
    final head = index.node(parts.first)!;
    if (parts.length == 1) {
      node = head;
    } else if (head is! InstanceNode) {
      diags.add(
        editError(
          IrDiagnosticKind.missingTrackTarget,
          'Track "${t.id}" targets "${t.target}", but "${parts.first}" is '
          'not an instance.',
          nodeId: t.target,
          path: t.property,
        ),
      );
    }
  }
  final match = reg.lookup(t.property);
  if (match == null) {
    diags.add(
      editError(
        IrDiagnosticKind.unknownPath,
        'No property is registered at "${t.property}".',
        nodeId: t.target,
        path: t.property,
      ),
    );
  } else if (!match.descriptor.animatable) {
    diags.add(
      editError(
        IrDiagnosticKind.invalidEdit,
        '"${t.property}" is not animatable.',
        nodeId: t.target,
        path: t.property,
      ),
    );
  } else if (node != null &&
      !match.descriptor.appliesTo.contains(nodeKindOf(node))) {
    diags.add(
      editError(
        IrDiagnosticKind.inapplicablePath,
        '"${t.property}" does not apply to ${nodeKindOf(node).name} '
        '"${node.id}".',
        nodeId: t.target,
        path: t.property,
      ),
    );
  }
  final only = t.breakpoints;
  if (only != null) {
    if (only.isEmpty) {
      diags.add(
        editError(
          IrDiagnosticKind.invalidEdit,
          'Track "${t.id}" applies at no breakpoint (use null for all).',
          path: t.property,
        ),
      );
    }
    for (final bp in only) {
      if (!doc.breakpoints.any((b) => b.id == bp)) {
        diags.add(
          editError(
            IrDiagnosticKind.missingBreakpoint,
            'Track "${t.id}" names breakpoint "$bp", which does not exist.',
            path: bp,
          ),
        );
      }
    }
  }
  final ids = <String>{};
  // Values are type-checked against the target when the property exists on
  // it (a paint may only exist under a breakpoint patch).
  final typed = match != null && node != null && match.get(node) != null
      ? match
      : null;
  for (final k in t.keyframes) {
    if (!ids.add(k.id)) {
      diags.add(
        editError(
          IrDiagnosticKind.duplicateId,
          'Keyframe id "${k.id}" is used twice in track "${t.id}".',
          path: t.property,
        ),
      );
    }
    if (!k.t.isFinite) {
      diags.add(
        editError(
          IrDiagnosticKind.invalidValue,
          'Keyframe "${k.id}" of track "${t.id}" has a non-finite time.',
          path: t.property,
        ),
      );
    }
    final v = k.value;
    if (typed != null &&
        v is! TokenRefValue &&
        typed.trySet(node!, v) == null) {
      diags.add(
        editError(
          IrDiagnosticKind.inapplicablePath,
          'Keyframe "${k.id}" of track "${t.id}" holds a value of the wrong '
          'type for "${t.property}".',
          nodeId: t.target,
          path: t.property,
        ),
      );
    }
  }
  return diags.length == before;
}

bool _checkClock(StageDocument doc, Clock clock, List<IrDiagnostic> diags) {
  final index = DocumentIndex.of(doc);
  switch (clock) {
    case SceneScrollClock(:final sceneId):
      if (index.sceneIndexOf(sceneId) == null) {
        diags.add(
          editError(
            IrDiagnosticKind.missingScene,
            'Scroll clock "${clock.id}" follows scene "$sceneId", which does '
            'not exist.',
          ),
        );
        return false;
      }
    case TimelineClock(:final duration, :final rate):
      if (!(duration > 0) || !duration.isFinite || !rate.isFinite) {
        diags.add(
          editError(
            IrDiagnosticKind.invalidValue,
            'Timeline clock "${clock.id}" needs a positive duration and a '
            'finite rate.',
          ),
        );
        return false;
      }
    case AudioClock(:final audioTrackId):
      if (!doc.audioTracks.any((a) => a.id == audioTrackId)) {
        diags.add(
          editError(
            IrDiagnosticKind.missingAudioTrack,
            'Audio clock "${clock.id}" follows audio track "$audioTrackId", '
            'which does not exist.',
          ),
        );
        return false;
      }
    case PointerClock(:final frameId):
      if (index.node(frameId) is! FrameNode) {
        diags.add(
          editError(
            IrDiagnosticKind.missingNode,
            'Pointer clock "${clock.id}" follows frame "$frameId", which does '
            'not exist.',
            nodeId: frameId,
          ),
        );
        return false;
      }
    case BehaviorClock(:final nodeId):
      if (!index.contains(nodeId)) {
        diags.add(
          editError(
            IrDiagnosticKind.missingNode,
            'Behaviour clock "${clock.id}" follows node "$nodeId", which does '
            'not exist.',
            nodeId: nodeId,
          ),
        );
        return false;
      }
  }
  final smoothing = switch (clock) {
    SceneScrollClock(:final smoothing) ||
    TimelineClock(:final smoothing) ||
    AudioClock(:final smoothing) ||
    PointerClock(:final smoothing) ||
    BehaviorClock(:final smoothing) => smoothing,
  };
  if (!(smoothing >= 0) || !smoothing.isFinite) {
    diags.add(
      editError(
        IrDiagnosticKind.invalidValue,
        'Clock "${clock.id}" has a negative or non-finite smoothing.',
      ),
    );
    return false;
  }
  return true;
}

bool _clockIdUsed(StageDocument doc, String id) =>
    doc.scenes.any((s) => s.clocks.any((c) => c.id == id));

bool _hasOtherOwnScrollClock(Scene scene, String exceptId) => scene.clocks.any(
  (c) => c is SceneScrollClock && c.sceneId == scene.id && c.id != exceptId,
);

/// [scene] with its tracks and text reveals on clock [from] moved to [to].
/// The time range of [clock] a track's keyframes span: scroll 0–1, timeline
/// 0–duration, pointer −1…1, audio 0–track length. Null when it has none (a
/// behaviour clock, or an audio clock whose track length is unknown).
({double start, double end})? clockTimeRange(StageDocument doc, Clock clock) =>
    switch (clock) {
      SceneScrollClock() => (start: 0, end: 1),
      TimelineClock(:final duration) => (start: 0, end: duration),
      PointerClock() => (start: -1, end: 1),
      AudioClock(:final audioTrackId) => () {
        for (final a in doc.audioTracks) {
          if (a.id != audioTrackId) continue;
          final d = doc.assets[a.assetId]?.duration;
          return d != null && d > 0 ? (start: 0.0, end: d) : null;
        }
        return null;
      }(),
      BehaviorClock() => null,
    };

/// [track] with its keyframe times mapped linearly from the range of [from]
/// to that of [to] when the clocks are of different kinds.
Track _retime(StageDocument doc, Track track, Clock? from, Clock to) {
  if (from == null || from.runtimeType == to.runtimeType) return track;
  final a = clockTimeRange(doc, from);
  final b = clockTimeRange(doc, to);
  if (a == null || b == null || a.end == a.start) return track;
  final k = (b.end - b.start) / (a.end - a.start);
  return track.copyWith(
    keyframes: [
      for (final kf in track.keyframes)
        kf.copyWith(t: b.start + (kf.t - a.start) * k),
    ],
  );
}

Scene _rebindClock(Scene scene, String from, String to) {
  var tracksChanged = false;
  final tracks = [
    for (final t in scene.tracks)
      if (t.clockId == from)
        () {
          tracksChanged = true;
          return t.copyWith(clockId: to);
        }()
      else
        t,
  ];
  var out = tracksChanged ? scene.copyWith(tracks: tracks) : scene;
  final reveals = <String>[];
  void find(Node n) {
    if (n case FrameNode(
      behavior: TextRevealBehavior(:final clockId),
    ) when clockId == from) {
      reveals.add(n.id);
    }
    if (n is FrameNode) n.children.forEach(find);
  }

  find(scene.root);
  if (reveals.isEmpty) return out;
  FrameNode rewrite(FrameNode f) {
    var kids = f.children;
    var changed = false;
    final next = [
      for (final c in kids)
        if (c is FrameNode)
          () {
            final r = rewrite(c);
            if (!identical(r, c)) changed = true;
            return r;
          }()
        else
          c,
    ];
    if (changed) kids = next;
    var out = changed ? f.copyWith(children: kids) : f;
    if (reveals.contains(f.id) && out.behavior is TextRevealBehavior) {
      out = out.copyWith(
        behavior: (out.behavior! as TextRevealBehavior).copyWith(clockId: to),
      );
    }
    return out;
  }

  out = out.copyWith(root: rewrite(out.root));
  return out;
}

/// Whether nodes of [scene] still name clock [id] (text reveals, embed
/// inputs, interactions).
bool _sceneReferencesClock(Scene scene, String id) {
  var found = false;
  void visit(Node n) {
    if (found) return;
    if (_nodeReferencesClock(n, id)) {
      found = true;
      return;
    }
    if (n is FrameNode) n.children.forEach(visit);
  }

  visit(scene.root);
  return found;
}

/// Whether nodes outside scene [exceptScene] (other scenes and the
/// overlay) name clock [id].
bool _referencesClock(
  StageDocument doc,
  String id, {
  required String exceptScene,
}) {
  for (final s in doc.scenes) {
    if (s.id != exceptScene && _sceneReferencesClock(s, id)) return true;
  }
  final o = doc.overlay;
  if (o == null) return false;
  return _sceneReferencesClock(Scene(id: '', root: o), id);
}

bool _nodeReferencesClock(Node n, String id) {
  if (n case FrameNode(
    behavior: TextRevealBehavior(:final clockId),
  ) when clockId == id) {
    return true;
  }
  if (n is EmbedNode && n.inputBindings.values.contains(id)) return true;
  for (final i in n.common.interactions) {
    if (i.trigger case ClockReachTrigger(:final clockId) when clockId == id) {
      return true;
    }
    for (final a in i.actions) {
      final ref = switch (a) {
        PlayTimelineAction(:final clockId) ||
        PauseTimelineAction(:final clockId) ||
        SeekTimelineAction(:final clockId) ||
        ReverseTimelineAction(:final clockId) => clockId,
        _ => null,
      };
      if (ref == id) return true;
    }
  }
  return false;
}

IrDiagnostic _invalid(String message) =>
    editError(IrDiagnosticKind.invalidEdit, message);

IrDiagnostic _missingClock(String clockId, String sceneId) => editError(
  IrDiagnosticKind.missingClock,
  'Clock "$clockId" is not a clock of scene "$sceneId".',
);

IrDiagnostic _clockIdTaken(String id) => editError(
  IrDiagnosticKind.duplicateId,
  'Clock id "$id" is already used in the document.',
);

IrDiagnostic _scrollClockRequired(String sceneId) => editError(
  IrDiagnosticKind.invalidEdit,
  'Scene "$sceneId" keeps its scroll clock.',
);

IrDiagnostic _dangling(String clockId) => editWarning(
  IrDiagnosticKind.missingClock,
  'Clock "$clockId" was removed but is still named by a text reveal, an '
  'embed input or an interaction.',
);
