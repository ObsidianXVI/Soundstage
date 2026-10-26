import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/cloud/publish.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/app/export/pdf_export.dart';
import 'package:soundstage_platform/app/export/rich_copy.dart' as clip;
import 'package:soundstage_platform/app/export/static_export.dart';
import 'package:soundstage_platform/app/persistence/db_story_repository.dart';
import 'package:soundstage_platform/app/persistence/platform.dart' as platform;
import 'package:soundstage_platform/app/persistence/providers.dart';
import 'package:soundstage_platform/app/persistence/story_package.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/export/export.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart'
    show
        StageAssetResolver,
        StageEnvironment,
        StageRenderMode,
        renderStagePoster;

import 'cloud_ui.dart';

/// Story-level actions of the story list: import, export, duplicate,
/// revisions. Each reports failures as a toast and never throws.
class StoryActions {
  StoryActions(this.context, this.ref);

  final BuildContext context;
  final WidgetRef ref;

  StoryRepository get _repo => ref.read(storyRepositoryProvider);
  DbStoryRepository? get _db =>
      _repo is DbStoryRepository ? _repo as DbStoryRepository : null;

  void _refresh() => ref.read(storyListRevisionProvider.notifier).bump();

  void _toast(String m, [SsToastKind kind = SsToastKind.info]) {
    if (context.mounted) SsToast.show(context, m, kind: kind);
  }

  String _describe(Object e) => e is StorageFullException
      ? 'The browser storage is full. Delete a story or export it first.'
      : e is ImportException
      ? e.message
      : '$e';

  Future<void> duplicate(StorySummary s) async {
    try {
      final copy = await _repo.duplicate(s.id);
      _refresh();
      _toast('Copied to your stories as "${copy.title}"', SsToastKind.success);
    } on Object catch (e) {
      _toast('Could not duplicate: ${_describe(e)}', SsToastKind.danger);
    }
  }

  Future<void> import() async {
    final db = _db;
    if (db == null) {
      _toast('Import needs browser storage.', SsToastKind.warning);
      return;
    }
    try {
      final files = await platform.pickFiles(accept: '.json,.zip');
      if (files.isEmpty) return;
      final imported = await importStoryFile(files.first.bytes, db.assets);
      final summary = await _repo.createFrom(imported.document!);
      _refresh();
      final extra = [
        if (imported.warnings.isNotEmpty)
          '${imported.warnings.length} warning(s)',
        if (imported.diagnostics.isNotEmpty)
          '${imported.diagnostics.length} issue(s) found',
      ].join(', ');
      _toast(
        'Imported "${summary.title}"${extra.isEmpty ? '' : ' ($extra)'}',
        extra.isEmpty ? SsToastKind.success : SsToastKind.warning,
      );
    } on Object catch (e) {
      _toast('Import failed: ${_describe(e)}', SsToastKind.danger);
    }
  }

  Future<void> exportJson(StorySummary s) async {
    try {
      final doc = await _repo.load(s.id);
      if (doc == null) return;
      platform.downloadFile(
        '${exportFileBase(s.title)}.stage.json',
        Uint8List.fromList(utf8.encode(exportStageJson(doc))),
        'application/json',
      );
    } on Object catch (e) {
      _toast('Export failed: ${_describe(e)}', SsToastKind.danger);
    }
  }

  Future<void> exportZip(StorySummary s) async {
    final db = _db;
    try {
      final doc = await _repo.load(s.id);
      if (doc == null) return;
      final bytes = await exportStageZip(
        doc,
        (a) => db?.assetBytes(a) ?? Future.value(null),
      );
      platform.downloadFile(
        '${exportFileBase(s.title)}.stage.zip',
        bytes,
        'application/zip',
      );
    } on Object catch (e) {
      _toast('Export failed: ${_describe(e)}', SsToastKind.danger);
    }
  }

