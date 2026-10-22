import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_scene.dart';
import '../render/stage_environment.dart';
import 'stage_node_widget.dart';

/// Renders one [ir.ResolvedScene] at [viewportSize] (architecture §3.2).
///
/// - `pinned`: the stage root is sized to the viewport; its reference size
///   is the active [breakpoint]'s `designSize`.
/// - `flow`: the root is laid out at the viewport width with its own
///   vertical sizing. Its reference size is the `designSize` width and the
///   root's stored height (see `lib/runtime/README.md`).
///
/// The scene root and every node a track animates are repaint boundaries
/// (§17.1). Scrolling, pinning and clocks arrive with `StagePlayer` (T0.6);
/// this widget is the static building block it uses.
class StageSceneView extends StatelessWidget {
  const StageSceneView({
    super.key,
    required this.scene,
    required this.viewportSize,
    this.breakpoint,
  });

  final ir.ResolvedScene scene;
  final Size viewportSize;

  /// The breakpoint the scene was resolved for (`ResolvedDocument.breakpoint`).
  final ir.Breakpoint? breakpoint;

  /// The reference size of [scene]'s root at [breakpoint].
  static Size referenceSizeFor(
    ir.ResolvedScene scene,
    ir.Breakpoint? breakpoint,
  ) {
    final root = scene.root.node.common;
    final design = breakpoint?.designSize;
    return Size(
      design?.width ?? root.width,
      scene.kind == ir.SceneKind.pinned
          ? (design?.height ?? root.height)
          : root.height,
    );
  }

  @override
  Widget build(BuildContext context) {
    final env = StageScope.of(context);
    final root = scene.root;
    return StageSceneBox(
      kind: scene.kind,
      viewportSize: viewportSize,
      background: scene.background,
      environment: env,
      child: StageNodeWidget(
        key: ValueKey<String>(root.id),
        node: root,
        referenceSize: referenceSizeFor(scene, breakpoint),
        repaintBoundaryIds: {root.id, for (final t in scene.tracks) t.target},
      ),
    );
  }
}

/// The render-object widget of [RenderStageScene].
class StageSceneBox extends SingleChildRenderObjectWidget {
  const StageSceneBox({
    super.key,
    required this.kind,
    required this.viewportSize,
    required this.background,
    required this.environment,
    super.child,
  });

  final ir.SceneKind kind;
  final Size viewportSize;
  final List<ir.Paint> background;
  final StageEnvironment environment;

  @override
  RenderStageScene createRenderObject(BuildContext context) => RenderStageScene(
    kind: kind,
    viewportSize: viewportSize,
    background: background,
    environment: environment,
  );

  @override
  void updateRenderObject(BuildContext context, RenderStageScene renderObject) {
    renderObject
      ..kind = kind
      ..viewportSize = viewportSize
      ..background = background
      ..environment = environment;
  }
}
