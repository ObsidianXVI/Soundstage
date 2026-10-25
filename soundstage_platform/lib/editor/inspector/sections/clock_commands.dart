import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';

// Commands and queries of the Clocks UI (m2.md T2.4). They sit beside the
// section rather than in `core/commands` so the section can be built without
// touching the shared command library; they are ordinary [EditCommand]s.

/// Adds several clocks as one undo step (a pointer clock for both axes).
class AddClocks extends EditCommand {
  const AddClocks(this.sceneId, this.clocks);

  final String sceneId;
  final List<ir.Clock> clocks;

  @override
  String get label => clocks.length == 1 ? 'Add clock' : 'Add clocks';

  @override
  CommandResult apply(EditorState state) {
    var doc = state.document;
    final diagnostics = <ir.IrDiagnostic>[];
    for (final c in clocks) {
      final r = ir.addClock(doc, sceneId, c);
      if (!r.ok) return failedCommand(state, label, r.diagnostics);
      doc = r.document;
      diagnostics.addAll(r.diagnostics);
    }
    return CommandResult(
      document: doc,
      label: label,
      changed: doc != state.document,
      diagnostics: diagnostics,
    );
  }
}

/// Scales the keyframe times of every track on timeline clock [clockId] so
/// the last keyframe lands on [duration] (the "Scale keyframes to fit"
/// action). One command, one undo step.
class ScaleClockKeyframes extends EditCommand {
  const ScaleClockKeyframes(this.sceneId, this.clockId, this.duration);

  final String sceneId;
  final String clockId;
  final double duration;

  @override
  String get label => 'Scale keyframes to fit';

  @override
  CommandResult apply(EditorState state) {
    final scene = state.document.scenes.where((s) => s.id == sceneId);
    if (scene.isEmpty) return failedCommand(state, label, const []);
    final tracks = tracksOnClock(scene.first, clockId);
    final last = lastKeyframeTime(tracks);
    if (last <= 0 || duration <= 0 || last == duration) {
      return CommandResult(document: state.document, label: label);
    }
    final k = duration / last;
    final changes = <String, Map<String, ir.Keyframe Function(ir.Keyframe)>>{
      for (final t in tracks)
        t.id: {
          for (final kf in t.keyframes)
            kf.id: (old) =>
                old.copyWith(t: old.t == last ? duration : old.t * k),
        },
    };
    return resultOf(
      state,
      ir.updateKeyframes(state.document, sceneId, changes),
      label: label,
    );
  }
}

// ---- Queries ----------------------------------------------------------------

/// The tracks of [scene] that run on [clockId].
List<ir.Track> tracksOnClock(ir.Scene scene, String clockId) => [
  for (final t in scene.tracks)
    if (t.clockId == clockId) t,
];

/// The latest keyframe time among [tracks] (0 when there are none).
double lastKeyframeTime(Iterable<ir.Track> tracks) {
  var last = 0.0;
  for (final t in tracks) {
    for (final k in t.keyframes) {
      if (k.t > last) last = k.t;
    }
  }
  return last;
}

/// How many keyframes on [clockId] lie after [duration].
int keyframesPastEnd(ir.Scene scene, String clockId, double duration) {
  var n = 0;
  for (final t in tracksOnClock(scene, clockId)) {
    for (final k in t.keyframes) {
      if (k.t > duration + ir.kKeyframeTimeEpsilon) n++;
    }
  }
  return n;
}

/// The frames of [scene] a pointer clock can be bound to (id, display name).
List<({String id, String name})> sceneFrames(ir.Scene scene) {
  final out = <({String id, String name})>[];
  void walk(ir.Node n) {
    if (n is ir.FrameNode) {
      final name = n.common.name;
      out.add((id: n.id, name: name.isEmpty ? n.id : name));
      n.children.forEach(walk);
    }
  }

  walk(scene.root);
  return out;
}
