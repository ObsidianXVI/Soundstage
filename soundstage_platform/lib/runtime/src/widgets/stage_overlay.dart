import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_box.dart';
import 'stage_scene_view.dart';

/// The story overlay (architecture §3, `StageDocument.overlay`): persistent
/// chrome above every scene, laid out over the viewport like a pinned
/// scene's stage. Pointers pass through to the story except where an
/// overlay layer is (its root frame itself does not take them).
class StageOverlayView extends StatelessWidget {
  const StageOverlayView({
    required this.root,
    required this.viewportSize,
    required this.breakpoint,
    super.key,
  });

  final ir.ResolvedNode root;
  final Size viewportSize;
  final ir.Breakpoint? breakpoint;

  @override
  Widget build(BuildContext context) => _OverlayHits(
    rootId: root.id,
    child: StageSceneView(
      scene: ir.ResolvedScene(
        id: '${root.id}#overlay',
        name: '',
        kind: ir.SceneKind.pinned,
        scrollLength: 0,
        root: root,
        clocks: const [],
        tracks: const [],
        background: const [],
        transitionIn: const ir.SceneTransition(),
        modes: const {},
      ),
      viewportSize: viewportSize,
      breakpoint: breakpoint,
    ),
  );
}

class _OverlayHits extends SingleChildRenderObjectWidget {
  const _OverlayHits({required this.rootId, super.child});

  final String rootId;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderOverlayHits(rootId);

  @override
  void updateRenderObject(BuildContext context, _RenderOverlayHits r) =>
      r.rootId = rootId;
}

class _RenderOverlayHits extends RenderProxyBox {
  _RenderOverlayHits(this.rootId);

  String rootId;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final probe = BoxHitTestResult();
    if (!super.hitTest(probe, position: position)) return false;
    final onLayer = probe.path.any(
      (e) =>
          e.target is RenderStageBox &&
          (e.target as RenderStageBox).nodeId != rootId,
    );
    return onLayer && super.hitTest(result, position: position);
  }
}
