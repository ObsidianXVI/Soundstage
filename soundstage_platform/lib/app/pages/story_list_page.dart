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
import 'project_page.dart' show ProjectActions, askText;
import 'story_actions.dart';

/// `/`: the author's projects and drafts (DECISIONS 26/10/26 #11) and the
/// bundled demos. A draft is one story; a project holds many drafts
/// (issues) sharing a library.
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
                          label: 'New project',
                          icon: SsIcons.folder,
                          onPressed: () =>
                              ProjectActions(context, ref).create(),
                        ),
                        SsButton(
                          label: 'New draft',
                          icon: SsIcons.plus,
                          variant: SsButtonVariant.primary,
                          onPressed: () => _create(context, ref),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: SsSpace.s6),
                if (ref.watch(projectListProvider).value case final projects?
                    when projects.isNotEmpty) ...[
                  Text('PROJECTS', style: t.text.overline),
                  const SizedBox(height: SsSpace.s2),
                  for (final p in projects) _ProjectRow(project: p),
                  const SizedBox(height: SsSpace.s4),
                  Text('DRAFTS', style: t.text.overline),
                  const SizedBox(height: SsSpace.s2),
                ],
                switch (stories) {
                  AsyncData(:final value) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final s in value)
                        if (s.projectId == null) StoryRow(story: s),
                    ],
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

/// A draft in a list (the home page, a project's issues).
class StoryRow extends ConsumerWidget {
  const StoryRow({required this.story, super.key});

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
      if (!story.bundled && story.projectId == null)
        if (ref.read(projectListProvider).value case final projects?
            when projects.isNotEmpty)
          SsMenuItem(
            label: 'Move to project…',
            icon: SsIcons.folder,
            onSelected: () => _move(context, ref, projects),
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
      SsMenuItem(
        label: 'Export for Letterpress (.zip)',
        icon: SsIcons.file,
        onSelected: () => actions.exportLetterpress(story),
      ),
      SsMenuItem(
        label: 'Copy as rich text',
        icon: SsIcons.copy,
        onSelected: () => actions.copyRichText(story),
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
    final name = await askText(
      context,
      title: 'Rename story',
      label: 'Story name',
      initial: story.title,
      confirm: 'Rename',
    );
    if (name == null) return;
    await ref.read(storyRepositoryProvider).rename(story.id, name);
    ref.read(storyListRevisionProvider.notifier).bump();
  }

  Future<void> _move(
    BuildContext context,
    WidgetRef ref,
    List<ProjectSummary> projects,
  ) async {
    final target = await showSsDialog<ProjectSummary>(
      context,
      builder: (ctx) => SsDialog(
        title: 'Move "${story.title}" to a project',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final p in projects)
              SsButton(
                label: p.title,
                icon: SsIcons.folder,
                variant: SsButtonVariant.ghost,
                onPressed: () => Navigator.of(ctx).pop(p),
              ),
          ],
        ),
        actions: [
          SsButton(label: 'Cancel', onPressed: () => Navigator.of(ctx).pop()),
        ],
      ),
    );
    if (target == null) return;
    await ref.read(storyRepositoryProvider).moveToProject(story.id, target.id);
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
      if (story.bundled)
        'Bundled demo (read-only)'
      else if (story.projectId != null)
        'Issue'
      else
        'Draft',
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

/// A project on the home page: its issues are on `/project/:id`.
class _ProjectRow extends ConsumerWidget {
  const _ProjectRow({required this.project});

  final ProjectSummary project;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final actions = ProjectActions(context, ref);
    final meta =
        'Project  ·  ${project.issueCount} '
        '${project.issueCount == 1 ? 'issue' : 'issues'}';
    List<SsMenuEntry> menu() => [
      SsMenuItem(
        label: 'Open',
        icon: SsIcons.folder,
        onSelected: () => context.go('/project/${project.id}'),
      ),
      SsMenuItem(
        label: 'New issue',
        icon: SsIcons.plus,
        onSelected: () => actions.newIssue(project),
      ),
      SsMenuItem(
        label: 'Rename',
        icon: SsIcons.pencil,
        onSelected: () => actions.rename(project),
      ),
      const SsMenuDivider(),
      SsMenuItem(
        label: 'Delete',
        icon: SsIcons.trash2,
        danger: true,
        onSelected: () => actions.delete(project),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: SsContextMenuRegion(
        entries: menu,
        child: SsInteractive(
          semanticLabel: '${project.title}, $meta',
          onTap: () => context.go('/project/${project.id}'),
          builder: (context, s) => SsFocusRing(
            visible: s.contains(WidgetState.focused),
            color: c.focusRing,
            borderRadius: SsRadius.brLg,
            child: Container(
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
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  SsIcon(SsIcons.folder, size: 18, color: c.accent),
                  const SizedBox(width: SsSpace.s3),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          project.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.text.bodyStrong,
                        ),
                        const SizedBox(height: 2),
                        Text(meta, style: t.text.caption),
                      ],
                    ),
                  ),
                  Builder(
                    builder: (b) => SsIconButton(
                      icon: SsIcons.ellipsis,
                      semanticLabel: 'More actions for ${project.title}',
                      onPressed: () => showSsMenu(
                        b,
                        anchor: ssGlobalRect(b),
                        placement: SsPlacement.belowEnd,
                        entries: menu(),
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
