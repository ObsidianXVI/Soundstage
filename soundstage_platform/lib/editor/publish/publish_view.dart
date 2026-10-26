import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../preview/preview_pane.dart';

/// An action of the Publish page that the app supplies (an export, a
/// copy): it gets the current story document.
class EditorPublishAction {
  const EditorPublishAction({
    required this.label,
    required this.icon,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final ValueChanged<ir.StageDocument> onSelected;
}

/// Publish mode (m5.md T5.1): the live player at full size with the width
/// and tier pickers (Full / Lite / Static are what readers get at their
/// published link with `?tier=`), and beside it Publish and the app's
/// exports.
class PublishView extends ConsumerWidget {
  const PublishView({
    this.onPublish,
    this.actions = const [],
    this.onOpenInNewTab,
    super.key,
  });

  /// Publishes the current document; null in a local-only build.
  final ValueChanged<ir.StageDocument>? onPublish;
  final List<EditorPublishAction> actions;
  final VoidCallback? onOpenInNewTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    ir.StageDocument doc() => ref.read(editorControllerProvider).storyDocument;
    return Row(
      key: const ValueKey<String>('publish-view'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: PreviewPane(onOpenInNewTab: onOpenInNewTab)),
        Container(
          width: 280,
          decoration: BoxDecoration(
            color: t.colors.surface1,
            border: Border(left: BorderSide(color: t.colors.borderSubtle)),
          ),
          child: ListView(
            padding: const EdgeInsets.all(SsSpace.s4),
            children: [
              Text('Publish', style: t.text.title),
              const SizedBox(height: SsSpace.s2),
              Text(
                onPublish == null
                    ? 'Publishing needs the hosted build. Exports work here.'
                    : 'Readers get the full story at its link, and the lite '
                          'and static versions with ?tier=lite or '
                          '?tier=static. Preview them on the left.',
                style: t.text.small.copyWith(color: t.colors.textSecondary),
              ),
              if (onPublish case final publish?) ...[
                const SizedBox(height: SsSpace.s3),
                SsButton(
                  key: const ValueKey<String>('publish-view-publish'),
                  label: 'Publish…',
                  icon: SsIcons.globe,
                  variant: SsButtonVariant.primary,
                  onPressed: () => publish(doc()),
                ),
              ],
              if (actions.isNotEmpty) ...[
                const SizedBox(height: SsSpace.s5),
                Text('EXPORT', style: t.text.overline),
                const SizedBox(height: SsSpace.s2),
                for (final a in actions)
                  Padding(
                    padding: const EdgeInsets.only(bottom: SsSpace.s1),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SsButton(
                        label: a.label,
                        icon: a.icon,
                        variant: SsButtonVariant.ghost,
                        onPressed: () => a.onSelected(doc()),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
