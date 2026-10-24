import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/canvas_controller.dart';
import 'file_drop.dart';
import 'insert_actions.dart';

/// An asset being dragged out of the Assets panel.
class AssetDrag {
  const AssetDrag(this.assetId);

  final String assetId;
}

/// Makes the canvas accept drops (T1.9):
///
/// - **Files from the desktop** become image frames at the drop point
///   (audio and video go to the Assets panel only).
/// - **An asset from the Assets panel** dropped on a frame or shape sets
///   its image fill; dropped on bare artboard it becomes a new image frame
///   centred on the drop point.
///
/// Both land in the frame under the pointer, and in the flow at that spot
/// when it has auto layout. One drop is one undo step (the stored file is
/// added with the frame).
class CanvasDropTarget extends ConsumerWidget {
  const CanvasDropTarget({
    required this.controller,
    required this.child,
    super.key,
  });

  final CanvasController controller;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Offset local(Offset global) {
      final box = context.findRenderObject();
      return box is RenderBox ? box.globalToLocal(global) : global;
    }

    return FileDropTarget(
      caption: 'Drop images to place them',
      onDrop: (files, global) => ref
          .read(insertActionsProvider)
          .insertFiles(files, screen: local(global), canvas: controller),
      child: DragTarget<AssetDrag>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (d) => ref
            .read(insertActionsProvider)
            .dropAsset(d.data.assetId, local(d.offset), controller),
        builder: (_, _, _) => child,
      ),
    );
  }
}
