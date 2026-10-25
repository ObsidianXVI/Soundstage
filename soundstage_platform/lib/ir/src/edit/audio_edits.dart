import '../assets.dart';
import '../audio.dart';
import '../behaviors.dart';
import '../diagnostics.dart';
import '../document.dart';
import '../interactions.dart';
import '../motion.dart';
import '../nodes/node.dart';
import 'document_index.dart';
import 'edit_core.dart';
import 'edit_result.dart';
import 'motion_edits.dart';

// Pure audio-track edits (architecture §10.4; m2.md "Audio lane"). Audio
// tracks live in `StageDocument.audioTracks`; the lyrics of a track are
// edited in `lyrics_edits.dart`. Errors leave the document unchanged (see
// [EditResult]).

/// Adds [track] to the document.
///
/// Its id must be new, its asset must exist and be audio, and a
/// scene-scoped track needs its scene. With [clock] (an [AudioClock] on
/// [track]) and [clockSceneId], the audio clock is added to that scene in
/// the same edit; that is what lets a scene animate to the track's playback
/// position. `createdIds` is `[track.id]`.
EditResult addAudioTrack(
  StageDocument doc,
  AudioTrack track, {
  AudioClock? clock,
  String? clockSceneId,
}) {
  if (doc.audioTracks.any((t) => t.id == track.id)) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.duplicateId,
        'Audio track id "${track.id}" is already used.',
      ),
    ]);
  }
  final diags = _checkTrack(doc, track);
  if (diags.isNotEmpty) return failed(doc, diags);
  var next = doc.copyWith(audioTracks: [...doc.audioTracks, track]);
  if (clock != null) {
    if (clock.audioTrackId != track.id || clockSceneId == null) {
      return failed(doc, [
        editError(
          IrDiagnosticKind.invalidEdit,
          'The audio clock must follow the new track and name a scene.',
        ),
      ]);
    }
    final r = addClock(next, clockSceneId, clock);
    if (!r.ok) return failed(doc, r.diagnostics);
    next = r.document;
  }
  return EditResult(document: next, changed: true, createdIds: [track.id]);
}

/// Replaces audio track [trackId] by `change(track)` (its id cannot change).
/// The new asset, scope, volume and fades are checked like [addAudioTrack].
EditResult updateAudioTrack(
  StageDocument doc,
  String trackId,
  AudioTrack Function(AudioTrack track) change,
) {
  final i = doc.audioTracks.indexWhere((t) => t.id == trackId);
  if (i < 0) return failed(doc, [_missingTrack(trackId)]);
  final old = doc.audioTracks[i];
  final next = change(old);
  if (identical(next, old) || next == old) return unchanged(doc);
  if (next.id != old.id) {
    return failed(doc, [
      editError(
        IrDiagnosticKind.invalidEdit,
        'The id of audio track "$trackId" cannot change.',
      ),
    ]);
  }
  final diags = _checkTrack(doc, next);
  if (diags.isNotEmpty) return failed(doc, diags);
  return EditResult(
    document: doc.copyWith(audioTracks: [...doc.audioTracks]..[i] = next),
    changed: true,
  );
}

