import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart' show cloudProvider;
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/app/export/static_export.dart'
    show StaticExportFormat;
import 'package:soundstage_platform/app/persistence/providers.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'cloud_ui.dart' show AccountButton;
import 'demo_page.dart';
import 'story_actions.dart';

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
                    Wrap(
                      spacing: SsSpace.s2,
                      children: [
                        const AccountButton(),
                        SsButton(
                          label: 'Import',
                          icon: SsIcons.file,
                          onPressed: () => StoryActions(context, ref).import(),
                        ),
                        SsButton(
                          label: 'New story',
                          icon: SsIcons.plus,
                          variant: SsButtonVariant.primary,
                          onPressed: () => _create(context, ref),
                        ),
                      ],
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
                const SizedBox(height: SsSpace.s6),
                const _StorageFooter(),
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

  List<SsMenuEntry> _menu(BuildContext context, WidgetRef ref) {
    final actions = StoryActions(context, ref);
    return [
      SsMenuItem(
        label: story.bundled ? 'Open (read-only)' : 'Open',
        icon: SsIcons.pencil,
        onSelected: () => actions.open(story),
      ),
      SsMenuItem(
        label: 'Play',
        icon: SsIcons.play,
        onSelected: () => context.go('/play/${story.id}'),
      ),
      const SsMenuDivider(),
      SsMenuItem(
        label: story.bundled ? 'Duplicate to my stories' : 'Duplicate',
        icon: SsIcons.copy,
        onSelected: () => actions.duplicate(story),
      ),
      if (!story.bundled)
        SsMenuItem(
          label: 'Rename',
          icon: SsIcons.pencil,
          onSelected: () => _rename(context, ref),
        ),
      if (ref.read(cloudProvider) != null) ...[
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Publish…',
          icon: SsIcons.globe,
          onSelected: () => actions.publish(story),
        ),
      ],
      const SsMenuDivider(),
      SsMenuItem(
        label: 'Export .stage.json',
        icon: SsIcons.file,
        onSelected: () => actions.exportJson(story),
      ),
      SsMenuItem(
        label: 'Export .stage.zip',
        icon: SsIcons.file,
        onSelected: () => actions.exportZip(story),
      ),
      SsMenuItem(
        label: 'Export Markdown (.zip)',
        icon: SsIcons.file,
        onSelected: () =>
            actions.exportStatic(story, StaticExportFormat.markdown),
      ),
      SsMenuItem(
        label: 'Export HTML (.zip)',
        icon: SsIcons.file,
        onSelected: () => actions.exportStatic(story, StaticExportFormat.html),
      ),
      SsMenuItem(
        label: 'Export PDF',
        icon: SsIcons.file,
        onSelected: () => actions.exportPdf(story),
      ),
      if (!story.bundled)
        SsMenuItem(
          label: 'Revisions',
          icon: SsIcons.rotateCcw,
          onSelected: () => actions.revisions(story),
        ),
      if (!story.bundled) ...[
        const SsMenuDivider(),
        SsMenuItem(
          label: 'Delete',
          icon: SsIcons.trash2,
          danger: true,
          onSelected: () => _delete(context, ref),
        ),
      ],
    ];
  }

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
      if (story.bundled) 'Bundled demo (read-only)' else 'Draft',
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

/// Storage usage, persistence and clean-up.
class _StorageFooter extends ConsumerWidget {
  const _StorageFooter();

  static String _size(int? b) {
    if (b == null) return '?';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(0)} KB';
    if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final storage = ref.watch(appStorageProvider);
    if (!storage.available) {
      return Text(
        'Browser storage is unavailable, so stories cannot be saved. '
        'Export anything you want to keep.',
        style: t.text.caption.copyWith(color: t.colors.danger),
      );
    }
    final est = ref.watch(storageEstimateProvider).asData?.value;
    final parts = [
      if (est?.usage != null)
        'Using ${_size(est!.usage)}${est.quota != null ? ' of ${_size(est.quota)}' : ''}',
      if (est?.persisted == true) 'protected from clean-up by the browser',
      if (est?.persisted == false) 'not yet protected from browser clean-up',
    ];
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: SsSpace.s3,
      children: [
        Text(
          parts.isEmpty ? 'Stored in this browser.' : parts.join('  ·  '),
          style: t.text.caption,
        ),
        SsButton(
          label: 'Clean up unused files',
          variant: SsButtonVariant.ghost,
          onPressed: () => StoryActions(context, ref).cleanUpAssets(),
        ),
      ],
    );
  }
}