  /// Static exports (architecture §16.1): Markdown or HTML in a zip with
  /// their images and poster frames, or a PDF. A published story's exports
  /// link back to it ("View interactive article on Soundstage").
  Future<void> exportStatic(StorySummary s, StaticExportFormat format) =>
      _exportWith(s, (doc, bytesOf, poster, backlink) async {
        final zip = await exportStaticZip(
          doc,
          format,
          bytesOf: bytesOf,
          poster: poster,
          backlink: backlink,
        );
        final suffix = format == StaticExportFormat.markdown ? 'md' : 'html';
        return (
          '${exportFileBase(s.title)}.$suffix.zip',
          zip,
          'application/zip',
        );
      });

  /// The story for the Letterpress blog (m4.md T4.5d): a zip to unzip at
  /// the Letterpress repo root (Markdown source, generated `LPModule`,
  /// images, and the lines to add).
  Future<void> exportLetterpress(StorySummary s) =>
      _exportWith(s, (doc, bytesOf, poster, backlink) async {
        final name = letterpressFileName(s.title);
        final zip = await exportLetterpressZip(
          doc,
          bytesOf: bytesOf,
          poster: poster,
          name: name,
          date: DateTime.now(),
          backlink: backlink,
        );
        return ('$name.letterpress.zip', zip, 'application/zip');
      });

  Future<void> exportPdf(StorySummary s) =>
      _exportWith(s, (doc, bytesOf, poster, backlink) async {
        Uint8List? font;
        try {
          final data = await rootBundle.load(
            'assets/fonts/inter/Inter-Variable.ttf',
          );
          font = data.buffer.asUint8List();
        } on Object {
          font = null; // Times alone still covers Latin text
        }
        final pdf = await exportStoryPdf(
          doc,
          bytesOf: bytesOf,
          poster: poster,
          fallbackFont: font,
          backlink: backlink,
        );
        return ('${exportFileBase(s.title)}.pdf', pdf, 'application/pdf');
      });

  Future<void> _exportWith(
    StorySummary s,
    Future<(String, Uint8List, String)> Function(
      ir.StageDocument doc,
      AssetBytesSource bytesOf,
      PosterSource poster,
      Backlink? backlink,
    )
    build,
  ) async {
    final db = _db;
    try {
      final doc = await _repo.load(s.id);
      if (doc == null) return;
      _toast('Exporting "${s.title}"…');
      final env = StageEnvironment.forDocument(doc, mode: StageRenderMode.edit);
      final (name, bytes, mime) = await build(
        doc,
        (a) => db?.assetBytes(a) ?? Future.value(null),
        ({required sceneId, clock, nodeId}) => renderStagePoster(
          doc,
          env,
          sceneId: sceneId,
          clock: clock,
          nodeId: nodeId,
          pixelRatio: 2,
        ),
        await _backlinkFor(s.id),
      );
      platform.downloadFile(name, bytes, mime);
    } on Object catch (e) {
      _toast('Export failed: ${_describe(e)}', SsToastKind.danger);
    }
  }

  /// Where story [storyId] is published, or null when it is not published
  /// or the cloud is unavailable.
  Future<PublishTarget?> _publishedTarget(String storyId) async {
    final cloud = ref.read(cloudProvider);
    if (cloud == null || cloud.auth.currentUser == null) return null;
    try {
      return await cloud.backend.publishedTargetOf(storyId);
    } on Object {
      return null;
    }
  }

  Future<Backlink?> _backlinkFor(String storyId) async {
    final target = await _publishedTarget(storyId);
    return target == null
        ? null
        : Backlink('${Uri.base.origin}${target.route}');
  }

