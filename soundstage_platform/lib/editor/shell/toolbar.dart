import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../shortcuts/intents.dart';
import '../shortcuts/shortcut_map.dart';
import 'editor_layout.dart';

/// The editor toolbar: back, title, tools, edit scope, zoom, history, panel
/// toggles, preview and help. Most controls are placeholders until their
/// tasks land (T1.2 history, T1.3 zoom, T1.4/T1.9 tools).
class EditorToolbar extends ConsumerWidget {
  const EditorToolbar({
    required this.title,
    required this.onBack,
    required this.onPreview,
    required this.onHelp,
    super.key,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback onPreview;
  final VoidCallback onHelp;

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
          for (final (tool, icon, label, id) in _tools)
            SsIconButton(
              icon: icon,
              semanticLabel: label,
              shortcut: shortcutLabel(id),
              selected: layout.tool == tool,
              onPressed: () => notifier.setTool(tool),
            ),
          const Spacer(),
          SsTooltip(
            message:
                'Edit scope: change both breakpoints, or only this one. '
                'Alt flips scope',
            placement: SsPlacement.belowCenter,
            child: SsSegmented<EditScope>(
              semanticLabel: 'Edit scope',
              selected: layout.scope,
              onChanged: notifier.setScope,
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
          SsIconButton(
            icon: SsIcons.undo2,
            semanticLabel: 'Undo',
            shortcut: shortcutLabel('undo'),
          ),
          SsIconButton(
            icon: SsIcons.redo2,
            semanticLabel: 'Redo',
            shortcut: shortcutLabel('redo'),
          ),
          const _Divider(),
          const _ZoomReadout(),
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

class _ZoomReadout extends StatelessWidget {
  const _ZoomReadout();

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Semantics(
      label: 'Zoom',
      value: '100 percent',
      child: SizedBox(
        width: 44,
        child: Text(
          '100%',
          textAlign: TextAlign.center,
          style: t.text.numeric.copyWith(color: t.colors.textSecondary),
        ),
      ),
    );
  }
}
