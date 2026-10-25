import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../../timeline/timeline_math.dart';
import '../../timeline/timeline_model.dart';
import '../inspector_providers.dart';
import '../section_registry.dart';

/// The selected nodes' tracks (m2.md "Inspector": a Motion section lists
/// them with clock and easing summary, plus "Add preset…"): one row per
/// track of the active scene that targets a selected node, with its
/// property's name, clock, keyframe count and easing; delete removes the
/// track (one undo step). Clicking a row shows its clock in the timeline.
/// "Add preset…" is the hook for T2.3's motion presets.
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
            onDelete: () => editor.execute(RemoveTracks(scene.id, [tr.id])),
          ),
        const SizedBox(height: SsSpace.s1),
        const Align(
          alignment: Alignment.centerLeft,
          child: SsTooltip(
            message:
                'Motion presets (fade, rise, slide, …) arrive with the '
                'easing editor',
            child: SsButton(
              key: ValueKey<String>('motion-add-preset'),
              label: 'Add preset…',
              icon: SsIcons.plus,
            ),
          ),
        ),
      ],
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.title,
    required this.detail,
    required this.onTap,
    required this.onDelete,
    super.key,
  });

  final String title;
  final String detail;
  final VoidCallback onTap;
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
