import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart' as pub;
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import 'cloud_ui.dart'
    show showPublishDialog, showPublishedDialog, showSignInDialog;
import 'not_found_page.dart';
import 'story_list_page.dart' show StoryRow;

/// Asks for a line of text; null when cancelled or empty.
Future<String?> askText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String confirm = 'OK',
}) async {
  final value = await showSsDialog<String>(
    context,
    builder: (ctx) => _TextPrompt(
      title: title,
      label: label,
      initial: initial,
      confirm: confirm,
    ),
  );
  final v = value?.trim();
  return v == null || v.isEmpty ? null : v;
}

/// The prompt owns its controller, so it lives through the closing
/// animation.
class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.label,
    required this.initial,
    required this.confirm,
  });

  final String title;
  final String label;
  final String initial;
  final String confirm;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final TextEditingController _text = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SsDialog(
    title: widget.title,
    content: SsTextField(
      controller: _text,
      autofocus: true,
      selectAllOnFocus: true,
      semanticLabel: widget.label,
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
      SsButton(
        label: widget.confirm,
        variant: SsButtonVariant.primary,
        onPressed: () => Navigator.of(context).pop(_text.text),
      ),
    ],
  );
}

/// Project actions shared by the story list and the project page.
class ProjectActions {
  ProjectActions(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  StoryRepository get _repo => ref.read(storyRepositoryProvider);
  void _refresh() => ref.read(storyListRevisionProvider.notifier).bump();

  Future<void> create() async {
    final title = await askText(
      context,
      title: 'New project',
      label: 'Project name',
      initial: 'Untitled project',
      confirm: 'Create',
    );
    if (title == null) return;
    final p = await _repo.createProject(title: title);
    _refresh();
    if (context.mounted) context.go('/project/${p.id}');
  }

  Future<void> rename(ProjectSummary p) async {
    final title = await askText(
      context,
      title: 'Rename project',
      label: 'Project name',
      initial: p.title,
      confirm: 'Rename',
    );
    if (title == null) return;
    await _repo.renameProject(p.id, title);
    _refresh();
  }

  /// Returns whether it was deleted.
  Future<bool> delete(ProjectSummary p) async {
    final ok = await showSsConfirm(
      context,
      title: 'Delete "${p.title}"?',
      message:
          'This deletes the project and its ${p.issueCount} '
          '${p.issueCount == 1 ? 'issue' : 'issues'}. It cannot be undone.',
      confirmLabel: 'Delete',
      danger: true,
    );
    if (!ok) return false;
    await _repo.deleteProject(p.id);
    _refresh();
    return true;
  }

  /// Publishes the project's series page (`/series/<slug>`): its
  /// published issues, newest first. Publishing an issue later refreshes it.
  Future<void> publishSeries(ProjectSummary p) async {
    final cloud = ref.read(cloudProvider);
    if (cloud == null) return;
    if (cloud.auth.currentUser == null) {
      await showSignInDialog(context, cloud.auth);
      if (cloud.auth.currentUser == null || !context.mounted) return;
    }
    final existing = await cloud.backend.seriesSlugOf(p.id);
    if (!context.mounted) return;
    final origin = Uri.base.origin;
    final slug = await showPublishDialog(
      context,
      title: p.title,
      suggested: existing ?? pub.slugFor(p.title),
      origin: origin,
      path: 'series',
    );
    if (slug == null || !context.mounted) return;
    try {
      final stories = await _repo.list();
      final record = await pub.publishSeries(
        projectId: p.id,
        title: p.title,
        slug: slug,
        issueIds: [
          for (final s in stories)
            if (s.projectId == p.id) s.id,
        ],
        backend: cloud.backend,
      );
      if (!context.mounted) return;
      await showPublishedDialog(
        context,
        url: '$origin/series/$slug',
        version: 1,
        warnings: [
          if (record.issues.isEmpty)
            'No issue is published yet: publish issues and they appear here.',
        ],
        onOpen: () => context.go('/series/$slug'),
      );
    } on pub.PublishException catch (e) {
      if (context.mounted) {
        SsToast.show(context, e.message, kind: SsToastKind.danger);
      }
    }
  }

  /// A new issue: blank with the project's library, or a copy of
  /// [template].
  Future<void> newIssue(ProjectSummary p, {StorySummary? template}) async {
    final s = await _repo.createIssue(p.id, fromStoryId: template?.id);
    _refresh();
    if (context.mounted) context.go('/edit/${s.id}');
  }
}

/// `/project/:id`: a project's issues (DECISIONS 26/10/26 #11). New
/// issues start blank with the project's shared library, or as a copy of
/// an earlier issue (its template).
class ProjectPage extends ConsumerWidget {
  const ProjectPage({required this.projectId, super.key});

  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final projects = ref.watch(projectListProvider);
    final stories = ref.watch(storyListProvider);
    final project = projects.value?.where((p) => p.id == projectId).firstOrNull;
    if (projects.hasValue && project == null) {
      return const NotFoundPage(message: 'Project not found');
    }
    if (project == null) {
      return Scaffold(backgroundColor: t.colors.surface0);
    }
    final issues = [
      for (final s in stories.value ?? const <StorySummary>[])
        if (s.projectId == projectId) s,
    ];
    final actions = ProjectActions(context, ref);
    return Scaffold(
      backgroundColor: t.colors.surface0,
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
                Row(
                  children: [
                    SsIconButton(
                      icon: SsIcons.arrowLeft,
                      semanticLabel: 'Back to stories',
                      onPressed: () => context.go('/'),
                    ),
                    const SizedBox(width: SsSpace.s1),
                    Expanded(
                      child: Text(
                        project.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.text.heading,
                      ),
                    ),
                    Builder(
                      builder: (b) => SsIconButton(
                        icon: SsIcons.ellipsis,
                        semanticLabel: 'Project actions',
                        onPressed: () => showSsMenu(
                          b,
                          anchor: ssGlobalRect(b),
                          placement: SsPlacement.belowEnd,
                          entries: [
                            SsMenuItem(
                              label: 'Rename',
                              icon: SsIcons.pencil,
                              onSelected: () => actions.rename(project),
                            ),
                            if (ref.read(cloudProvider) != null)
                              SsMenuItem(
                                label: 'Publish series…',
                                icon: SsIcons.globe,
                                onSelected: () =>
                                    actions.publishSeries(project),
                              ),
                            const SsMenuDivider(),
                            SsMenuItem(
                              label: 'Delete project',
                              icon: SsIcons.trash2,
                              danger: true,
                              onSelected: () async {
                                if (await actions.delete(project) &&
                                    context.mounted) {
                                  context.go('/');
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: SsSpace.s1),
                    Builder(
                      builder: (b) => SsButton(
                        key: const ValueKey<String>('new-issue'),
                        label: 'New issue',
                        icon: SsIcons.plus,
                        variant: SsButtonVariant.primary,
                        onPressed: issues.isEmpty
                            ? () => actions.newIssue(project)
                            : () => showSsMenu(
                                b,
                                anchor: ssGlobalRect(b),
                                placement: SsPlacement.belowEnd,
                                entries: [
                                  SsMenuItem(
                                    label: 'Blank, with the project library',
                                    icon: SsIcons.file,
                                    onSelected: () => actions.newIssue(project),
                                  ),
                                  const SsMenuDivider(),
                                  for (final i in issues.take(8))
                                    SsMenuItem(
                                      label: 'Copy of ${i.title}',
                                      icon: SsIcons.copy,
                                      onSelected: () => actions.newIssue(
                                        project,
                                        template: i,
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SsSpace.s2),
                Text(
                  'Issues share this project\'s tokens, styles, components '
                  'and fonts: a change to them in one issue reaches the '
                  'others.',
                  style: t.text.small.copyWith(color: t.colors.textSecondary),
                ),
                const SizedBox(height: SsSpace.s5),
                if (issues.isEmpty)
                  Text(
                    'No issues yet. Start the first one with New issue.',
                    style: t.text.body.copyWith(color: t.colors.textSecondary),
                  ),
                for (final s in issues) StoryRow(story: s),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
