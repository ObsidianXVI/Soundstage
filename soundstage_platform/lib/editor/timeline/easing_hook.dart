import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../core/editor_controller.dart';
import 'timeline_math.dart';
import 'timeline_model.dart';

/// Where the easing editor opens (m2.md "Easing editor"): double-clicking a
/// segment in the lanes sets `TimelineController.easingSegment`, and the
/// timeline shows this widget for it until it is closed.
///
/// Placeholder for T2.3, which builds the editor (presets, bezier handles,
/// spring, steps, hold) here. For now it names the segment's easing.
class EasingHook extends ConsumerWidget {
  const EasingHook({required this.segment, required this.onClose, super.key});

  final SegmentRef segment;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final easing = ref.watch(
      editorControllerProvider.select((s) {
        final scene = s.activeScene;
        if (scene == null) return null;
        for (final tr in scene.tracks) {
          if (tr.id != segment.track) continue;
          for (final k in tr.keyframes) {
            if (k.id == segment.keyframe) return k.easing;
          }
        }
        return null;
      }),
    );
    if (easing == null) return const SizedBox.shrink();
    return Container(
      key: const ValueKey<String>('easing-hook'),
      height: 24,
      padding: const EdgeInsets.only(left: SsSpace.s2),
      decoration: BoxDecoration(
        color: t.colors.surface2,
        borderRadius: SsRadius.brSm,
        border: Border.all(color: t.colors.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Easing: ', style: t.text.caption),
          Text(easingName(easing), style: t.text.small),
          SsIconButton(
            icon: SsIcons.x,
            semanticLabel: 'Close easing',
            size: 22,
            iconSize: 12,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