/// Removes audio track [trackId] and what only made sense with it:
///
/// - its audio clocks, with the motion tracks that run on them
///   (`cascade.removedClockIds` / `removedTrackIds`);
/// - Lyrics and AudioControls behaviours that name it, and TextReveal
///   behaviours that ran on one of those clocks (the frame stays);
/// - interactions triggered by its cues, and audio actions that name it
///   (`cascade.removedInteractions` / `removedActions`).
///
/// Each cleared behaviour is reported as a warning diagnostic.
EditResult removeAudioTrack(StageDocument doc, String trackId) {
  if (!doc.audioTracks.any((t) => t.id == trackId)) {
    return failed(doc, [_missingTrack(trackId)]);
  }
  final goneClocks = <String>{};
  final removedTracks = <String>[];
  final scenes = [
    for (final s in doc.scenes)
      () {
        final clocks = <Clock>[];
        for (final c in s.clocks) {
          if (c is AudioClock && c.audioTrackId == trackId) {
            goneClocks.add(c.id);
          } else {
            clocks.add(c);
          }
        }
        if (clocks.length == s.clocks.length) return s;
        final tracks = <Track>[];
        for (final t in s.tracks) {
          if (goneClocks.contains(t.clockId)) {
            removedTracks.add(t.id);
          } else {
            tracks.add(t);
          }
        }
        return s.copyWith(clocks: clocks, tracks: tracks);
      }(),
  ];
  final cleaner = _AudioRefCleaner(trackId, goneClocks);
  final cleaned = [
    for (final s in scenes)
      () {
        final root = cleaner.node(s.root) as FrameNode;
        return identical(root, s.root) ? s : s.copyWith(root: root);
      }(),
  ];
  final overlay = doc.overlay == null
      ? null
      : cleaner.node(doc.overlay!) as FrameNode;
  final components = {
    for (final e in doc.components.entries)
      e.key: () {
        final root = cleaner.node(e.value.root) as FrameNode;
        return identical(root, e.value.root)
            ? e.value
            : e.value.copyWith(root: root);
      }(),
  };
  return EditResult(
    document: doc.copyWith(
      audioTracks: [
        for (final t in doc.audioTracks)
          if (t.id != trackId) t,
      ],
      scenes: cleaned,
      overlay: overlay,
      components: components,
    ),
    changed: true,
    diagnostics: cleaner.warnings,
    cascade: EditCascade(
      removedTrackIds: removedTracks,
      removedClockIds: goneClocks.toList(),
      removedActions: cleaner.actions,
      removedInteractions: cleaner.interactions,
    ),
  );
}

/// Whether no scene of [doc] has a clock with id [id] (clock ids are
/// document-wide).
bool audioClockIdFree(StageDocument doc, String id) =>
    !doc.scenes.any((s) => s.clocks.any((c) => c.id == id));

/// The audio clock of [trackId] in scene [sceneId], or null.
AudioClock? audioClockOf(StageDocument doc, String sceneId, String trackId) {
  for (final s in doc.scenes) {
    if (s.id != sceneId) continue;
    for (final c in s.clocks) {
      if (c is AudioClock && c.audioTrackId == trackId) return c;
    }
  }
  return null;
}

IrDiagnostic _missingTrack(String id) => editError(
  IrDiagnosticKind.missingAudioTrack,
  'There is no audio track "$id".',
);

List<IrDiagnostic> _checkTrack(StageDocument doc, AudioTrack t) {
  final out = <IrDiagnostic>[];
  final asset = doc.assets[t.assetId];
  if (asset == null) {
    out.add(
      editError(
        IrDiagnosticKind.missingAsset,
        'Audio track "${t.id}" uses asset "${t.assetId}", which does not '
        'exist.',
      ),
    );
  } else if (asset.kind != AssetKind.audio) {
    out.add(
      editError(
        IrDiagnosticKind.wrongAssetKind,
        'Asset "${t.assetId}" is ${asset.kind.name}, not audio.',
      ),
    );
  }
  final scope = t.scope;
  if (scope is SceneAudioScope &&
      DocumentIndex.of(doc).sceneIndexOf(scope.sceneId) == null) {
    out.add(
      editError(
        IrDiagnosticKind.missingScene,
        'Audio track "${t.id}" is scoped to scene "${scope.sceneId}", which '
        'does not exist.',
      ),
    );
  }
  if (!(t.volume >= 0 && t.volume <= 1)) {
    out.add(
      editError(
        IrDiagnosticKind.invalidValue,
        'Volume must be between 0 and 1 (got ${t.volume}).',
      ),
    );
  }
  for (final (name, v) in [('fadeIn', t.fadeIn), ('fadeOut', t.fadeOut)]) {
    if (!(v >= 0) || !v.isFinite) {
      out.add(
        editError(
          IrDiagnosticKind.invalidValue,
          '$name must be zero or more seconds (got $v).',
        ),
      );
    }
  }
  return out;
}

