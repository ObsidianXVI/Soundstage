import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:soundstage_platform/app/agent/agent_settings.dart';
import 'package:soundstage_platform/app/cloud/cloud.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/app/export/static_export.dart'
    show StaticExportFormat;
import 'package:soundstage_platform/app/persistence/autosave.dart';
import 'package:soundstage_platform/app/persistence/editor_asset_service.dart';
import 'package:soundstage_platform/app/persistence/providers.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'not_found_page.dart';
import 'open_in_new_tab_stub.dart'
    if (dart.library.js_interop) 'open_in_new_tab_web.dart';
import 'story_actions.dart';

/// `/edit/:id`: the editor for one story.
///
/// Opens the story through the `StoryRepository` (`open`: never throws,
/// may recover an older revision) and hands the document to [EditorShell],
/// which overrides `initialDocumentProvider` with it. Every document change
/// goes to `autosaveProvider(id).notifyChanged`; leaving the editor flushes
/// and drops the cached story, and the next open or play waits for that
/// write ([StoryWriteBarrier]) and reads what was saved.
class EditPage extends ConsumerStatefulWidget {
  const EditPage({required this.storyId, super.key});

  final String storyId;

  @override
  ConsumerState<EditPage> createState() => _EditPageState();
}

class _EditPageState extends ConsumerState<EditPage> {
  late final ProviderContainer _root;
  bool _edited = false;

  @override
  void initState() {
    super.initState();
    _root = ProviderScope.containerOf(context, listen: false);
  }

  String get _id => widget.storyId;