  /// Puts the story on the clipboard as rich text for Medium or Substack
  /// (m4.md T4.5d). Called straight from the menu, so the browser still
  /// sees the click. Images go along by their public URLs, so only a
  /// published story's images are included; posters become links.
  void copyRichText(StorySummary s) {
    final content = () async {
      final doc = await _repo.load(s.id);
      if (doc == null) throw StateError('the story is gone');
      final story = linearize(doc);
      final target = await _publishedTarget(s.id);
      final backlink = target == null
          ? null
          : Backlink('${Uri.base.origin}${target.route}');
      Map<String, ir.Asset> published = const {};
      final cloud = ref.read(cloudProvider);
      if (target != null && cloud != null) {
        try {
          final loaded = await loadPublished(
            target,
            backend: cloud.backend,
            fetch: StageAssetResolver().load,
          );
          published = loaded?.document?.assets ?? const {};
        } on Object {
          published = const {}; // text only
        }
      }
      String? urlOf(String key) {
        final uri = published[key]?.uri;
        return uri != null && uri.startsWith('https://') ? uri : null;
      }

      return (
        html: toPasteHtml(story, pathOf: urlOf, backlink: backlink),
        plain: toMarkdown(story, pathOf: urlOf, backlink: backlink),
      );
    }();
    clip
        .copyRichText(content)
        .then(
          (_) => _toast(
            'Copied "${s.title}". Paste it into Medium or Substack.',
            SsToastKind.success,
          ),
          onError: (Object e) =>
              _toast('Could not copy: ${_describe(e)}', SsToastKind.danger),
        );
  }

  /// Republishes the publication of [storyId]'s project, if it has one,
  /// so a newly published issue is listed. Failures are quiet: the issue
  /// itself is published.
  Future<void> refreshSeriesOf(String storyId) async {
    final cloud = ref.read(cloudProvider);
    if (cloud == null) return;
    try {
      final stories = await _repo.list();
      final pid = stories.where((x) => x.id == storyId).firstOrNull?.projectId;
      if (pid == null) return;
      final pub = await cloud.backend.publicationOf(pid);
      if (pub == null) return;
      final project = (await _repo.projects())
          .where((p) => p.id == pid)
          .firstOrNull;
      await publishSeries(
        projectId: pid,
        title: project?.title ?? '',
        ref: pub,
        issueIds: [
          for (final x in stories)
            if (x.projectId == pid) x.id,
        ],
        backend: cloud.backend,
      );
    } on Object {
      // The series catches up when it is next published.
    }
  }

