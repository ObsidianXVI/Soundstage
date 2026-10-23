import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../command.dart';
import '../editor_state.dart';

// Scene commands (architecture §3.2, §15).

/// Adds a blank scene at [index] (null: after the active scene, else last)
/// and makes it active. Its stage root is sized to the first primary
/// breakpoint's design size and it has its own scroll clock.
class AddScene extends EditCommand {
  const AddScene({
    this.index,
    this.kind = ir.SceneKind.pinned,
    this.name = '',
    this.ids,
  });

  final int? index;
  final ir.SceneKind kind;
  final String name;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Add scene';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final bpId = defaultBreakpointId(doc);
    if (bpId == null) {
      return failedCommand(state, label, [
        commandError('The document has no breakpoint to size a scene by.'),
      ]);
    }
    final bp = doc.breakpoints.firstWhere((b) => b.id == bpId);
    final gen = ids ?? ir.IdGenerator.forDocument(doc);
    var scene = ir.Scene.blankPinned(ids: gen, breakpoint: bp, name: name);
    if (kind == ir.SceneKind.flow) {
      scene = scene.copyWith(kind: ir.SceneKind.flow, scrollLength: 0);
    }
    final active = ir.DocumentIndex.of(
      doc,
    ).sceneIndexOf(state.activeSceneId ?? '');
    final at = index ?? (active == null ? doc.scenes.length : active + 1);
    final r = ir.insertScene(doc, at, scene);
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: const {},
      activeSceneAfter: scene.id,
    );
  }
}

/// Deletes a scene. The last scene can't be deleted. When it was active,
/// the scene after it (else before it) becomes active.
class DeleteScene extends EditCommand {
  const DeleteScene(this.sceneId);

  final String sceneId;

  @override
  String get label => 'Delete scene';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final i = ir.DocumentIndex.of(doc).sceneIndexOf(sceneId);
    if (i != null && doc.scenes.length == 1) {
      return failedCommand(state, label, [
        commandError('A story needs at least one scene.'),
      ]);
    }
    final r = ir.removeScene(doc, sceneId);
    String? next;
    if (i != null && state.activeSceneId == sceneId) {
      next = doc.scenes[i + 1 < doc.scenes.length ? i + 1 : i - 1].id;
    }
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: next == null ? null : const {},
      activeSceneAfter: next,
    );
  }
}

/// Moves a scene to insertion point [index] (a drop indicator in the
/// scenes panel; counts the scene itself).
class MoveScene extends EditCommand {
  const MoveScene(this.sceneId, this.index);

  final String sceneId;
  final int index;

  @override
  String get label => 'Move scene';

  @override
  CommandResult apply(EditorState state) => resultOf(
    state,
    ir.moveScene(state.document, sceneId, index),
    label: label,
  );
}

/// Changes a scene's settings; null fields are left as they are.
/// [posterClock] is a record so it can be cleared: `(value: null)` resets
/// it to the default.
class UpdateSceneSettings extends EditCommand {
  const UpdateSceneSettings(
    this.sceneId, {
    this.name,
    this.kind,
    this.scrollLength,
    this.exportAs,
    this.posterClock,
    this.background,
    this.transitionIn,
  });

  final String sceneId;
  final String? name;
  final ir.SceneKind? kind;
  final double? scrollLength;
  final ir.SceneExportMode? exportAs;
  final ({double? value})? posterClock;
  final List<ir.Paint>? background;
  final ir.SceneTransition? transitionIn;

  @override
  String get label => 'Change scene settings';

  @override
  String get coalesceKey => 'scene:$sceneId';

  @override
  CommandResult apply(EditorState state) {
    if (scrollLength case final l? when l < 0) {
      return failedCommand(state, label, [
        commandError('Scroll length must not be negative.'),
      ]);
    }
    final r = ir.updateScene(state.document, sceneId, (s) {
      final next = s.copyWith(
        name: name ?? s.name,
        kind: kind ?? s.kind,
        scrollLength: scrollLength ?? s.scrollLength,
        exportAs: exportAs ?? s.exportAs,
        posterClock: posterClock == null ? s.posterClock : posterClock!.value,
        background: background ?? s.background,
        transitionIn: transitionIn ?? s.transitionIn,
      );
      return next == s ? s : next;
    });
    return resultOf(state, r, label: label, coalesceKey: coalesceKey);
  }
}
