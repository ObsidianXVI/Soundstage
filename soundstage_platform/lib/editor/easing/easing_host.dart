import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../timeline/timeline_model.dart';
import 'easing_editor.dart';

/// Segments by track: `segments[trackId]` are the ids of the keyframes that
/// start them (the shape `SetSegmentEasing` takes).
typedef EasingSegments = Map<String, Set<String>>;

/// Every segment of tracks [trackIds] of [scene] (each keyframe but the
/// last in time starts one).
EasingSegments segmentsOfTracks(ir.Scene scene, Iterable<String> trackIds) {
  final wanted = trackIds.toSet();
  return {
    for (final t in scene.tracks)
      if (wanted.contains(t.id) && t.keyframes.length > 1)
        t.id: {for (final k in t.keyframes.take(t.keyframes.length - 1)) k.id},
  };
}

/// The segments started by [keyframes] (a keyframe that is the last of its
/// track starts none).
EasingSegments segmentsOfKeyframes(
  ir.Scene scene,
  Iterable<KeyframeRef> keyframes,
) {
  final out = <String, Set<String>>{};
  for (final t in scene.tracks) {
    if (t.keyframes.length < 2) continue;
    final last = t.keyframes.last.id;
    for (final ref in keyframes) {
      if (ref.track == t.id && ref.keyframe != last) {
        if (t.keyframes.any((k) => k.id == ref.keyframe)) {
          (out[t.id] ??= {}).add(ref.keyframe);
        }
      }
    }
  }
  return out;
}

/// The segments an easing editor opened on [clicked] edits: the clicked one
/// alone, or, when it belongs to the keyframe [selection], every selected
/// segment (the editor then shows Mixed if they differ).
EasingSegments segmentsForOpen(
  ir.Scene scene,
  SegmentRef clicked,
  Set<KeyframeRef> selection,
) => selection.contains(clicked)
    ? segmentsOfKeyframes(scene, selection)
    : segmentsOfKeyframes(scene, [clicked]);

/// The easing of each segment of [segments] in [scene] (segments that no
/// longer exist are skipped: a keyframe starts one only while another
/// follows it).
List<ir.Easing> easingsOf(ir.Scene? scene, EasingSegments segments) {
  if (scene == null) return const [];
  return [
    for (final t in scene.tracks)
      for (final k in t.keyframes.take(t.keyframes.length - 1))
        if (segments[t.id]?.contains(k.id) ?? false) k.easing,
  ];
}

/// [EasingEditor] bound to the document of [container]'s editor: it shows
/// the easing of [segments] of scene [sceneId] and writes
/// `SetSegmentEasing`. A handle drag or number scrub is one undo step.
///
/// It is built in the root overlay, outside the editor's provider scope, and
/// a second scope for the same container would flush provider notifications
/// from inside a build. So it takes the [container] and listens to the
/// document itself, deferring its rebuild when the change arrives while the
/// framework is building.
class EasingEditorHost extends StatefulWidget {
  const EasingEditorHost({
    required this.container,
    required this.sceneId,
    required this.segments,
    this.onClose,
    super.key,
  });

  final ProviderContainer container;
  final String sceneId;
  final EasingSegments segments;
  final VoidCallback? onClose;

  @override
  State<EasingEditorHost> createState() => _EasingEditorHostState();
}

class _EasingEditorHostState extends State<EasingEditorHost> {
  ProviderSubscription<Identity<ir.StageDocument>>? _sub;

  EditorController get _editor =>
      widget.container.read(editorControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _sub = widget.container.listen(
      editorControllerProvider.select((s) => Identity(s.document)),
      (_, _) {
        if (!mounted) return;
        if (SchedulerBinding.instance.schedulerPhase ==
            SchedulerPhase.persistentCallbacks) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        } else {
          setState(() {});
        }
      },
    );
  }

  @override
  void dispose() {
    _sub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.container.read(editorControllerProvider).document;
    final scene = doc.scenes.where((s) => s.id == widget.sceneId).firstOrNull;
    final easings = easingsOf(scene, widget.segments);
    if (easings.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onClose?.call();
      });
      return const SizedBox.shrink();
    }
    return EasingEditor(
      easings: easings,
      onClose: widget.onClose,
      onGestureStart: _editor.beginGesture,
      onGestureEnd: _editor.endGesture,
      onChanged: (e) =>
          _editor.execute(SetSegmentEasing(widget.sceneId, widget.segments, e)),
    );
  }
}

/// Opens the easing editor for [segments] of scene [sceneId] in a popover
/// next to [anchor]. Returns the popover's handle.
SsPopoverHandle showEasingEditor(
  BuildContext context, {
  required Rect anchor,
  required String sceneId,
  required EasingSegments segments,
  SsPlacement placement = SsPlacement.belowStart,
  VoidCallback? onClosed,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  late final SsPopoverHandle handle;
  handle = showSsPopover(
    context,
    anchor: anchor,
    placement: placement,
    gap: 6,
    onClosed: onClosed,
    builder: (_) => SsPopoverSurface(
      width: 300,
      padding: const EdgeInsets.all(SsSpace.s3),
      child: SingleChildScrollView(
        child: EasingEditorHost(
          container: container,
          sceneId: sceneId,
          segments: segments,
          onClose: handle.close,
        ),
      ),
    ),
  );
  return handle;
}
