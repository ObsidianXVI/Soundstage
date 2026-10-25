import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Audio and lyrics commands (architecture §10.4; m2.md "Audio lane",
// "Lyrics lane"): one command per IR edit helper in
// `lib/ir/src/edit/audio_edits.dart` and `lyrics_edits.dart`. The lanes
// drive the lyric commands with absolute values; drags coalesce on the key
// of the line or word being dragged, so a drag is one undo step.

/// Adds an audio track playing asset [assetId].
///
/// - [sceneId] set: the track plays only while that scene is on screen;
///   null: across the whole story.
/// - [clockSceneId] set: the scene also gets an audio clock following the
///   new track, so its motion tracks can be keyed to playback time
///   (m2.md "Audio lane"). The inspector passes the active scene.
///
/// Selects the new track (its Audio view opens in the inspector).
class AddAudioTrack extends EditCommand {
  const AddAudioTrack(
    this.assetId, {
    this.sceneId,
    this.clockSceneId,
    this.autoplay = false,
    this.loop = false,
    this.ids,
  });

  final String assetId;
  final String? sceneId;
  final String? clockSceneId;
  final bool autoplay;
  final bool loop;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Add audio';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final gen = ids ?? ir.IdGenerator.forDocument(doc);
    final trackId = gen.next();
    final withClock = clockSceneId != null;
    final r = ir.addAudioTrack(
      doc,
      ir.AudioTrack(
        id: trackId,
        assetId: assetId,
        scope: sceneId == null
            ? const ir.AudioScope.story()
            : ir.AudioScope.scene(sceneId!),
        autoplay: autoplay,
        loop: loop,
      ),
      clock: withClock
          ? ir.AudioClock(id: gen.next(), audioTrackId: trackId)
          : null,
      clockSceneId: clockSceneId,
    );
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: const {},
      audioTrackAfter: trackId,
    );
  }
}

/// Replaces audio track [trackId] by `change(track)`: autoplay, loop,
/// volume, fades, scope or asset (see `ir.updateAudioTrack`). Give a
/// [coalesceKey] for a scrubbed value.
class UpdateAudioTrack extends EditCommand {
  const UpdateAudioTrack(
    this.trackId,
    this.change, {
    this.label = 'Change audio',
    this.coalesceKey,
  });

  final String trackId;
  final ir.AudioTrack Function(ir.AudioTrack track) change;

  @override
  final String label;

  @override
  final String? coalesceKey;

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateAudioTrack(state.document, trackId, change),
    label: label,
    coalesceKey: coalesceKey,
  );
}

/// Removes audio track [trackId] with its audio clocks, the behaviours and
/// interactions that used it (see `ir.removeAudioTrack`).
class RemoveAudioTrack extends EditCommand {
  const RemoveAudioTrack(this.trackId);

  final String trackId;

  @override
  String get label => 'Remove audio';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.removeAudioTrack(state.document, trackId),
    label: label,
  );
}

// ---- Lyrics --------------------------------------------------------------------

/// Replaces the lyrics of [trackId] with [lyrics] (an LRC import); null or
/// empty clears them.
class SetLyrics extends EditCommand {
  const SetLyrics(this.trackId, this.lyrics);

  final String trackId;
  final ir.LyricsDoc? lyrics;

  @override
  String get label => lyrics == null || lyrics!.lines.isEmpty
      ? 'Clear lyrics'
      : 'Import lyrics';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.setLyrics(state.document, trackId, lyrics),
    label: label,
  );
}

/// Clears the lyrics of [trackId].
class ClearLyrics extends SetLyrics {
  const ClearLyrics(String trackId) : super(trackId, null);
}

/// Replaces line [index] by `change(line)`: text, start and/or end (see
/// `ir.updateLyricLine`).
class UpdateLyricLine extends EditCommand {
  const UpdateLyricLine(
    this.trackId,
    this.index,
    this.change, {
    this.label = 'Edit lyric line',
    this.coalesce = false,
  });

  final String trackId;
  final int index;
  final ir.LyricLine Function(ir.LyricLine line) change;

  @override
  final String label;

  /// Coalesce consecutive edits of this line within a gesture (an edge
  /// drag).
  final bool coalesce;

  @override
  String? get coalesceKey => coalesce ? 'lyric:$trackId:$index' : null;

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateLyricLine(state.document, trackId, index, change),
    label: label,
    coalesceKey: coalesceKey,
  );
}

