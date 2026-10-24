import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

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
import '../shortcuts/editor_shortcuts.dart';
import '../shortcuts/intents.dart';
import '../shortcuts/shortcut_help.dart';
import 'content_mode_screen.dart';
import 'editor_layout.dart';
import 'resize_handle.dart';
import 'toolbar.dart';

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
    super.key,
  });

  /// The document the editor opens with.
  final ir.StageDocument document;
  final VoidCallback onBack;

  /// Opens the player for this story (`/play/:id`).
  final VoidCallback onPreview;

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

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        initialDocumentProvider.overrideWithValue(document),
        if (assetService case final service?)
          editorAssetServiceProvider.overrideWithValue(service),
        if (filePicker case final picker?)
          editorFilePickerProvider.overrideWithValue(picker),
      ],
      child: _EditorScope(
        onBack: onBack,
        onPreview: onPreview,
        onDocumentChanged: onDocumentChanged,
        onSave: onSave,
        saveStatus: saveStatus,
      ),
    );
  }
}

/// The shell inside the editor's provider scope.
class _EditorScope extends ConsumerWidget {
  const _EditorScope({
    required this.onBack,
    required this.onPreview,
    required this.onDocumentChanged,
    required this.onSave,
    required this.saveStatus,
  });

  final VoidCallback onBack;
  final VoidCallback onPreview;
  final ValueChanged<ir.StageDocument>? onDocumentChanged;
  final VoidCallback? onSave;
  final Widget? saveStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(
      editorControllerProvider.select((s) => Identity(s.document)),
      (_, next) => onDocumentChanged?.call(next.value),
    );
    final document = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    final title = document.meta.title.isEmpty
        ? 'Untitled story'
        : document.meta.title;
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
            document: document,
            title: title,
            width: box.maxWidth,
            onBack: onBack,
            onPreview: onPreview,
            onSave: onSave,
            saveStatus: saveStatus,
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
    required this.document,
    required this.title,
    required this.width,
    required this.onBack,
    required this.onPreview,
    required this.onSave,
    required this.saveStatus,
  });

  final ir.StageDocument document;
  final String title;
  final double width;
  final VoidCallback onBack;
  final VoidCallback onPreview;
  final VoidCallback? onSave;
  final Widget? saveStatus;

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

    void help() => showShortcutHelp(context);
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
            (_) => onPreview(),
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
                  onPreview: onPreview,
                  onHelp: help,
                  saveStatus: saveStatus,
                ),
                Expanded(
                  child: Row(
                    children: [
                      if (layout.leftOpen) ...[
                        SizedBox(
                          width: leftW.toDouble(),
                          child: _LeftPanel(document: document),
                        ),
                        ResizeHandle(
                          semanticLabel: 'Resize left panel',
                          onDelta: (d) => notifier.setLeftWidth(
                            leftW + d,
                            available: width,
                          ),
                          onReset: () => notifier.setLeftWidth(264),
                        ),
                      ],
                      const Expanded(child: EditorCanvas()),
                      if (layout.rightOpen) ...[
                        ResizeHandle(
                          semanticLabel: 'Resize inspector',
                          onDelta: (d) => notifier.setRightWidth(
                            rightW - d,
                            available: width,
                          ),
                          onReset: () => notifier.setRightWidth(288),
                        ),
                        SizedBox(
                          width: rightW.toDouble(),
                          child: const Inspector(),
                        ),
                      ],
                    ],
                  ),
                ),
                _TimelineStrip(open: layout.timelineOpen),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SsSpace.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsIcon(icon, size: 24, color: t.colors.textDisabled),
            const SizedBox(height: SsSpace.s3),
            Text(title, style: t.text.bodyStrong, textAlign: TextAlign.center),
            const SizedBox(height: SsSpace.s1),
            Text(
              body,
              textAlign: TextAlign.center,
              style: t.text.small.copyWith(color: t.colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeftPanel extends ConsumerWidget {
  const _LeftPanel({required this.document});

  final ir.StageDocument document;

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
            ],
          ),
          Expanded(
            child: SsTabPanel(
              label: '${tab.name} panel',
              child: switch (tab) {
                LeftPanelTab.scenes => const ScenesPanel(),
                LeftPanelTab.layers => const LayersPanel(),
                LeftPanelTab.assets => const AssetsPanel(),
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineStrip extends ConsumerWidget {
  const _TimelineStrip({required this.open});

  final bool open;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final notifier = ref.read(editorLayoutProvider.notifier);
    return AnimatedSize(
      duration: SsMotion.base,
      curve: SsMotion.easeOut,
      alignment: Alignment.topCenter,
      child: Container(
        height: open ? 200 : 32,
        decoration: BoxDecoration(
          color: c.surface1,
          border: Border(top: BorderSide(color: c.borderSubtle)),
        ),
        child: Column(
          children: [
            SizedBox(
              height: 31,
              child: Row(
                children: [
                  const SizedBox(width: SsSpace.s3),
                  Text('Timeline', style: t.text.bodyStrong),
                  const SizedBox(width: SsSpace.s2),
                  Text('Motion editing arrives in M2', style: t.text.caption),
                  const Spacer(),
                  SsIconButton(
                    icon: open ? SsIcons.chevronDown : SsIcons.chevronUp,
                    semanticLabel: open
                        ? 'Collapse timeline'
                        : 'Expand timeline',
                    size: 24,
                    iconSize: 14,
                    onPressed: notifier.toggleTimeline,
                  ),
                  const SizedBox(width: SsSpace.s1),
                ],
              ),
            ),
            if (open)
              const Expanded(
                child: _EmptyState(
                  icon: SsIcons.audioLines,
                  title: 'Timeline',
                  body: 'Keyframes and clips will be edited here.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
