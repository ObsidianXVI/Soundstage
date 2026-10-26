import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../agent/agent_panel.dart';
import '../agent/agent_transport.dart';
import '../board/board_view.dart';
import '../canvas/canvas_controller.dart';
import '../canvas/editor_canvas.dart';
import '../clipboard/clipboard_actions.dart';
import '../core/editor_controller.dart';
import '../insert/asset_service.dart';
import '../insert/editor_notices.dart';
import '../inspector/inspector.dart';
import '../panels/assets_panel.dart';
import '../panels/layers_panel.dart';
import '../panels/scenes_panel.dart';
import '../panels/tokens_panel.dart';
import '../preview/preview_split.dart';
import '../preview/preview_state.dart';
import '../publish/publish_view.dart';
import '../shortcuts/editor_shortcuts.dart';
import '../shortcuts/intents.dart';
import '../shortcuts/shortcut_help.dart';
import '../timeline/timeline_panel.dart';
import '../writing/writing_view.dart';
import 'content_mode_screen.dart';
import 'editor_layout.dart';
import 'isolation_bar.dart';
import 'resize_handle.dart';
import 'toolbar.dart';

export '../publish/publish_view.dart' show EditorPublishAction;

/// The editor frame for one story: toolbar, resizable left panel, canvas,
/// inspector and the timeline strip.
///
/// The shell opens its own editor: a `ProviderScope` overrides
/// [initialDocumentProvider] with [document], so the `EditorController`,
/// its resolvers and the canvas state belong to this editor. Every later
/// document change is reported to [onDocumentChanged] (the app's
/// autosave). Below [kEditorMinWidth] it shows [ContentModeScreen] instead.
class EditorShell extends StatelessWidget {
  const EditorShell({
    required this.document,
    required this.onBack,
    required this.onPreview,
    this.onDocumentChanged,
    this.onSave,
    this.saveStatus,
    this.assetService,
    this.filePicker,
    this.onOpenPreviewInNewTab,
    this.onPublish,
    this.publishActions = const [],
    this.agentTransport,
    this.onAgentSettings,
    this.onAgentConfig,
    super.key,
  });

  /// The document the editor opens with.
  final ir.StageDocument document;
  final VoidCallback onBack;

  /// Opens the full-window player for this story (`/play/:id`). The toolbar's
  /// Preview button toggles the split preview instead; this is what a
  /// Cmd/Ctrl-click falls back to when [onOpenPreviewInNewTab] is not given,
  /// and what content mode plays with.
  final VoidCallback onPreview;

  /// Opens `/play/:id` in a new browser tab (Cmd/Ctrl-click on Preview and
  /// the preview pane's "open in new tab" control). The app supplies it.
  final VoidCallback? onOpenPreviewInNewTab;

  /// Called with the new document after every change (edits, undo, redo).
  final ValueChanged<ir.StageDocument>? onDocumentChanged;

  /// Cmd+S: write pending changes now.
  final VoidCallback? onSave;

  /// The save indicator shown in the toolbar (the app's autosave status).
  final Widget? saveStatus;

  /// The asset store the app provides (the editor never imports the app).
  /// Without it, adding files fails with a StateError.
  final EditorAssetService? assetService;

  /// The browser file picker, supplied by the app.
  final EditorFilePicker? filePicker;

  /// The toolbar's Publish button, called with the current story document
  /// (hidden when null). The app supplies it when the cloud is configured.
  final ValueChanged<ir.StageDocument>? onPublish;

  /// The Publish mode's export actions, supplied by the app.
  final List<EditorPublishAction> publishActions;

  /// The agent's model access (the app's agent service); null: the Agent
  /// panel explains what it needs.
  final AgentTransport? agentTransport;

  /// Opens the app's Agent settings (keys and models).
  final VoidCallback? onAgentSettings;

  /// Stores a changed agent config (the agent's policy, set in the panel).
  final ValueChanged<AgentConfig>? onAgentConfig;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        initialDocumentProvider.overrideWithValue(document),
        if (assetService case final service?)
          editorAssetServiceProvider.overrideWithValue(service),
        if (filePicker case final picker?)
          editorFilePickerProvider.overrideWithValue(picker),
        agentTransportProvider.overrideWithValue(agentTransport),
        agentSettingsProvider.overrideWithValue(onAgentSettings),
        agentConfigSinkProvider.overrideWithValue(onAgentConfig),
      ],
      child: _EditorScope(
        onBack: onBack,
        onPreview: onPreview,
        onOpenPreviewInNewTab: onOpenPreviewInNewTab,
        onDocumentChanged: onDocumentChanged,
        onSave: onSave,
        saveStatus: saveStatus,
        onPublish: onPublish,
        publishActions: publishActions,
      ),
    );
  }
}

