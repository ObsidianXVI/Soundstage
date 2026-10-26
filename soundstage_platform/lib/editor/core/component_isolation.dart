import 'package:soundstage_platform/ir/ir.dart' as ir;

// Isolation mode (m3.md T3.2; DECISIONS 26/10/26 #8): editing a main
// component on its own. While isolated, the editor's document is a *view*:
// the story with its scenes and overlay set aside and one synthetic scene
// whose stage holds the component's root. Every tool, panel and command
// works on that view unchanged; the story document is the view folded back
// (the component's root taken from the stage, the scenes and overlay
// restored). Undo snapshots carry the isolation, so undoing past the entry
// leaves it.

/// The synthetic scene of isolation mode.
const String kIsolationSceneId = '__component__';

/// The synthetic scene's stage frame (the component's root is its child).
const String kIsolationStageId = '__component_stage__';

/// What isolation mode set aside.
class ComponentIsolation {
  const ComponentIsolation({
    required this.componentId,
    required this.rootId,
    required this.scenes,
    required this.overlay,
    this.returnSceneId,
  });

  final String componentId;

  /// The component root's id (stable while isolated).
  final String rootId;

  /// The story's scenes and overlay, unchanged while isolated.
  final List<ir.Scene> scenes;
  final ir.FrameNode? overlay;

  /// The scene to show again on leaving.
  final String? returnSceneId;
}

/// The isolation view of [doc] for component [componentId] at
/// [designSize] (the widest breakpoint's), and what it set aside.
(ir.StageDocument, ComponentIsolation) isolate(
  ir.StageDocument doc,
  String componentId, {
  String? returnSceneId,
}) {
  final def = doc.components[componentId]!;
  final root = def.root;
  final iso = ComponentIsolation(
    componentId: componentId,
    rootId: root.id,
    scenes: doc.scenes,
    overlay: doc.overlay,
    returnSceneId: returnSceneId,
  );
  final stage = ir.FrameNode(
    common: ir.NodeCommon(
      id: kIsolationStageId,
      name: def.name,
      width: root.common.width,
      height: root.common.height,
    ),
    children: [root],
  );
  final view = doc.copyWith(
    scenes: [
      ir.Scene(
        id: kIsolationSceneId,
        name: def.name,
        kind: ir.SceneKind.flow,
        root: stage,
        clocks: const [
          ir.Clock.sceneScroll(
            id: '__component_clock__',
            sceneId: kIsolationSceneId,
          ),
        ],
      ),
    ],
    overlay: null,
    // The definition's root lives on the stage while isolated (no
    // duplicate ids in the view).
    components: {
      ...doc.components,
      componentId: def.copyWith(root: _placeholder),
    },
  );
  return (view, iso);
}

const ir.FrameNode _placeholder = ir.FrameNode(
  common: ir.NodeCommon(id: '__component_placeholder__'),
);

final Expando<ir.StageDocument> _folded = Expando('foldIsolation');

/// The story document behind isolation view [view] (cached per view).
///
/// Layers drawn on the stage outside the component's root move into it
/// (keeping where they show). A deleted root keeps the previous one.
ir.StageDocument foldIsolation(ir.StageDocument view, ComponentIsolation iso) =>
    _folded[view] ??= _fold(view, iso);

ir.StageDocument _fold(ir.StageDocument view, ComponentIsolation iso) {
  final def = view.components[iso.componentId];
  if (def == null || view.scenes.isEmpty) {
    return view.copyWith(scenes: iso.scenes, overlay: iso.overlay);
  }
  final stage = view.scenes.first.root;
  ir.FrameNode? root;
  final extras = <ir.Node>[];
  for (final c in stage.children) {
    if (c.id == iso.rootId && c is ir.FrameNode) {
      root = c;
    } else {
      extras.add(c);
    }
  }
  if (root == null) {
    return view.copyWith(scenes: iso.scenes, overlay: iso.overlay);
  }
  if (extras.isNotEmpty) {
    final r = root;
    root = r.copyWith(
      children: [
        ...r.children,
        for (final e in extras)
          e.copyWith(
            common: e.common.copyWith(
              x: e.common.x - r.common.x,
              y: e.common.y - r.common.y,
            ),
          ),
      ],
    );
  }
  return view.copyWith(
    scenes: iso.scenes,
    overlay: iso.overlay,
    components: {
      ...view.components,
      iso.componentId: def.copyWith(root: root),
    },
  );
}
