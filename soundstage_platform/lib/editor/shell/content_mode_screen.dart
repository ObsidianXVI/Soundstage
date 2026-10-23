import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// What `/edit/:id` shows below [kEditorMinWidth]: a stand-in for content
/// mode (in-place text editing and media-slot replacement), which arrives
/// in T1.13. Today it lists the scenes and points to the player.
///
/// This widget is the seam: T1.13 replaces its body, and its inputs (the
/// document, a play action and a back action) stay.
class ContentModeScreen extends StatelessWidget {
  const ContentModeScreen({
    required this.title,
    required this.scenes,
    required this.onPlay,
    required this.onBack,
    super.key,
  });

  final String title;
  final List<ir.Scene> scenes;

  /// Opens the player (`/play/:id`).
  final VoidCallback onPlay;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return ColoredBox(
      color: c.surface0,
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(SsSpace.s4),
              children: [
                Row(
                  children: [
                    SsIconButton(
                      icon: SsIcons.arrowLeft,
                      semanticLabel: 'Back to stories',
                      onPressed: onBack,
                    ),
                    const SizedBox(width: SsSpace.s2),
                    Expanded(
                      child: Text(
                        title,
                        key: const ValueKey<String>('content-mode-title'),
                        style: t.text.heading,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SsSpace.s5),
                Container(
                  padding: const EdgeInsets.all(SsSpace.s4),
                  decoration: BoxDecoration(
                    color: c.surface1,
                    borderRadius: SsRadius.brLg,
                    border: Border.all(color: c.border),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SsIcon(SsIcons.monitor, size: 20, color: c.accentText),
                      const SizedBox(width: SsSpace.s3),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Content mode', style: t.text.bodyStrong),
                            const SizedBox(height: SsSpace.s1),
                            Text(
                              'Layout and motion editing need a larger window '
                              '(at least 1024 px wide). Here you will be able '
                              'to edit text and swap images in place.',
                              key: const ValueKey<String>('content-mode-note'),
                              style: t.text.body.copyWith(
                                color: c.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: SsSpace.s4),
                SsButton(
                  label: 'Play story',
                  icon: SsIcons.play,
                  variant: SsButtonVariant.primary,
                  onPressed: onPlay,
                ),
                const SizedBox(height: SsSpace.s6),
                Text('SCENES', style: t.text.overline),
                const SizedBox(height: SsSpace.s2),
                if (scenes.isEmpty)
                  Text(
                    'This story has no scenes yet.',
                    style: t.text.body.copyWith(color: c.textSecondary),
                  )
                else
                  for (var i = 0; i < scenes.length; i++)
                    SsTreeRow(
                      icon: SsIcons.clapperboard,
                      label: scenes[i].name.isEmpty
                          ? 'Scene ${i + 1}'
                          : scenes[i].name,
                      showToggles: false,
                      renameEnabled: false,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