/// The shell inside the editor's provider scope.
class _EditorScope extends ConsumerWidget {
  const _EditorScope({
    required this.onBack,
    required this.onPreview,
    required this.onOpenPreviewInNewTab,
    required this.onDocumentChanged,
    required this.onSave,
    required this.saveStatus,
    required this.onPublish,
    required this.publishActions,
  });

  final VoidCallback onBack;
  final VoidCallback onPreview;
  final VoidCallback? onOpenPreviewInNewTab;
  final ValueChanged<ir.StageDocument>? onDocumentChanged;
  final VoidCallback? onSave;
  final Widget? saveStatus;
  final ValueChanged<ir.StageDocument>? onPublish;
  final List<EditorPublishAction> publishActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(
      editorControllerProvider.select((s) => Identity(s.storyDocument)),
      (_, next) => onDocumentChanged?.call(next.value),
    );
    // The title only: an edit must not rebuild the shell (T2.1-6).
    final storyTitle = ref.watch(
      editorControllerProvider.select((s) => s.document.meta.title),
    );
    final title = storyTitle.isEmpty ? 'Untitled story' : storyTitle;
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth < kEditorMinWidth) {
          return ContentModeScreen(
            title: title,
            onPlay: onPreview,
            onBack: onBack,
            saveStatus: saveStatus,
          );
        }
        return _AltScopeFlip(
          child: _DockedEditor(
            title: title,
            width: box.maxWidth,
            onBack: onBack,
            onPreview: onPreview,
            onOpenPreviewInNewTab: onOpenPreviewInNewTab,
            onSave: onSave,
            saveStatus: saveStatus,
            onPublish: onPublish == null
                ? null
                : () => onPublish!(
                    ref.read(editorControllerProvider).storyDocument,
                  ),
            onPublishDocument: onPublish,
            publishActions: publishActions,
          ),
        );
      },
    );
  }
}

/// Holding Alt flips the edit scope for the edits made while it is down,
/// and the toolbar shows the flipped scope live.
class _AltScopeFlip extends ConsumerStatefulWidget {
  const _AltScopeFlip({required this.child});

  final Widget child;

  @override
  ConsumerState<_AltScopeFlip> createState() => _AltScopeFlipState();
}