/// Path-copying cleanup of every reference to a removed audio track (and to
/// the clocks that followed it) in a node tree.
class _AudioRefCleaner {
  _AudioRefCleaner(this.trackId, this.goneClocks);

  final String trackId;
  final Set<String> goneClocks;
  final warnings = <IrDiagnostic>[];
  final actions = <CascadedAction>[];
  final interactions = <CascadedInteraction>[];

  bool _actionGone(Action a) => switch (a) {
    PlayAudioAction(:final audioTrackId) ||
    PauseAudioAction(:final audioTrackId) ||
    SeekAudioAction(:final audioTrackId) => audioTrackId == trackId,
    PlayTimelineAction(:final clockId) ||
    PauseTimelineAction(:final clockId) ||
    SeekTimelineAction(:final clockId) ||
    ReverseTimelineAction(:final clockId) => goneClocks.contains(clockId),
    _ => false,
  };

  bool _triggerGone(InteractionTrigger t) => switch (t) {
    AudioCueTrigger(:final audioTrackId) => audioTrackId == trackId,
    ClockReachTrigger(:final clockId) => goneClocks.contains(clockId),
    _ => false,
  };

  Node node(Node n) {
    var common = n.common;
    if (common.interactions.isNotEmpty) {
      final kept = <Interaction>[];
      for (final i in common.interactions) {
        if (_triggerGone(i.trigger)) {
          interactions.add(CascadedInteraction(nodeId: n.id, interaction: i));
          continue;
        }
        final ok = <Action>[];
        for (final a in i.actions) {
          if (_actionGone(a)) {
            actions.add(
              CascadedAction(nodeId: n.id, interactionId: i.id, action: a),
            );
          } else {
            ok.add(a);
          }
        }
        if (ok.length == i.actions.length) {
          kept.add(i);
        } else if (ok.isEmpty) {
          interactions.add(CascadedInteraction(nodeId: n.id, interaction: i));
        } else {
          kept.add(i.copyWith(actions: ok));
        }
      }
      if (kept.length != common.interactions.length ||
          !_same(kept, common.interactions)) {
        common = common.copyWith(interactions: kept);
      }
    }
    if (n is! FrameNode) {
      return identical(common, n.common) ? n : n.copyWith(common: common);
    }
    final kids = [for (final k in n.children) node(k)];
    var childrenSame = true;
    for (var i = 0; i < kids.length; i++) {
      if (!identical(kids[i], n.children[i])) childrenSame = false;
    }
    var behavior = n.behavior;
    final gone = switch (behavior) {
      LyricsBehavior(:final audioTrackId) ||
      AudioControlsBehavior(:final audioTrackId) => audioTrackId == trackId,
      TextRevealBehavior(:final clockId) => goneClocks.contains(clockId),
      _ => false,
    };
    if (gone) {
      warnings.add(
        editWarning(
          IrDiagnosticKind.missingAudioTrack,
          'Removed the ${_behaviorName(behavior!)} behaviour from '
          '"${n.id}": it used the removed audio track.',
          nodeId: n.id,
        ),
      );
      behavior = null;
    }
    if (childrenSame && !gone && identical(common, n.common)) return n;
    return n.copyWith(common: common, children: kids, behavior: behavior);
  }

  static bool _same(List<Interaction> a, List<Interaction> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }
}

String _behaviorName(Behavior b) => switch (b) {
  LyricsBehavior() => 'Lyrics',
  AudioControlsBehavior() => 'Audio controls',
  TextRevealBehavior() => 'Text reveal',
  _ => 'behaviour',
};