/// Moves line [index] to start at [start], taking its end and words along
/// (a block drag; clamped between the neighbours).
class MoveLyricLine extends EditCommand {
  const MoveLyricLine(this.trackId, this.index, this.start);

  final String trackId;
  final int index;
  final double start;

  @override
  String get label => 'Move lyric line';

  @override
  String? get coalesceKey => 'lyric:$trackId:$index';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.moveLyricLine(state.document, trackId, index, start),
    label: label,
    coalesceKey: coalesceKey,
  );
}

/// Inserts [line] at its sorted position.
class InsertLyricLine extends EditCommand {
  const InsertLyricLine(this.trackId, this.line);

  final String trackId;
  final ir.LyricLine line;

  @override
  String get label => 'Add lyric line';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.insertLyricLine(state.document, trackId, line),
    label: label,
  );
}

/// Removes line [index].
class RemoveLyricLine extends EditCommand {
  const RemoveLyricLine(this.trackId, this.index);

  final String trackId;
  final int index;

  @override
  String get label => 'Remove lyric line';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.removeLyricLine(state.document, trackId, index),
    label: label,
  );
}

/// Replaces word [word] of line [line] by `change(word)`: its text, start
/// or end (see `ir.updateLyricWord`).
class UpdateLyricWord extends EditCommand {
  const UpdateLyricWord(
    this.trackId,
    this.line,
    this.word,
    this.change, {
    this.label = 'Edit lyric word',
    this.coalesce = false,
  });

  final String trackId;
  final int line;
  final int word;
  final ir.LyricWord Function(ir.LyricWord word) change;

  @override
  final String label;

  final bool coalesce;

  @override
  String? get coalesceKey => coalesce ? 'lyric:$trackId:$line:$word' : null;

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.updateLyricWord(state.document, trackId, line, word, change),
    label: label,
    coalesceKey: coalesceKey,
  );
}

// ---- Behaviours ----------------------------------------------------------------

/// Sets (or, with null, removes) the behaviour of frame [frameId].
class SetBehavior extends EditCommand {
  const SetBehavior(
    this.frameId,
    this.behavior, {
    this.label = 'Set behaviour',
  });

  final String frameId;
  final ir.Behavior? behavior;

  @override
  final String label;

  @override
  String? get coalesceKey => 'behavior:$frameId';

  @override
  CommandResult apply(EditorState state) {
    final node = ir.DocumentIndex.of(state.document).node(frameId);
    if (node is! ir.FrameNode) {
      return failedCommand(state, label, [
        commandError('"$frameId" is not a frame.', nodeId: frameId),
      ]);
    }
    if (node.behavior == behavior) {
      return CommandResult(document: state.document, label: label);
    }
    return resultOf(
      state,
      ir.updateNode(
        state.document,
        frameId,
        (n) => (n as ir.FrameNode).copyWith(behavior: behavior),
      ),
      label: label,
      coalesceKey: coalesceKey,
    );
  }
}

/// Gives text node [textId] a behaviour by wrapping it in a new frame that
/// carries [behavior] (Lyrics and TextReveal live on a frame and act on the
/// text inside). The frame takes the text's place and box; the text stays
/// selected.
class WrapTextInBehavior extends EditCommand {
  const WrapTextInBehavior(this.textId, this.behavior, {this.ids});

  final String textId;
  final ir.Behavior behavior;
  final ir.IdGenerator? ids;

  @override
  String get label => switch (behavior) {
    ir.LyricsBehavior() => 'Add lyrics',
    ir.TextRevealBehavior() => 'Add text reveal',
    _ => 'Add behaviour',
  };

  @override
  CommandResult apply(EditorState state) {
    final gen = ids ?? ir.IdGenerator.forDocument(state.document);
    final r = ir.wrapInFrame(
      state.document,
      [textId],
      (bounds) => ir.FrameNode(
        common: ir.NodeCommon(
          id: gen.next(),
          name: switch (behavior) {
            ir.LyricsBehavior() => 'Lyrics',
            ir.TextRevealBehavior() => 'Text reveal',
            _ => 'Frame',
          },
        ),
        behavior: behavior,
      ),
    );
    return resultOf(state, r, label: label, selectionAfter: {textId});
  }
}
