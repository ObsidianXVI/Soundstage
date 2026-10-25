import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../easing/easing_host.dart';
import '../../insert/editor_notices.dart';
import '../../motion/motion_preset_dialog.dart';
import '../../motion/motion_presets.dart';
import '../../timeline/timeline_math.dart';
import '../../timeline/timeline_model.dart';
import '../inspector_providers.dart';
import '../section_registry.dart';
import 'clock_fields.dart' show FitLeft;

/// The selected nodes' tracks (m2.md "Inspector": a Motion section lists
/// them with clock and easing summary, plus "Add preset…"): one row per
/// track of the active scene that targets a selected node, with its
/// property's name, clock, keyframe count and easing; delete removes the
/// track (one undo step). Clicking a row shows its clock in the timeline.
/// A track's easing button opens the easing editor on all its segments, and
/// when keyframes of these tracks are selected in the timeline another
/// button opens it on exactly those segments (Mixed if they differ).
/// "Add preset…" asks for a motion preset and writes it onto the selected
/// nodes as ordinary tracks, in one undo step.
final InspectorSectionSpec motionSection = InspectorSectionSpec(
  id: 'motion',
  title: 'Motion',
  appliesTo: (info) => !info.isEmpty,
  builder: (context, info) => _MotionBody(info: info),
);

class _MotionBody extends ConsumerWidget {
  const _MotionBody({required this.info});

  final SelectionInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final doc = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    final scene = ref.watch(
      editorControllerProvider.select((s) => s.activeScene),
    );
    final editor = ref.read(editorControllerProvider.notifier);
    final ids = info.ids.toSet();
    final tracks = [
      for (final tr in scene?.tracks ?? const <ir.Track>[])
        if (ids.contains(tr.target)) tr,
    ];
    final index = ir.DocumentIndex.of(doc);
    final many = ids.length > 1;
    return Column(
      key: const ValueKey<String>('motion-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tracks.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: SsSpace.s2),
            child: Text(
              'Not animated. Add a keyframe with ◇ beside a property, or '
              'turn on auto-key.',
              style: t.text.caption,
            ),
          ),
        for (final tr in tracks)
          _TrackRow(
            key: ValueKey<String>('motion-track:${tr.id}'),
            title: many
                ? '${timelineNodeName(index, tr.target)} · ${laneLabel(doc, tr)}'
                : laneLabel(doc, tr),
            detail: [
              clockLabel(
                doc,
                scene!.clocks.firstWhere(
                  (k) => k.id == tr.clockId,
                  orElse: () => scene.clocks.first,
                ),
              ),
              tr.keyframes.length == 1
                  ? '1 keyframe'
                  : '${tr.keyframes.length} keyframes',
              easingSummary(tr),
            ].join(' · '),
            onTap: () => editor.setActiveClock(scene.id, tr.clockId),
            onEasing: tr.keyframes.length < 2
                ? null
                : (anchor) => showEasingEditor(
                    context,
                    anchor: anchor,
                    sceneId: scene.id,
                    segments: segmentsOfTracks(scene, [tr.id]),
                    placement: SsPlacement.rightStart,
                  ),
            onDelete: () => editor.execute(RemoveTracks(scene.id, [tr.id])),
          ),
        if (scene != null) _SelectedKeyframesEasing(scene: scene),
        const SizedBox(height: SsSpace.s1),
        Align(
          alignment: Alignment.centerLeft,
          child: SsButton(
            key: const ValueKey<String>('motion-add-preset'),
            label: 'Add preset…',
            icon: SsIcons.plus,
            onPressed: scene == null
                ? null
                : () => _addPreset(context, ref, doc, scene, ids),
          ),
        ),
      ],
    );
  }

  Future<void> _addPreset(
    BuildContext context,
    WidgetRef ref,
    ir.StageDocument doc,
    ir.Scene scene,
    Set<String> ids,
  ) async {
    final editor = ref.read(editorControllerProvider.notifier);
    final clocks = presetClocksOf(doc, scene);
    if (clocks.isEmpty) return;
    final active = ref.read(editorControllerProvider).activeClockOf(scene.id);
    final initial = clocks.any((c) => c.clock.id == active)
        ? active!
        : clocks.first.clock.id;
    final spec = await showMotionPresetDialog(
      context,
      clocks: clocks,
      initialClockId: initial,
    );
    if (spec == null) return;
    final r = editor.execute(ApplyMotionPreset(scene.id, ids.toList(), spec));
    final notices = ref.read(editorNoticesProvider);
    if (!r.ok) {
      notices.say(
        r.diagnostics.firstOrNull?.message ?? 'The preset was not applied.',
      );
      return;
    }
    for (final w in r.diagnostics.where(
      (d) => d.severity == ir.IrSeverity.warning,
    )) {
      notices.say(w.message);
    }
    editor.setActiveClock(scene.id, spec.clockId);
  }
}

/// "Easing of selected keyframes…": shown while keyframes of the shown
/// tracks are selected in the timeline.
class _SelectedKeyframesEasing extends ConsumerWidget {
  const _SelectedKeyframesEasing({required this.scene});

  final ir.Scene scene;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tl = ref.watch(timelineControllerProvider);
    return ValueListenableBuilder<Set<KeyframeRef>>(
      valueListenable: tl.selection,
      builder: (context, selection, _) {
        final segments = segmentsOfKeyframes(scene, selection);
        if (segments.isEmpty) return const SizedBox.shrink();
        final n = segments.values.fold<int>(0, (a, b) => a + b.length);
        return Padding(
          padding: const EdgeInsets.only(top: SsSpace.s1),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FitLeft(
              child: Builder(
                builder: (ctx) => SsButton(
                  key: const ValueKey<String>('motion-selected-easing'),
                  label: n == 1
                      ? 'Selected segment easing…'
                      : 'Selected segments easing…',
                  icon: SsIcons.slidersHorizontal,
                  onPressed: () => showEasingEditor(
                    ctx,
                    anchor: ssGlobalRect(ctx),
                    sceneId: scene.id,
                    segments: segments,
                    placement: SsPlacement.rightStart,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.title,
    required this.detail,
    required this.onTap,
    required this.onEasing,
    required this.onDelete,
    super.key,
  });

  final String title;
  final String detail;
  final VoidCallback onTap;

  /// Opens the easing editor next to the given anchor (null: the track has
  /// no segment).
  final void Function(Rect anchor)? onEasing;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s1),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.text.small,
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.text.caption,
                  ),
                ],
              ),
            ),
          ),
          Builder(
            builder: (ctx) => SsIconButton(
              key: ValueKey<String>('motion-easing:$title'),
              icon: SsIcons.slidersHorizontal,
              semanticLabel: 'Edit easing of $title',
              size: 24,
              iconSize: 14,
              onPressed: onEasing == null
                  ? null
                  : () => onEasing!(ssGlobalRect(ctx)),
            ),
          ),
          SsIconButton(
            icon: SsIcons.trash2,
            semanticLabel: 'Delete track $title',
            size: 24,
            iconSize: 14,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}
