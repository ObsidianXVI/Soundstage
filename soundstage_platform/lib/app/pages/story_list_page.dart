import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'demo_page.dart';

/// `/`: the story list. Lists the author's stories (in memory until T1.11)
/// and the bundled demos; "New story" creates a blank document.
class StoryListPage extends ConsumerWidget {
  const StoryListPage({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final repo = ref.read(storyRepositoryProvider);
    final s = await repo.create();
    ref.read(storyListRevisionProvider.notifier).bump();
    if (context.mounted) context.go('/edit/${s.id}');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final stories = ref.watch(storyListProvider);
    return Scaffold(
      backgroundColor: c.surface0,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: SsSpace.s4,
                vertical: SsSpace.s8,
              ),
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: SsSpace.s3,
                  children: [
                    Text('Stories', style: t.text.heading),
                    SsButton(
                      label: 'New story',
                      icon: SsIcons.plus,
                      variant: SsButtonVariant.primary,
                      onPressed: () => _create(context, ref),
                    ),
                  ],
                ),
                const SizedBox(height: SsSpace.s6),
                switch (stories) {
                  AsyncData(:final value) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [for (final s in value) _StoryRow(story: s)],
                  ),
                  AsyncError(:final error) => Text(
                    'Could not load stories: $error',
                    style: t.text.body.copyWith(color: c.danger),
                  ),
                  _ => const SizedBox(height: 120),
                },
                const SizedBox(height: SsSpace.s8),
                Text('DEVELOPMENT', style: t.text.overline),
                const SizedBox(height: SsSpace.s2),
                Wrap(
                  spacing: SsSpace.s2,
                  runSpacing: SsSpace.s2,
                  children: [
                    for (final d in kDemoNames)
                      SsButton(
                        label: d,
                        variant: SsButtonVariant.ghost,
                        onPressed: () => context.go('/demo/$d'),
                      ),
                    SsButton(
                      label: 'design system',
                      variant: SsButtonVariant.ghost,
                      onPressed: () => context.go('/demo/design-system'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StoryRow extends ConsumerWidget {
  const _StoryRow({required this.story});

  final StorySummary story;

  List<SsMenuEntry> _menu(BuildContext context, WidgetRef ref) => [
    SsMenuItem(
      label: 'Open',
      icon: SsIcons.pencil,
      onSelected: () => context.go('/edit/${story.id}'),
    ),
    SsMenuItem(
      label: 'Play',
      icon: SsIcons.play,
      onSelected: () => context.go('/play/${story.id}'),
    ),
    const SsMenuDivider(),
    SsMenuItem(
      label: 'Rename',
      icon: SsIcons.pencil,
      onSelected: () => _rename(context, ref),
    ),
    SsMenuItem(
      label: 'Delete',
      icon: SsIcons.trash2,
      danger: true,
      onSelected: () => _delete(context, ref),
    ),
  ];

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: story.title);
    final name = await showSsDialog<String>(
      context,
      builder: (ctx) => SsDialog(
        title: 'Rename story',
        content: SsTextField(
          controller: controller,
          autofocus: true,
          selectAllOnFocus: true,
          semanticLabel: 'Story name',
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          SsButton(label: 'Cancel', onPressed: () => Navigator.of(ctx).pop()),
          SsButton(
            label: 'Rename',
            variant: SsButtonVariant.primary,
            onPressed: () => Navigator.of(ctx).pop(controller.text),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await ref.read(storyRepositoryProvider).rename(story.id, name.trim());
    ref.read(storyListRevisionProvider.notifier).bump();
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showSsConfirm(
      context,
      title: 'Delete "${story.title}"?',
      message: 'This cannot be undone.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok) return;
    await ref.read(storyRepositoryProvider).delete(story.id);
    ref.read(storyListRevisionProvider.notifier).bump();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final meta = [
      if (story.bundled) 'Bundled demo' else 'Draft',
      if (story.sceneCount != null)
        '${story.sceneCount} ${story.sceneCount == 1 ? 'scene' : 'scenes'}',
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: SsContextMenuRegion(
        entries: () => _menu(context, ref),
        child: SsInteractive(
          semanticLabel: '${story.title}, $meta',
          onTap: () => context.go('/edit/${story.id}'),
          builder: (context, s) => SsFocusRing(
            visible: s.contains(WidgetState.focused),
            color: c.focusRing,
            borderRadius: SsRadius.brLg,
            child: AnimatedContainer(
              duration: SsMotion.fast,
              padding: const EdgeInsets.fromLTRB(
                SsSpace.s4,
                SsSpace.s3,
                SsSpace.s2,
                SsSpace.s3,
              ),
              decoration: BoxDecoration(
                color: s.contains(WidgetState.hovered)
                    ? c.surface2
                    : c.surface1,
                borderRadius: SsRadius.brLg,
                border: Border.all(color: c.borderSubtle),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          story.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.text.bodyStrong,
                        ),
                        const SizedBox(height: 2),
                        Text(meta, style: t.text.caption),
                      ],
                    ),
                  ),
                  SsIconButton(
                    icon: SsIcons.play,
                    semanticLabel: 'Play ${story.title}',
                    onPressed: () => context.go('/play/${story.id}'),
                  ),
                  Builder(
                    builder: (btnContext) => SsIconButton(
                      icon: SsIcons.ellipsis,
                      semanticLabel: 'More actions for ${story.title}',
                      onPressed: () => showSsMenu(
                        btnContext,
                        anchor: ssGlobalRect(btnContext),
                        placement: SsPlacement.belowEnd,
                        entries: _menu(context, ref),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
