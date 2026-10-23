import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../canvas/camera.dart';
import '../canvas/canvas_controller.dart';
import '../core/editor_controller.dart';
import '../core/editor_state.dart';
import '../shortcuts/shortcut_map.dart';
import 'editor_layout.dart';

/// The editor toolbar: back, title, tools, edit scope, save status,
/// undo/redo, zoom, panel toggles, preview and help, bound to the
/// `EditorController` and the canvas camera. Insert tools select but do
/// nothing yet (T1.9).
class EditorToolbar extends ConsumerWidget {
  const EditorToolbar({
    required this.title,
    required this.onBack,
    required this.onPreview,
    required this.onHelp,
    this.saveStatus,
    super.key,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onPreview;
  final VoidCallback onHelp;

  /// The app's autosave indicator.
  final Widget? saveStatus;

  static const _tools = <(EditorTool, IconData, String, String)>[
    (EditorTool.move, SsIcons.mousePointer2, 'Move', 'toolMove'),
    (EditorTool.frame, SsIcons.frame, 'Frame', 'toolFrame'),
    (EditorTool.text, SsIcons.type, 'Text', 'toolText'),
    (EditorTool.rectangle, SsIcons.square, 'Rectangle', 'toolRectangle'),
    (EditorTool.ellipse, SsIcons.circle, 'Ellipse', 'toolEllipse'),
    (EditorTool.hand, SsIcons.hand, 'Hand', 'toolHand'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final c = t.colors;
    final layout = ref.watch(editorLayoutProvider);
    final notifier = ref.read(editorLayoutProvider.notifier);
    final editor = ref.read(editorControllerProvider.notifier);
    final tool = ref.watch(editorControllerProvider.select((s) => s.tool));
    final scope = ref.watch(
      editorControllerProvider.select((s) => s.effectiveScope),
    );
    final flipped = ref.watch(
      editorControllerProvider.select((s) => s.scopeFlipped),
    );
    final history = ref.watch(
      editorControllerProvider.select((s) => s.history),
    );
    final canvas = ref.watch(canvasControllerProvider);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: [
          SsIconButton(
            icon: SsIcons.arrowLeft,
            semanticLabel: 'Back to stories',
            onPressed: onBack,
          ),
          const SizedBox(width: SsSpace.s1),
          Flexible(
            flex: 2,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                title,
                key: const ValueKey<String>('toolbar-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.text.bodyStrong,
              ),
            ),
          ),
          const _Divider(),
          for (final (t, icon, label, id) in _tools)
            SsIconButton(
              icon: icon,
              semanticLabel: label,
              shortcut: shortcutLabel(id),
              selected: tool == t,
              onPressed: () => editor.setTool(t),
            ),
          const Spacer(),
          SsTooltip(
            message:
                'Edit scope: change both breakpoints, or only this one. '
                'Alt flips scope',
            placement: SsPlacement.belowCenter,
            child: SsSegmented<EditScope>(
              key: ValueKey<String>('edit-scope${flipped ? '-flipped' : ''}'),
              semanticLabel: flipped
                  ? 'Edit scope (flipped by Alt)'
                  : 'Edit scope',
              selected: scope,
              onChanged: (v) => editor.setEditScope(flipped ? v.flipped : v),
              segments: const [
                SsSegment(value: EditScope.both, label: 'Both'),
                SsSegment(
                  value: EditScope.thisBreakpoint,
                  label: 'This breakpoint',
                ),
              ],
            ),
          ),
          const Spacer(),
          if (saveStatus != null) ...[saveStatus!, const _Divider()],
          SsIconButton(
            icon: SsIcons.undo2,
            semanticLabel: history.undoLabel == null
                ? 'Undo'
                : 'Undo ${history.undoLabel}',
            shortcut: shortcutLabel('undo'),
            onPressed: history.canUndo ? editor.undo : null,
          ),
          SsIconButton(
            icon: SsIcons.redo2,
            semanticLabel: history.redoLabel == null
                ? 'Redo'
                : 'Redo ${history.redoLabel}',
            shortcut: shortcutLabel('redo'),
            onPressed: history.canRedo ? editor.redo : null,
          ),
          const _Divider(),
          _ZoomReadout(controller: canvas),
          const _Divider(),
          SsIconButton(
            icon: SsIcons.panelLeft,
            semanticLabel: 'Toggle left panel',
            shortcut: shortcutLabel('toggleLeft'),
            selected: layout.leftOpen,
            onPressed: notifier.toggleLeft,
          ),
          SsIconButton(
            icon: SsIcons.panelBottom,
            semanticLabel: 'Toggle timeline',
            shortcut: shortcutLabel('toggleTimeline'),
            selected: layout.timelineOpen,
            onPressed: notifier.toggleTimeline,
          ),
          SsIconButton(
            icon: SsIcons.panelRight,
            semanticLabel: 'Toggle inspector',
            shortcut: shortcutLabel('toggleRight'),
            selected: layout.rightOpen,
            onPressed: notifier.toggleRight,
          ),
          const _Divider(),
          SsIconButton(
            icon: SsIcons.keyboard,
            semanticLabel: 'Keyboard shortcuts',
            shortcut: shortcutLabel('help'),
            onPressed: onHelp,
          ),
          const SizedBox(width: SsSpace.s1),
          SsButton(
            label: 'Preview',
            icon: SsIcons.play,
            variant: SsButtonVariant.primary,
            onPressed: onPreview,
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 20,
    margin: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
    color: context.ss.colors.border,
  );
}

/// The live zoom; clicking it zooms to fit. Rebuilds only itself on zoom.
class _ZoomReadout extends StatelessWidget {
  const _ZoomReadout({required this.controller});

  final CanvasController controller;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return ValueListenableBuilder<CanvasCamera>(
      valueListenable: controller.camera,
      builder: (context, cam, _) {
        final label = CanvasController.zoomLabel(cam.zoom);
        return SsTooltip(
          message: 'Zoom to fit',
          shortcut: shortcutLabel('zoomFit'),
          placement: SsPlacement.belowCenter,
          child: Semantics(
            label: 'Zoom',
            value: label,
            button: true,
            child: GestureDetector(
              onTap: controller.zoomToFit,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: SizedBox(
                  width: 52,
                  child: Text(
                    label,
                    key: const ValueKey<String>('zoom-readout'),
                    textAlign: TextAlign.center,
                    style: t.text.numeric.copyWith(
                      color: t.colors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
