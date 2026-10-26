import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/app/export/pdf_export.dart';
import 'package:soundstage_platform/app/export/static_export.dart';
import 'package:soundstage_platform/app/persistence/db_story_repository.dart';
import 'package:soundstage_platform/app/persistence/platform.dart' as platform;
import 'package:soundstage_platform/app/persistence/providers.dart';
import 'package:soundstage_platform/app/persistence/story_package.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart'
    show StageEnvironment, StageRenderMode, renderStagePoster;

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
  /// their images and poster frames, or a PDF. Local exports carry no
  /// backlink until the story is published (M4 hosting).
  Future<void> exportStatic(StorySummary s, StaticExportFormat format) =>
      _exportWith(s, (doc, bytesOf, poster) async {
        final zip = await exportStaticZip(
          doc,
          format,
          bytesOf: bytesOf,
          poster: poster,
        );
        final suffix = format == StaticExportFormat.markdown ? 'md' : 'html';
        return (
          '${exportFileBase(s.title)}.$suffix.zip',
          zip,
          'application/zip',
        );
      });

  Future<void> exportPdf(StorySummary s) =>
      _exportWith(s, (doc, bytesOf, poster) async {
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
        );
        return ('${exportFileBase(s.title)}.pdf', pdf, 'application/pdf');
      });

  Future<void> _exportWith(
    StorySummary s,
    Future<(String, Uint8List, String)> Function(
      ir.StageDocument doc,
      AssetBytesSource bytesOf,
      PosterSource poster,
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
      );
      platform.downloadFile(name, bytes, mime);
    } on Object catch (e) {
      _toast('Export failed: ${_describe(e)}', SsToastKind.danger);
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
