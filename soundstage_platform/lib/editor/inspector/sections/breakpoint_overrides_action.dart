import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../../core/core.dart';

/// The inspector header action "Reset overrides on Tablet" (T1.10):
/// shown while a selected layer has a patch on the breakpoint in effect on
/// the edited artboard; clears all of their patches there (one undo step).
/// Per-field resets stay on each field's value-source dot.
class ResetOverridesAction extends ConsumerWidget {
  const ResetOverridesAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(
      editorControllerProvider.select((s) {
        final bp = s.breakpointId;
        return hasOverridesOn(s.document, s.selection, bp)
            ? breakpointName(s.document, bp)
            : null;
      }),
    );
    if (info == null) return const SizedBox.shrink();
    final label = 'Reset overrides on $info';
    return SsIconButton(
      key: const ValueKey<String>('reset-breakpoint-overrides'),
      icon: SsIcons.rotateCcw,
      semanticLabel: label,
      tooltip: label,
      size: 24,
      iconSize: 14,
      onPressed: () {
        final ctl = ref.read(editorControllerProvider.notifier);
        ctl.execute(
          ResetBreakpointOverrides(
            ref.read(editorControllerProvider).selection.toList(),
          ),
        );
      },
    );
  }
}