  @override
  void dispose() {
    final root = _root;
    final id = _id;
    if (_edited) {
      // Write what is pending, and make the next open (or play) of this
      // story wait for that write and read it fresh.
      root
          .read(storyWriteBarrierProvider)
          .track(id, root.read(autosaveProvider(id)).flush());
      scheduleMicrotask(() {
        root
          ..invalidate(storyDocumentProvider(id))
          ..invalidate(storyLoadProvider(id));
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(storyLoadProvider(_id), (_, next) {
      final load = next.asData?.value;
      if (load != null && load.recovered && context.mounted) {
        SsToast.show(
          context,
          'The latest save of this story was damaged. Opened revision '
          '${load.recoveredFromRevision} instead.',
          kind: SsToastKind.warning,
        );
      }
    });
    // Keep the autosave controller alive while the editor is open.
    final autosave = ref.watch(autosaveProvider(_id));
    return switch (ref.watch(storyLoadProvider(_id))) {
      AsyncData(:final value) when value?.document != null => Scaffold(
        backgroundColor: context.ss.colors.surface0,
        body: EditorShell(
          document: value!.document!,
          assetService: ref.watch(appEditorAssetServiceProvider),
          filePicker: pickEditorFiles,
          // An issue goes back to its project.
          onBack: () {
            final pid = ref
                .read(storyListProvider)
                .value
                ?.where((s) => s.id == _id)
                .firstOrNull
                ?.projectId;
            context.go(pid == null ? '/' : '/project/$pid');
          },
          onPreview: () => context.go('/play/$_id'),
          onOpenPreviewInNewTab: () => openInNewTab('/play/$_id'),
          onDocumentChanged: (doc) {
            _edited = true;
            autosave.notifyChanged(doc);
          },
          onSave: () => unawaited(autosave.flush()),
          publishActions: _exportActions(autosave),
          agentTransport: ref.watch(agentClientProvider),
          onAgentConfig: (c) => ref.read(agentConfigProvider.notifier).set(c),
          onAgentSettings: ref.watch(cloudProvider) == null
              ? null
              : () => showAgentSettings(context, ref),
          onPublish: ref.watch(cloudProvider) == null
              ? null
              : (doc) async {
                  await autosave.flush();
                  if (!context.mounted) return;
                  await StoryActions(context, ref).publish(
                    StorySummary(
                      id: _id,
                      title: doc.meta.title.isEmpty
                          ? 'Untitled story'
                          : doc.meta.title,
                      updatedAt: DateTime.now(),
                    ),
                    current: doc,
                    open: openInNewTab,
                  );
                },
          saveStatus: SaveIndicator(status: autosave.status),
        ),
      ),
      AsyncData() => const NotFoundPage(message: 'Story not found'),
      AsyncError(:final error) => NotFoundPage(
        message: 'Could not open the story: $error',
      ),
      _ => Scaffold(backgroundColor: context.ss.colors.surface0),
    };
  }
}

extension on _EditPageState {
  /// Publish mode's exports: the story is saved first, then exported like
  /// from the story list.
  List<EditorPublishAction> _exportActions(AutosaveController autosave) {
    StorySummary summary(ir.StageDocument doc) => StorySummary(
      id: _id,
      title: doc.meta.title.isEmpty ? 'Untitled story' : doc.meta.title,
      updatedAt: DateTime.now(),
    );
    EditorPublishAction action(
      String label,
      IconData icon,
      Future<void> Function(StoryActions a, StorySummary s) run,
    ) => EditorPublishAction(
      label: label,
      icon: icon,
      onSelected: (doc) async {
        await autosave.flush();
        if (!mounted) return;
        await run(StoryActions(context, ref), summary(doc));
      },
    );
    return [
      action(
        'Markdown (.zip)',
        SsIcons.file,
        (a, s) => a.exportStatic(s, StaticExportFormat.markdown),
      ),
      action(
        'HTML (.zip)',
        SsIcons.file,
        (a, s) => a.exportStatic(s, StaticExportFormat.html),
      ),
      action('PDF', SsIcons.file, (a, s) => a.exportPdf(s)),
      action(
        'Letterpress (.zip)',
        SsIcons.file,
        (a, s) => a.exportLetterpress(s),
      ),
      // Straight from the click: the clipboard needs the user's gesture.
      EditorPublishAction(
        label: 'Copy as rich text',
        icon: SsIcons.copy,
        onSelected: (doc) =>
            StoryActions(context, ref).copyRichText(summary(doc)),
      ),
    ];
  }
}

/// The toolbar's save indicator: saving, saved, error, offline or
/// read-only.
class SaveIndicator extends StatelessWidget {
  const SaveIndicator({required this.status, super.key});

  final ValueListenable<SaveStatus> status;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return ValueListenableBuilder<SaveStatus>(
      valueListenable: status,
      builder: (context, s, _) {
        final (IconData icon, String label, Color color) = switch (s.state) {
          SaveState.idle => (
            SsIcons.circleCheck,
            'Saved',
            t.colors.textDisabled,
          ),
          SaveState.saving => (
            SsIcons.ellipsis,
            'Saving…',
            t.colors.textSecondary,
          ),
          SaveState.saved => (
            SsIcons.circleCheck,
            'Saved',
            t.colors.textSecondary,
          ),
          SaveState.error => (
            SsIcons.circleAlert,
            'Not saved',
            t.colors.danger,
          ),
          SaveState.offline => (
            SsIcons.triangleAlert,
            'Offline',
            t.colors.warning,
          ),
          SaveState.readOnly => (
            SsIcons.lock,
            'Read-only demo',
            t.colors.textSecondary,
          ),
        };
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsIcon(icon, size: 14, color: color),
            const SizedBox(width: SsSpace.s1),
            Text(
              label,
              key: const ValueKey<String>('save-status'),
              style: t.text.small.copyWith(color: color),
            ),
          ],
        );
        final message =
            s.message ??
            (s.state == SaveState.readOnly
                ? 'Duplicate this demo from the story list to keep changes.'
                : null);
        return Semantics(
          label: 'Save status',
          value: label,
          child: message == null
              ? row
              : SsTooltip(
                  message: message,
                  placement: SsPlacement.belowCenter,
                  child: row,
                ),
        );
      },
    );
  }
}
