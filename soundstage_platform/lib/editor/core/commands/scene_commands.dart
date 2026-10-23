import 'dart:convert';

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

/// Duplicates a scene right after the original, with fresh ids for the
/// scene and everything inside it (nodes, clocks, tracks, paints,
/// interactions), and makes the copy active. References inside the copy
/// (a track's target, a scroll clock's scene, property paths naming a paint)
/// follow the new ids; references to anything outside the scene (assets,
/// components, tokens, other scenes) are kept.
class DuplicateScene extends EditCommand {
  const DuplicateScene(this.sceneId, {this.ids});

  final String sceneId;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Duplicate scene';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final i = ir.DocumentIndex.of(doc).sceneIndexOf(sceneId);
    if (i == null) {
      return failedCommand(state, label, [
        commandError('Scene "$sceneId" does not exist.'),
      ]);
    }
    final gen = ids ?? ir.IdGenerator.forDocument(doc);
    // A full JSON tree (the generated `toJson` leaves nested objects).
    final json = jsonDecode(jsonEncode(doc.scenes[i]));
    // Every `id` value inside the scene names something that needs a copy.
    final idMap = <String, String>{};
    void collect(Object? v) {
      switch (v) {
        case final Map<Object?, Object?> m:
          for (final e in m.entries) {
            if (e.key == 'id' && e.value is String) {
              idMap.putIfAbsent(e.value! as String, gen.next);
            }
            collect(e.value);
          }
        case final Iterable<Object?> l:
          l.forEach(collect);
        default:
      }
    }

    collect(json);
    final token = RegExp(r'(?<![A-Za-z0-9_])[A-Za-z0-9_]+(?![A-Za-z0-9_])');
    String remap(String s) =>
        s.replaceAllMapped(token, (m) => idMap[m[0]] ?? m[0]!);
    Object? rewrite(Object? v) => switch (v) {
      final String s => remap(s),
      final Map<Object?, Object?> m => <String, Object?>{
        for (final e in m.entries)
          // Keys are field names, except the generated-id ones.
          (ir.isGeneratedId(e.key! as String)
              ? remap(e.key! as String)
              : e.key! as String): rewrite(
            e.value,
          ),
      },
      final List<Object?> l => [for (final x in l) rewrite(x)],
      _ => v,
    };
    var copy = ir.Scene.fromJson(
      (rewrite(json)! as Map<Object?, Object?>).cast<String, dynamic>(),
    );
    copy = copy.copyWith(
      name: doc.scenes[i].name.isEmpty ? '' : '${doc.scenes[i].name} copy',
    );
    final r = ir.insertScene(doc, i + 1, copy);
    return resultOf(
      state,
      r,
      label: label,
      selectionAfter: const {},
      activeSceneAfter: copy.id,
    );
  }
}
