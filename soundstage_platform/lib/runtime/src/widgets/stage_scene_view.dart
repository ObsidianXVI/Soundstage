import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../animator/behavior_drivers.dart';
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
///
/// The boundary id set handed to the node widgets keeps its identity while
/// its contents stay the same, so a rebuild after an edit only rebuilds the
/// node widgets on the edited path (see [StageNodeWidget]).
class StageSceneView extends StatefulWidget {
  const StageSceneView({
    super.key,
    required this.scene,
    required this.viewportSize,
    this.breakpoint,
    this.extraRepaintBoundaryIds = const {},
  });

  final ir.ResolvedScene scene;
  final Size viewportSize;

  /// The breakpoint the scene was resolved for (`ResolvedDocument.breakpoint`).
  final ir.Breakpoint? breakpoint;

  /// More nodes to make repaint boundaries (the editor isolates large
  /// subtrees so an edit re-records only the path to it).
  final Set<String> extraRepaintBoundaryIds;

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
  State<StageSceneView> createState() => _StageSceneViewState();
}

class _StageSceneViewState extends State<StageSceneView> {
  Set<String> _boundaries = const {};

  /// The boundary ids of the current scene, as the previous set object when
  /// the contents did not change.
  Set<String> _boundaryIds() {
    final scene = widget.scene;
    final next = {
      scene.root.id,
      for (final t in scene.tracks) t.target,
      ...behaviorTargetIds(scene),
      ...widget.extraRepaintBoundaryIds,
    };
    if (!setEquals(next, _boundaries)) _boundaries = next;
    return _boundaries;
  }

  @override
  Widget build(BuildContext context) {
    final env = StageScope.of(context);
    final scene = widget.scene;
    final root = scene.root;
    return StageSceneBox(
      kind: scene.kind,
      viewportSize: widget.viewportSize,
      background: scene.background,
      environment: env,
      child: StageNodeWidget(
        key: ValueKey<String>(root.id),
        node: root,
        referenceSize: StageSceneView.referenceSizeFor(
          scene,
          widget.breakpoint,
        ),
        repaintBoundaryIds: _boundaryIds(),
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
