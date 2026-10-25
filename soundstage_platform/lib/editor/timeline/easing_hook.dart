import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../core/editor_controller.dart';
import '../easing/easing_host.dart';
import 'timeline_math.dart';
import 'timeline_model.dart';

/// Where the easing editor opens from the timeline (m2.md "Easing editor"):
/// double-clicking a segment in the lanes sets
/// `TimelineController.easingSegment`, and the timeline shows this chip for
/// it while the editor is open.
///
/// The chip opens the [EasingEditorHost] popover when it appears (and again
/// when it is tapped) and calls [onClose] once the popover closes. The
/// editor acts on the segment, or on every selected segment when the
/// segment is part of the keyframe selection (the Mixed state when their
/// easings differ).
class EasingHook extends ConsumerStatefulWidget {
  const EasingHook({required this.segment, required this.onClose, super.key});

  final SegmentRef segment;
  final VoidCallback onClose;

  @override
  ConsumerState<EasingHook> createState() => _EasingHookState();
}

class _EasingHookState extends ConsumerState<EasingHook> {
  SsPopoverHandle? _popover;
  late EasingSegments _segments;
  late String _sceneId;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    final scene = ref.read(editorControllerProvider).activeScene;
    _sceneId = scene?.id ?? '';
    _segments = scene == null
        ? const {}
        : segmentsForOpen(
            scene,
            widget.segment,
            ref.read(timelineControllerProvider).selection.value,
          );
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  @override
  void dispose() {
    _disposed = true;
    _popover?.close();
    super.dispose();
  }

  void _open() {
    if (!mounted || (_popover?.isOpen ?? false) || _segments.isEmpty) return;
    _popover = showEasingEditor(
      context,
      anchor: ssGlobalRect(context),
      sceneId: _sceneId,
      segments: _segments,
      onClosed: () {
        _popover = null;
        if (!_disposed) widget.onClose();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final label = ref.watch(
      editorControllerProvider.select((s) {
        final names = {
          for (final e in easingsOf(s.activeScene, _segments)) easingName(e),
        };
        return names.isEmpty
            ? null
            : names.length == 1
            ? names.single
            : 'Mixed';
      }),
    );
    if (label == null) return const SizedBox.shrink();
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
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _open,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Easing: ', style: t.text.caption),
                Text(label, style: t.text.small),
              ],
            ),
          ),
          SsIconButton(
            icon: SsIcons.x,
            semanticLabel: 'Close easing',
            size: 22,
            iconSize: 12,
            onPressed: () {
              final open = _popover;
              if (open != null) {
                open.close();
              } else {
                widget.onClose();
              }
            },
          ),
        ],
      ),
    );
  }
}
