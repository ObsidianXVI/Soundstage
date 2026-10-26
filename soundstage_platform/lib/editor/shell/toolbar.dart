import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../canvas/camera.dart';
import '../canvas/canvas_controller.dart';
import '../core/commands/breakpoint_commands.dart';
import '../core/editor_controller.dart';
import '../core/editor_state.dart';
import '../preview/preview_state.dart';
import '../shortcuts/shortcut_map.dart';
import 'breakpoint_manager.dart';
import 'editor_layout.dart';

/// The editor toolbar: back, title, tools, edit scope, save status,
/// undo/redo, zoom, panel toggles, preview and help, bound to the
/// `EditorController` and the canvas camera. The insert tools (frame, text,
/// rectangle, ellipse, line) draw on the canvas (`InsertToolLayer`); the
/// image tool opens the file picker.
class EditorToolbar extends ConsumerWidget {
  const EditorToolbar({
    required this.title,
    required this.onBack,
    required this.onPreview,
    required this.onHelp,
    this.saveStatus,
    this.onPublish,
    super.key,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onPreview;
  final VoidCallback onHelp;

  /// The app's autosave indicator.
  final Widget? saveStatus;

  /// Publishes the story (m4.md T4.2); the button is hidden when null (a
  /// local-only build).
  final VoidCallback? onPublish;

  static const _tools = <(EditorTool, IconData, String, String)>[
    (EditorTool.move, SsIcons.mousePointer2, 'Move', 'toolMove'),
    (EditorTool.frame, SsIcons.frame, 'Frame', 'toolFrame'),
    (EditorTool.text, SsIcons.type, 'Text', 'toolText'),
  ];

  static const _after = <(EditorTool, IconData, String, String)>[
    (EditorTool.image, SsIcons.imagePlus, 'Image', 'toolImage'),
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
    final autoKey = ref.watch(
      editorControllerProvider.select((s) => s.autoKey),
    );
    // The breakpoint "This breakpoint" writes to: the one in effect on the
    // edited artboard (its free width may fall in another's range).
    final bpName = ref.watch(
      editorControllerProvider.select(
        (s) => breakpointName(s.document, s.breakpointId),
      ),
    );
    final canvas = ref.watch(canvasControllerProvider);
    // Below this window width the scope label shortens ("Only Tablet").
    final windowWidth = MediaQuery.sizeOf(context).width;
    final compact = windowWidth < 1280;
    // The mode picker is a dropdown until there is room for four segments.
    final narrow = windowWidth < 1800;
    // The canvas tools belong to Design and Animation (m5.md T5.1).
    final mode = layout.mode;
    final onCanvas = mode == EditorMode.design || mode == EditorMode.animation;
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
          if (narrow)
            SsDropdown<EditorMode>(
              key: const ValueKey<String>('editor-mode'),
              semanticLabel: 'Editor mode',
              width: 100,
              value: mode,
              items: [
                for (final m in EditorMode.values)
                  SsDropdownItem(value: m, label: m.label),
              ],
              onChanged: notifier.setMode,
            )
          else
            SsSegmented<EditorMode>(
              key: const ValueKey<String>('editor-mode'),
              semanticLabel: 'Editor mode',
              selected: mode,
              onChanged: notifier.setMode,
              segments: [
                for (final m in EditorMode.values)
                  SsSegment(value: m, label: m.label),
              ],
            ),
          if (onCanvas) ...[
            const _Divider(),
            for (final (t, icon, label, id) in _tools)
              SsIconButton(
                icon: icon,
                semanticLabel: label,
                shortcut: shortcutLabel(id),
                selected: tool == t,
                onPressed: () => editor.setTool(t),
              ),
            ShapeToolButton(tool: tool, onSelect: editor.setTool),
            for (final (t, icon, label, id) in _after)
              SsIconButton(
                icon: icon,
                semanticLabel: label,
                shortcut: shortcutLabel(id),
                selected: tool == t,
                onPressed: () => editor.setTool(t),
              ),
          ],
          const Spacer(),
          if (onCanvas) ...[
            SsTooltip(
              message:
                  'Edit scope: Both changes the shared design (every '
                  'breakpoint); This breakpoint changes $bpName only, the '
                  'breakpoint in effect on the edited artboard. Alt flips scope',
              placement: SsPlacement.belowCenter,
              child: SsSegmented<EditScope>(
                key: ValueKey<String>('edit-scope${flipped ? '-flipped' : ''}'),
                semanticLabel: flipped
                    ? 'Edit scope (flipped by Alt)'
                    : 'Edit scope',
                selected: scope,
                onChanged: (v) => editor.setEditScope(flipped ? v.flipped : v),
                segments: [
                  const SsSegment(value: EditScope.both, label: 'Both'),
                  SsSegment(
                    value: EditScope.thisBreakpoint,
                    label: bpName.isEmpty
                        ? 'This breakpoint'
                        : (compact
                              ? 'Only $bpName'
                              : 'This breakpoint: $bpName'),
                  ),
                ],
              ),
            ),
            const SizedBox(width: SsSpace.s1),
            const BreakpointManagerButton(),
          ],
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
          if (onCanvas) ...[const _Divider(), _ZoomReadout(controller: canvas)],
          const _Divider(),
          if (onCanvas) ...[
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
          ],
          // Below 1600 px: ? still opens the shortcut list.
          if (windowWidth >= 1600)
            SsIconButton(
              icon: SsIcons.keyboard,
              semanticLabel: 'Keyboard shortcuts',
              shortcut: shortcutLabel('help'),
              onPressed: onHelp,
            ),
          if (onCanvas) ...[
            const SizedBox(width: SsSpace.s1),
            SsIconButton(
              key: const ValueKey<String>('toolbar-autokey'),
              icon: SsIcons.timer,
              semanticLabel: autoKey ? 'Auto-key on' : 'Auto-key',
              tooltip: autoKey
                  ? 'Auto-key is on: changes to properties write keyframes'
                  : 'Auto-key: changes to properties write keyframes',
              selected: autoKey,
              selectedColor: c.danger,
              onPressed: () => editor.setAutoKey(!autoKey),
            ),
          ],
          // Publish mode shows the player itself.
          if (mode != EditorMode.publish) ...[
            const SizedBox(width: SsSpace.s1),
            if (compact)
              SsIconButton(
                icon: SsIcons.play,
                semanticLabel: 'Preview',
                selected: ref.watch(previewProvider.select((s) => s.open)),
                onPressed: onPreview,
              )
            else
              SsButton(
                label: 'Preview',
                icon: SsIcons.play,
                variant: ref.watch(previewProvider.select((s) => s.open))
                    ? SsButtonVariant.secondary
                    : SsButtonVariant.primary,
                onPressed: onPreview,
              ),
          ],
          const SizedBox(width: SsSpace.s1),
          SsIconButton(
            key: const ValueKey<String>('toolbar-agent'),
            icon: SsIcons.sparkles,
            semanticLabel: 'Agent',
            selected: layout.agentOpen,
            onPressed: notifier.toggleAgent,
          ),
          if (onPublish != null) ...[
            const SizedBox(width: SsSpace.s1),
            if (compact)
              SsIconButton(
                key: const ValueKey<String>('toolbar-publish'),
                icon: SsIcons.globe,
                semanticLabel: 'Publish',
                onPressed: onPublish,
              )
            else
              SsButton(
                key: const ValueKey<String>('toolbar-publish'),
                label: 'Publish',
                icon: SsIcons.globe,
                onPressed: onPublish,
              ),
          ],
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

/// The shape tools (Figma's shape menu): the button holds the last shape
/// tool used (a click picks it again; R, O and L still pick theirs), and
/// the chevron opens the menu of all five.
class ShapeToolButton extends StatefulWidget {
  const ShapeToolButton({
    required this.tool,
    required this.onSelect,
    super.key,
  });

  final EditorTool tool;
  final ValueChanged<EditorTool> onSelect;

  /// The shape tools in menu order: tool, icon, label, shortcut id.
  static const shapes = <(EditorTool, IconData, String, String)>[
    (EditorTool.rectangle, SsIcons.square, 'Rectangle', 'toolRectangle'),
    (EditorTool.line, SsIcons.minus, 'Line', 'toolLine'),
    (EditorTool.ellipse, SsIcons.circle, 'Ellipse', 'toolEllipse'),
    (EditorTool.polygon, SsIcons.hexagon, 'Polygon', 'toolPolygon'),
    (EditorTool.star, SsIcons.star, 'Star', 'toolStar'),
  ];

  @override
  State<ShapeToolButton> createState() => _ShapeToolButtonState();
}

class _ShapeToolButtonState extends State<ShapeToolButton> {
  EditorTool _last = EditorTool.rectangle;

  @override
  void didUpdateWidget(ShapeToolButton old) {
    super.didUpdateWidget(old);
    if (ShapeToolButton.shapes.any((e) => e.$1 == widget.tool)) {
      _last = widget.tool;
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ShapeToolButton.shapes.firstWhere((e) => e.$1 == _last);
    final active = ShapeToolButton.shapes.any((e) => e.$1 == widget.tool);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SsIconButton(
          key: const ValueKey<String>('tool-shape'),
          icon: current.$2,
          semanticLabel: current.$3,
          shortcut: shortcutLabel(current.$4),
          selected: active,
          onPressed: () => widget.onSelect(current.$1),
        ),
        Builder(
          builder: (anchor) => SsIconButton(
            key: const ValueKey<String>('tool-shape-menu'),
            icon: SsIcons.chevronDown,
            semanticLabel: 'Shape tools',
            tooltip: 'Shape tools',
            size: 16,
            iconSize: 12,
            onPressed: () => showSsMenu(
              anchor,
              anchor: ssGlobalRect(anchor),
              placement: SsPlacement.belowStart,
              minWidth: 180,
              entries: [
                for (final (t, icon, label, id) in ShapeToolButton.shapes)
                  SsMenuItem(
                    label: label,
                    icon: icon,
                    shortcut: shortcutLabel(id),
                    checked: widget.tool == t,
                    onSelected: () => widget.onSelect(t),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
