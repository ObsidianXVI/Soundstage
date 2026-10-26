import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../core/core.dart';

/// The canvas with, in isolation mode, a bar naming the component being
/// edited and leading back to the story (m3.md T3.2).
class IsolationFrame extends ConsumerWidget {
  const IsolationFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final iso = ref.watch(editorControllerProvider.select((s) => s.isolation));
    if (iso == null) return child;
    final name = ref.watch(
      editorControllerProvider.select(
        (s) => s.document.components[iso.componentId]?.name ?? 'Component',
      ),
    );
    final t = context.ss;
    final ctl = ref.read(editorControllerProvider.notifier);
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: SsSpace.s2,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              key: const ValueKey<String>('isolation-bar'),
              padding: const EdgeInsets.symmetric(
                horizontal: SsSpace.s2,
                vertical: SsSpace.s1,
              ),
              decoration: BoxDecoration(
                color: t.colors.surface2,
                borderRadius: SsRadius.brMd,
                border: Border.all(
                  color: t.colors.accentText.withValues(alpha: 0.5),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SsButton(
                    label: 'Story',
                    icon: SsIcons.arrowLeft,
                    variant: SsButtonVariant.ghost,
                    onPressed: ctl.exitComponent,
                  ),
                  SsIcon(
                    SsIcons.chevronRight,
                    size: 12,
                    color: t.colors.textSecondary,
                  ),
                  const SizedBox(width: SsSpace.s1),
                  SsIcon(
                    SsIcons.component,
                    size: 14,
                    color: t.colors.accentText,
                  ),
                  const SizedBox(width: SsSpace.s1),
                  Text(name, style: t.text.bodyStrong),
                  const SizedBox(width: SsSpace.s3),
                  SsButton(
                    key: const ValueKey<String>('isolation-done'),
                    label: 'Done',
                    variant: SsButtonVariant.primary,
                    onPressed: ctl.exitComponent,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