  /// Publishes the story (m4.md T4.2, m7.md T7.2): check access, choose
  /// a handle the first time, choose the link, upload, then show it. A
  /// one-off draft publishes at `/@<handle>/s/<slug>`; a project's issue
  /// at `/@<handle>/<publication>/<slug>`, after the project's publication
  /// link is chosen once. [current] is the editor's document (the editor's
  /// Publish button): it is published as is, and the story is not written
  /// to (the editor's autosave owns it). [open] opens the published link
  /// (default: navigate to it).
  Future<void> publish(
    StorySummary s, {
    ir.StageDocument? current,
    ValueChanged<String>? open,
  }) async {
    final cloud = ref.read(cloudProvider);
    final db = _db;
    if (cloud == null) return;
    if (!await ensureCloudAccess(context, cloud) || !context.mounted) return;
    final handle = await ensureHandle(context, cloud);
    if (handle == null || !context.mounted) return;
    try {
      final doc = current ?? await _repo.load(s.id);
      if (doc == null || !context.mounted) return;
      final origin = Uri.base.origin;
      final before = await _publishedTarget(s.id);
      final projectId = (await _repo.list())
          .where((x) => x.id == s.id)
          .firstOrNull
          ?.projectId;
      PublicationRef? pub;
      if (projectId != null) {
        pub = await _publicationFor(cloud, handle, projectId);
        if (pub == null) return;
      }
      if (!context.mounted) return;
      final previous = switch (before) {
        IssueTarget(:final publication, :final slug) when publication == pub =>
          slug,
        DraftTarget(handle: final h, :final slug)
            when pub == null && h == handle =>
          slug,
        _ => '',
      };
      final suggested = previous.isNotEmpty
          ? previous
          : doc.meta.slug.isNotEmpty
          ? doc.meta.slug
          : slugFor(s.title);
      final slug = await showPublishDialog(
        context,
        title: s.title,
        suggested: suggested,
        prefix: pub == null ? '$origin/@$handle/s/' : '$origin${pub.route}/',
      );
      if (slug == null) return;
      final target = pub == null
          ? DraftTarget(handle, slug)
          : IssueTarget(pub, slug);
      _toast('Publishing "${s.title}"…');
      final result = await publishStory(
        doc,
        storyId: s.id,
        target: target,
        backend: cloud.backend,
        bytesOf: (a) => db?.assetBytes(a) ?? Future.value(null),
        cover: doc.scenes.isEmpty
            ? null
            : () => renderStagePoster(
                doc,
                StageEnvironment.forDocument(doc, mode: StageRenderMode.edit),
                sceneId: doc.scenes.first.id,
              ),
      );
      // An issue's publication lists it.
      await refreshSeriesOf(s.id);
      // Remember the link in the story (the next publish suggests it).
      if (current == null && !s.bundled && doc.meta.slug != slug) {
        await _repo.save(
          s.id,
          doc.copyWith(meta: doc.meta.copyWith(slug: slug)),
        );
      }
      if (!context.mounted) return;
      await showPublishedDialog(
        context,
        url: '$origin${result.path}',
        version: result.version,
        warnings: result.warnings,
        onOpen: () =>
            open != null ? open(result.path) : context.go(result.path),
      );
    } on PublishException catch (e) {
      _toast(e.message, SsToastKind.danger);
    } on Object catch (e) {
      _toast('Publishing failed: ${_describe(e)}', SsToastKind.danger);
    }
  }

  /// Project [projectId]'s publication; asks for its link (and creates
  /// it, empty) the first time. Null when cancelled.
  Future<PublicationRef?> _publicationFor(
    Cloud cloud,
    String handle,
    String projectId,
  ) async {
    final existing = await cloud.backend.publicationOf(projectId);
    if (existing != null || !context.mounted) return existing;
    final project = (await _repo.projects())
        .where((p) => p.id == projectId)
        .firstOrNull;
    final title = project?.title ?? 'Project';
    if (!context.mounted) return null;
    final slug = await showPublishDialog(
      context,
      title: title,
      suggested: slugFor(title),
      prefix: '${Uri.base.origin}/@$handle/',
      note:
          'Issues of this project are published under this link, and it '
          'lists them, newest first.',
      action: 'Name the publication of',
      valid: isValidPublication,
    );
    if (slug == null) return null;
    final ref = PublicationRef(handle, slug);
    await publishSeries(
      projectId: projectId,
      title: title,
      ref: ref,
      issueIds: const [],
      backend: cloud.backend,
    );
    return ref;
  }

  /// The published versions of [s] (DECISIONS 26/10/26 "Releases"),
  /// newest first; any can be made live (readers get it at once; nothing
  /// is rebuilt).
  Future<void> versions(StorySummary s) async {
    final cloud = ref.read(cloudProvider);
    if (cloud == null) return;
    if (!await ensureCloudAccess(context, cloud) || !context.mounted) return;
    try {
      final target = await cloud.backend.publishedTargetOf(s.id);
      final record = target == null
          ? null
          : await cloud.backend.published(target);
      if (!context.mounted) return;
      if (target == null || record == null || record.versions.isEmpty) {
        _toast('"${s.title}" is not published yet.');
        return;
      }
      final chosen = await showSsDialog<int>(
        context,
        builder: (ctx) => SsDialog(
          title: 'Published versions of "${s.title}"',
          width: 480,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SelectableText(
                '${Uri.base.origin}${target.route}',
                style: ctx.ss.text.small,
              ),
              const SizedBox(height: SsSpace.s2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final v in record.versions.reversed)
                      _VersionRow(
                        version: v,
                        live: v.version == record.version,
                        onMakeLive: () => Navigator.of(ctx).pop(v.version),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            SsButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
          ],
        ),
      );
      if (chosen == null) return;
      await makeLive(target, chosen, backend: cloud.backend);
      await refreshSeriesOf(s.id);
      _toast('Version $chosen is live.', SsToastKind.success);
    } on PublishException catch (e) {
      _toast(e.message, SsToastKind.danger);
    } on Object catch (e) {
      _toast(
        'Could not change the version: ${_describe(e)}',
        SsToastKind.danger,
      );
    }
  }