class _AltScopeFlipState extends ConsumerState<_AltScopeFlip> {
  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent e) {
    if (mounted) {
      ref
          .read(editorControllerProvider.notifier)
          .setScopeFlipped(HardwareKeyboard.instance.isAltPressed);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DockedEditor extends ConsumerWidget {
  const _DockedEditor({
    required this.title,
    required this.width,
    required this.onBack,
    required this.onPreview,
    required this.onOpenPreviewInNewTab,
    required this.onSave,
    required this.saveStatus,
    required this.onPublish,
    required this.onPublishDocument,
    required this.publishActions,
  });

  final String title;
  final double width;
  final VoidCallback onBack;
  final VoidCallback onPreview;
  final VoidCallback? onOpenPreviewInNewTab;
  final VoidCallback? onSave;
  final Widget? saveStatus;
  final VoidCallback? onPublish;
  final ValueChanged<ir.StageDocument>? onPublishDocument;
  final List<EditorPublishAction> publishActions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ss.colors;
    final layout = ref.watch(editorLayoutProvider);
    final notifier = ref.read(editorLayoutProvider.notifier);

    // Keep the canvas usable if the window shrank after the panels grew.
    final maxSide = math.max(
      kLeftPanelMin,
      (width - kCanvasMinWidth) - (layout.rightOpen ? kRightPanelMin : 0),
    );
    final leftW = layout.leftWidth.clamp(
      kLeftPanelMin,
      math.min(kLeftPanelMax, maxSide),
    );
    final maxRight = math.max(
      kRightPanelMin,
      width - kCanvasMinWidth - (layout.leftOpen ? leftW : 0),
    );
    final rightW = layout.rightWidth.clamp(
      kRightPanelMin,
      math.min(kRightPanelMax, maxRight),
    );
    final timelineH = clampTimelineHeight(
      layout.timelineHeight,
      MediaQuery.sizeOf(context).height,
    );

    void help() => showShortcutHelp(context);

    /// Preview toggles the split; Cmd/Ctrl-click opens the full player in a
    /// new tab instead.
    void preview() {
      final keys = HardwareKeyboard.instance;
      if (keys.isMetaPressed || keys.isControlPressed) {
        (onOpenPreviewInNewTab ?? onPreview)();
      } else {
        ref.read(previewProvider.notifier).toggle();
      }
    }

    final editor = ref.read(editorControllerProvider.notifier);
    final canvas = ref.read(canvasControllerProvider);
    final clip = ref.read(clipboardActionsProvider);

    return EditorNoticeHost(
      child: EditorShortcuts(
        onEditorIntent: editor.perform,
        actions: <Type, Action<Intent>>{
          ShowShortcutHelpIntent: EditorShortcutAction<ShowShortcutHelpIntent>(
            (_) => help(),
          ),
          ToggleLeftPanelIntent: EditorShortcutAction<ToggleLeftPanelIntent>(
            (_) => notifier.toggleLeft(),
          ),
          ToggleRightPanelIntent: EditorShortcutAction<ToggleRightPanelIntent>(
            (_) => notifier.toggleRight(),
          ),
          ToggleTimelineIntent: EditorShortcutAction<ToggleTimelineIntent>(
            (_) => notifier.toggleTimeline(),
          ),
          PreviewIntent: EditorShortcutAction<PreviewIntent>(
            (_) => ref.read(previewProvider.notifier).toggle(),
          ),
          SaveIntent: EditorShortcutAction<SaveIntent>((_) => onSave?.call()),
          CopyIntent: ClipboardShortcutAction<CopyIntent>(
            (_) => unawaited(clip.copy()),
          ),
          CutIntent: ClipboardShortcutAction<CutIntent>(
            (_) => unawaited(clip.cut()),
          ),
          PasteIntent: ClipboardShortcutAction<PasteIntent>(
            (_) => unawaited(clip.paste()),
          ),
          PasteReplaceIntent: ClipboardShortcutAction<PasteReplaceIntent>(
            (_) => unawaited(clip.paste(replace: true)),
          ),
          SelectToolIntent: EditorShortcutAction<SelectToolIntent>(
            (i) => editor.setTool(i.tool),
          ),
          ZoomInIntent: EditorShortcutAction<ZoomInIntent>(
            (_) => canvas.zoomIn(),
          ),
          ZoomOutIntent: EditorShortcutAction<ZoomOutIntent>(
            (_) => canvas.zoomOut(),
          ),
          ZoomTo100Intent: EditorShortcutAction<ZoomTo100Intent>(
            (_) => canvas.zoomTo100(),
          ),
          ZoomToFitIntent: EditorShortcutAction<ZoomToFitIntent>(
            (_) => canvas.zoomToFit(),
          ),
          ZoomToSelectionIntent: EditorShortcutAction<ZoomToSelectionIntent>((
            _,
          ) {
            final st = ref.read(editorControllerProvider);
            canvas.zoomToNodes(st.selection, breakpointId: st.artboardId);
          }),
        },
        child: Focus(
          autofocus: true,
          child: ColoredBox(
            color: c.surface0,
            child: Column(
              children: [
                EditorToolbar(
                  title: title,
                  onBack: onBack,
                  onPreview: preview,
                  onHelp: help,
                  saveStatus: saveStatus,
                  onPublish: onPublish,
                ),
                Expanded(
                  child: _withAgent(
                    layout: layout,
                    notifier: notifier,
                    width: rightW.toDouble(),
                    child: switch (layout.mode) {
                      EditorMode.writing => _WriteArea(
                        board: layout.board,
                        onBoard: notifier.showBoard,
                        onOpenInNewTab: onOpenPreviewInNewTab,
                      ),
                      EditorMode.publish => PublishView(
                        onPublish: onPublishDocument,
                        actions: publishActions,
                        onOpenInNewTab: onOpenPreviewInNewTab,
                      ),
                      EditorMode.design || EditorMode.animation => _canvasArea(
                        layout: layout,
                        notifier: notifier,
                        leftW: leftW.toDouble(),
                        rightW: rightW.toDouble(),
                      ),
                    },
                  ),
                ),
                if (layout.mode == EditorMode.design ||
                    layout.mode == EditorMode.animation)
                  TimelinePanel(
                    open: layout.showsTimeline,
                    height: timelineH,
                    onToggle: notifier.toggleTimeline,
                    onResize: (d) => notifier.setTimelineHeight(
                      timelineH - d,
                      available: MediaQuery.sizeOf(context).height,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The Agent panel beside [child] in Write and Publish; in Design and
  /// Animate it takes the inspector's place (see [_canvasArea]).
  Widget _withAgent({
    required EditorLayoutState layout,
    required EditorLayoutNotifier notifier,
    required double width,
    required Widget child,
  }) {
    final onCanvas =
        layout.mode == EditorMode.design || layout.mode == EditorMode.animation;
    if (!layout.agentOpen || onCanvas) return child;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: child),
        SizedBox(
          width: width,
          child: AgentPanel(onClose: notifier.toggleAgent),
        ),
      ],
    );
  }

  Widget _canvasArea({
    required EditorLayoutState layout,
    required EditorLayoutNotifier notifier,
    required double leftW,
    required double rightW,
  }) => Row(
    children: [
      if (layout.leftOpen) ...[
        SizedBox(width: leftW, child: const _LeftPanel()),
        ResizeHandle(
          semanticLabel: 'Resize left panel',
          onDelta: (d) => notifier.setLeftWidth(leftW + d, available: width),
          onReset: () => notifier.setLeftWidth(264),
        ),
      ],
      Expanded(
        child: PreviewSplit(
          canvas: const IsolationFrame(child: EditorCanvas()),
          onOpenInNewTab: onOpenPreviewInNewTab,
        ),
      ),
      if (layout.rightOpen || layout.agentOpen) ...[
        ResizeHandle(
          semanticLabel: 'Resize inspector',
          onDelta: (d) => notifier.setRightWidth(rightW - d, available: width),
          onReset: () => notifier.setRightWidth(288),
        ),
        SizedBox(
          width: rightW,
          child: layout.agentOpen
              ? AgentPanel(onClose: notifier.toggleAgent)
              : const Inspector(),
        ),
      ],
    ],
  );
}

/// Write mode: the story's text (with the preview beside it) or the
/// draft's inspiration board.
class _WriteArea extends StatelessWidget {
  const _WriteArea({
    required this.board,
    required this.onBoard,
    required this.onOpenInNewTab,
  });

  final bool board;
  final ValueChanged<bool> onBoard;
  final VoidCallback? onOpenInNewTab;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: SsSpace.s3),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: c.surface1,
            border: Border(bottom: BorderSide(color: c.borderSubtle)),
          ),
          child: SsSegmented<bool>(
            key: const ValueKey<String>('write-board-switch'),
            semanticLabel: 'Story or board',
            selected: board,
            onChanged: onBoard,
            segments: const [
              SsSegment(value: false, label: 'Story'),
              SsSegment(value: true, label: 'Board'),
            ],
          ),
        ),
        Expanded(
          child: board
              ? const BoardView()
              : PreviewSplit(
                  canvas: const WritingView(),
                  onOpenInNewTab: onOpenInNewTab,
                ),
        ),
      ],
    );
  }
}

class _LeftPanel extends ConsumerWidget {
  const _LeftPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.ss.colors;
    final tab = ref.watch(editorLayoutProvider.select((s) => s.leftTab));
    final notifier = ref.read(editorLayoutProvider.notifier);
    return Container(
      color: c.surface1,
      child: Column(
        children: [
          SsTabs(
            selectedId: tab.name,
            onChanged: (id) => notifier.setLeftTab(
              LeftPanelTab.values.firstWhere((t) => t.name == id),
            ),
            tabs: const [
              SsTab(id: 'scenes', label: 'Scenes'),
              SsTab(id: 'layers', label: 'Layers'),
              SsTab(id: 'assets', label: 'Assets'),
              SsTab(id: 'tokens', label: 'Tokens'),
            ],
          ),
          Expanded(
            child: SsTabPanel(
              label: '${tab.name} panel',
              child: switch (tab) {
                LeftPanelTab.scenes => const ScenesPanel(),
                LeftPanelTab.layers => const LayersPanel(),
                LeftPanelTab.assets => const AssetsPanel(),
                LeftPanelTab.tokens => const TokensPanel(),
              },
            ),
          ),
        ],
      ),
    );
  }
}
