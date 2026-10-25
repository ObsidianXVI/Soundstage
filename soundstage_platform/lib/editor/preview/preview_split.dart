import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../shell/resize_handle.dart';
import 'preview_pane.dart';
import 'preview_state.dart';

/// Narrowest the preview pane and the canvas may get.
const double kPreviewPaneMin = 300;
const double kPreviewCanvasMin = 240;

/// The canvas area (T2.6): the editor [canvas], plus, when Preview is on, a
/// draggable divider and the live preview pane to its right.
class PreviewSplit extends ConsumerWidget {
  const PreviewSplit({required this.canvas, this.onOpenInNewTab, super.key});

  final Widget canvas;
  final VoidCallback? onOpenInNewTab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preview = ref.watch(previewProvider);
    if (!preview.open) return canvas;
    final notifier = ref.read(previewProvider.notifier);
    return LayoutBuilder(
      builder: (context, box) {
        final total = box.maxWidth;
        const handle = 7.0;
        final maxPane = math.max(
          kPreviewPaneMin,
          total - kPreviewCanvasMin - handle,
        );
        final pane = (preview.fraction * total).clamp(kPreviewPaneMin, maxPane);
        return Row(
          children: [
            Expanded(child: canvas),
            ResizeHandle(
              semanticLabel: 'Resize preview',
              onDelta: (d) => notifier.setFraction((pane - d) / total),
              onReset: () => notifier.setFraction(0.42),
            ),
            SizedBox(
              width: pane.toDouble(),
              child: PreviewPane(onOpenInNewTab: onOpenInNewTab),
            ),
          ],
        );
      },
    );
  }
}