  Future<void> revisions(StorySummary s) async {
    final revs = await _repo.revisions(s.id);
    if (!context.mounted) return;
    final chosen = await showSsDialog<int>(
      context,
      builder: (ctx) => SsDialog(
        title: 'Revisions of "${s.title}"',
        width: 440,
        content: revs.isEmpty
            ? const Text('No saved revisions yet.')
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < revs.length; i++)
                      _RevisionRow(
                        info: revs[i],
                        current: i == 0,
                        onRestore: () => Navigator.of(ctx).pop(revs[i].rev),
                      ),
                  ],
                ),
              ),
        actions: [
          SsButton(label: 'Close', onPressed: () => Navigator.of(ctx).pop()),
        ],
      ),
    );
    if (chosen == null) return;
    try {
      await _repo.restore(s.id, chosen);
      _refresh();
      _toast('Restored revision $chosen', SsToastKind.success);
    } on Object catch (e) {
      _toast('Could not restore: ${_describe(e)}', SsToastKind.danger);
    }
  }

  Future<void> cleanUpAssets() async {
    final db = _db;
    if (db == null) return;
    try {
      final n = await db.assets.collectGarbage();
      ref.invalidate(storageEstimateProvider);
      _toast(
        n == 0
            ? 'No unused files.'
            : 'Removed $n unused file${n == 1 ? '' : 's'}.',
        SsToastKind.success,
      );
    } on Object catch (e) {
      _toast('Clean-up failed: ${_describe(e)}', SsToastKind.danger);
    }
  }

  void open(StorySummary s) => context.go('/edit/${s.id}');
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.version,
    required this.live,
    required this.onMakeLive,
  });

  final PublishedVersion version;
  final bool live;
  final VoidCallback onMakeLive;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final at = version.publishedAt == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(version.publishedAt).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final when = at == null
        ? ''
        : '  ·  ${at.year}-${two(at.month)}-${two(at.day)} '
              '${two(at.hour)}:${two(at.minute)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SsSpace.s1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Version ${version.version}${live ? '  (live)' : ''}',
                  style: t.text.bodyStrong,
                ),
                Text(
                  '${version.title.isEmpty ? 'Untitled' : version.title}$when',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.text.caption,
                ),
              ],
            ),
          ),
          if (!live)
            SsButton(
              key: ValueKey<String>('versions:live:${version.version}'),
              label: 'Make live',
              onPressed: onMakeLive,
            ),
        ],
      ),
    );
  }
}

class _RevisionRow extends StatelessWidget {
  const _RevisionRow({
    required this.info,
    required this.current,
    required this.onRestore,
  });

  final RevisionInfo info;
  final bool current;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final time = info.time;
    String two(int n) => n.toString().padLeft(2, '0');
    final label =
        '${time.year}-${two(time.month)}-${two(time.day)} ${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
    final kb = (info.size / 1024).toStringAsFixed(1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SsSpace.s1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$label${current ? '  (current)' : ''}',
                  style: t.text.bodyStrong,
                ),
                Text('Revision ${info.rev}  ·  $kb KB', style: t.text.caption),
              ],
            ),
          ),
          if (!current) SsButton(label: 'Restore', onPressed: onRestore),
        ],
      ),
    );
  }
}
