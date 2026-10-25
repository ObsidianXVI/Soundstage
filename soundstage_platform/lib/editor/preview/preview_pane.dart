import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../canvas/canvas_controller.dart' show artboardBreakpoints;
import '../core/editor_controller.dart';
import 'preview_stage.dart';
import 'preview_state.dart';

/// The preview pane (T2.6): a header (width picker, follow, restart, mute,
/// open in a new tab) over the live [PreviewStage].
class PreviewPane extends ConsumerStatefulWidget {
  const PreviewPane({this.onOpenInNewTab, super.key});

  /// Opens the full-window player in a new browser tab; the control is
  /// hidden without it.
  final VoidCallback? onOpenInNewTab;

  @override
  ConsumerState<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends ConsumerState<PreviewPane> {
  final PreviewStageController _stage = PreviewStageController();

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final preview = ref.watch(previewProvider);
    final notifier = ref.read(previewProvider.notifier);
    final boards = ref.watch(
      editorControllerProvider.select((s) => Identity(s.document)),
    );
    final doc = boards.value;
    final primaries = artboardBreakpoints(doc);
    final selected =
        preview.breakpointId ??
        (primaries.isEmpty ? kPreviewFreeWidth : primaries.first.id);
    final value =
        selected == kPreviewFreeWidth || primaries.any((b) => b.id == selected)
        ? selected
        : (primaries.isEmpty ? kPreviewFreeWidth : primaries.first.id);
    return Container(
      key: const ValueKey<String>('preview-pane'),
      color: c.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: SsSpace.s2,
              vertical: SsSpace.s1,
            ),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: c.borderSubtle)),
            ),
            child: Wrap(
              spacing: SsSpace.s1,
              runSpacing: SsSpace.s1,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SsDropdown<String>(
                  semanticLabel: 'Preview width',
                  width: 168,
                  value: value,
                  items: [
                    for (final b in primaries)
                      SsDropdownItem(
                        value: b.id,
                        label: '${b.name} ${b.designSize.width.round()}',
                      ),
                    const SsDropdownItem(
                      value: kPreviewFreeWidth,
                      label: 'Free width',
                    ),
                  ],
                  onChanged: (id) => id == kPreviewFreeWidth
                      ? notifier.chooseFree()
                      : notifier.chooseBreakpoint(id),
                ),
                if (value == kPreviewFreeWidth)
                  SsNumberField(
                    key: const ValueKey<String>('preview-free-width'),
                    semanticLabel: 'Preview free width',
                    label: 'W',
                    unit: 'px',
                    width: 96,
                    value: preview.freeWidth,
                    min: kPreviewMinFreeWidth,
                    max: kPreviewMaxFreeWidth,
                    fractionDigits: 0,
                    onChanged: notifier.setFreeWidth,
                  ),
                SsIconButton(
                  icon: SsIcons.link,
                  semanticLabel: 'Follow the active scene',
                  selected: preview.follow,
                  size: 28,
                  onPressed: notifier.toggleFollow,
                ),
                SsIconButton(
                  icon: SsIcons.rotateCcw,
                  semanticLabel: 'Restart preview',
                  size: 28,
                  onPressed: _stage.restart,
                ),
                SsIconButton(
                  icon: SsIcons.volume2,
                  semanticLabel: preview.muted ? 'Unmute' : 'Mute',
                  selected: preview.muted,
                  size: 28,
                  onPressed: notifier.toggleMuted,
                ),
                if (widget.onOpenInNewTab != null)
                  SsIconButton(
                    icon: SsIcons.externalLink,
                    semanticLabel: 'Open the preview in a new tab',
                    size: 28,
                    onPressed: widget.onOpenInNewTab,
                  ),
              ],
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: c.surface0,
              child: PreviewStage(controller: _stage),
            ),
          ),
        ],
      ),
    );
  }
}
