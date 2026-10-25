import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_frame.dart';
import '../render/render_stage_lyrics.dart';
import '../render/render_stage_shape.dart';
import '../render/render_stage_text.dart';
import '../render/stage_environment.dart';
import 'stage_behaviors.dart';

/// Provides the [StageEnvironment] to every stage widget below it.
class StageScope extends InheritedWidget {
  const StageScope({
    super.key,
    required this.environment,
    required super.child,
  });

  final StageEnvironment environment;

  /// The nearest environment, or a default play-mode one without media.
  static StageEnvironment of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StageScope>()?.environment ??
      const StageEnvironment();

  @override
  bool updateShouldNotify(StageScope oldWidget) =>
      !identical(environment, oldWidget.environment);
}

/// Maps a [ir.ResolvedNode] subtree to stage render-object widgets, keyed by
/// node id so render objects survive re-resolution (architecture §14).
///
/// - frames → [RenderStageFrame] (placeholders too: see §17.2),
/// - text → [RenderStageText], from `ResolvedNode.paragraphs` only,
/// - shapes, and for now videos and embeds → [RenderStageShape].
///
/// [referenceSize] overrides the root frame's reference size (a scene root
/// passes its breakpoint's `designSize`). Nodes in [repaintBoundaryIds]
/// (scene roots and animated nodes, §17.1) become repaint boundaries.
///
/// **Rebuilds follow the edited path (§17.1).** A child's widget is reused
/// (the same instance) while its `ResolvedNode` is identical and the
/// boundary set is the same object, so Flutter skips it: after an edit,
/// which re-resolves only the path to the edited node, only the widgets on
/// that path build again ([StageNodeWidget.forChild]). Keep
/// [repaintBoundaryIds] stable across builds (`StageSceneView` does) or
/// every child rebuilds.
class StageNodeWidget extends StatelessWidget {
  const StageNodeWidget({
    super.key,
    required this.node,
    this.referenceSize,
    this.repaintBoundaryIds = const {},
  });

  /// The widget for child [node], reused while [node] and
  /// [repaintBoundaryIds] are the same objects as last time.
  factory StageNodeWidget.forChild(
    ir.ResolvedNode node,
    Set<String> repaintBoundaryIds,
  ) {
    final last = _childWidgets[node];
    if (last != null &&
        identical(last.repaintBoundaryIds, repaintBoundaryIds)) {
      return last;
    }
    return _childWidgets[node] = StageNodeWidget(
      key: ValueKey<String>(node.id),
      node: node,
      repaintBoundaryIds: repaintBoundaryIds,
    );
  }

  static final Expando<StageNodeWidget> _childWidgets = Expando(
    'StageNodeWidget',
  );

  /// Test counter: [build] calls (an edit must rebuild only its path).
  static int debugBuildCount = 0;

  final ir.ResolvedNode node;
  final Size? referenceSize;
  final Set<String> repaintBoundaryIds;

  @override
  Widget build(BuildContext context) {
    assert(() {
      debugBuildCount++;
      return true;
    }());
    final env = StageScope.of(context);
    final boundary = repaintBoundaryIds.contains(node.id);
    return switch (node.node) {
      final ir.FrameNode frame
          when env.mode == StageRenderMode.play &&
              _interactive(frame.behavior) =>
        _BehaviorFrame(
          node: node,
          referenceSize: referenceSize,
          boundary: boundary,
          repaintBoundaryIds: repaintBoundaryIds,
        ),
      final ir.FrameNode frame => StageFrameWidget(
        node: frame,
        environment: env,
        referenceSize: referenceSize,
        repaintBoundary: boundary,
        placeholder: node.isPlaceholder,
        children: [
          for (final child in node.children)
            if (frame.behavior case final ir.LyricsBehavior lyrics
                when identical(child, lyricsTemplateOf(node)))
              StageLyricsWidget(
                key: ValueKey<String>(child.id),
                node: child.node as ir.TextNode,
                paragraphs: child.paragraphs ?? const [],
                behavior: lyrics,
                lyrics: env.audioTracks[lyrics.audioTrackId]?.lyrics,
                environment: env,
                repaintBoundary: true,
              )
            else
              StageNodeWidget.forChild(child, repaintBoundaryIds),
        ],
      ),
      final ir.TextNode text => StageTextWidget(
        node: text,
        paragraphs: node.paragraphs ?? const [],
        environment: env,
        repaintBoundary: boundary,
      ),
      final ir.Node other => StageShapeWidget(
        node: other,
        environment: env,
        repaintBoundary: boundary,
      ),
    };
  }
}

bool _interactive(ir.Behavior? b) =>
    b is ir.CarouselBehavior ||
    b is ir.MarqueeBehavior ||
    b is ir.LightboxBehavior;

/// A frame with a play-mode behaviour (stage_behaviors.dart). Stateful so
/// the key that reaches its render object survives rebuilds.
class _BehaviorFrame extends StatefulWidget {
  const _BehaviorFrame({
    required this.node,
    required this.referenceSize,
    required this.boundary,
    required this.repaintBoundaryIds,
  });

  final ir.ResolvedNode node;
  final Size? referenceSize;
  final bool boundary;
  final Set<String> repaintBoundaryIds;

  @override
  State<_BehaviorFrame> createState() => _BehaviorFrameState();
}

class _BehaviorFrameState extends State<_BehaviorFrame> {
  final GlobalKey _frameKey = GlobalKey(debugLabel: 'behavior frame');

  @override
  Widget build(BuildContext context) {
    final env = StageScope.of(context);
    final node = widget.node;
    final frame = node.node as ir.FrameNode;
    final members = [
      for (final c in node.children)
        if (c.node.common.visible) c,
    ];
    return wrapStageBehavior(
      behavior: frame.behavior,
      frameKey: _frameKey,
      memberCount: members.length,
      // A member alone in a bare frame of its size (its own stored place
      // and constraints do not apply there), under this stage's scope.
      buildMember: (i) => stageNodeAlone(env, members[i]),
      child: StageFrameWidget(
        key: _frameKey,
        node: frame,
        environment: env,
        referenceSize: widget.referenceSize,
        repaintBoundary: widget.boundary,
        placeholder: node.isPlaceholder,
        children: [
          for (final child in node.children)
            StageNodeWidget.forChild(child, widget.repaintBoundaryIds),
        ],
      ),
    );
  }
}

/// Node [m] alone in a bare frame of its size (its stored place and
/// constraints do not apply there): a lightbox's full-screen view. Not in
/// the player's node registry, so the copy never takes the original's track
/// bindings.
Widget stageNodeAlone(StageEnvironment env, ir.ResolvedNode m) {
  final c = m.node.common;
  final alone = m.copyWith(
    node: m.node.copyWith(
      common: c.copyWith(
        x: 0,
        y: 0,
        rotation: 0,
        layoutChild: const ir.LayoutChild(),
      ),
    ),
  );
  final copyEnv = StageEnvironment(
    mode: env.mode,
    fonts: env.fonts,
    media: env.media,
    painter: env.painter,
    audioTracks: env.audioTracks,
  );
  return StageScope(
    environment: copyEnv,
    child: StageFrameWidget(
      node: ir.FrameNode(
        common: ir.NodeCommon(
          id: '${m.id}#alone',
          width: c.width,
          height: c.height,
        ),
      ),
      environment: copyEnv,
      children: [StageNodeWidget.forChild(alone, const {})],
    ),
  );
}

/// The line template of a `Lyrics` frame: its first text child (null when
/// it has none, and the behaviour renders nothing).
ir.ResolvedNode? lyricsTemplateOf(ir.ResolvedNode frame) {
  for (final c in frame.children) {
    if (c.node is ir.TextNode) return c;
  }
  return null;
}

/// The render-object widget of a `Lyrics` line stack (see
/// [RenderStageLyrics]).
class StageLyricsWidget extends LeafRenderObjectWidget {
  const StageLyricsWidget({
    super.key,
    required this.node,
    required this.paragraphs,
    required this.behavior,
    required this.lyrics,
    required this.environment,
    this.repaintBoundary = false,
  });

  final ir.TextNode node;
  final List<ir.ResolvedParagraph> paragraphs;
  final ir.LyricsBehavior behavior;
  final ir.LyricsDoc? lyrics;
  final StageEnvironment environment;
  final bool repaintBoundary;

  @override
  RenderStageLyrics createRenderObject(BuildContext context) =>
      RenderStageLyrics(
        node: node,
        paragraphs: paragraphs,
        behavior: behavior,
        lyrics: lyrics,
        environment: environment,
        repaintBoundary: repaintBoundary,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderStageLyrics renderObject,
  ) {
    renderObject
      ..node = node
      ..paragraphs = paragraphs
      ..behavior = behavior
      ..lyrics = lyrics
      ..environment = environment
      ..repaintBoundary = repaintBoundary;
  }
}

/// The render-object widget of a frame.
class StageFrameWidget extends MultiChildRenderObjectWidget {
  const StageFrameWidget({
    super.key,
    required this.node,
    required this.environment,
    this.referenceSize,
    this.repaintBoundary = false,
    this.placeholder = false,
    super.children,
  });

  final ir.FrameNode node;
  final StageEnvironment environment;
  final Size? referenceSize;
  final bool repaintBoundary;
  final bool placeholder;

  @override
  RenderStageFrame createRenderObject(BuildContext context) => RenderStageFrame(
    node: node,
    environment: environment,
    referenceSize: referenceSize,
    repaintBoundary: repaintBoundary,
    placeholder: placeholder,
  );

  @override
  void updateRenderObject(BuildContext context, RenderStageFrame renderObject) {
    renderObject
      ..node = node
      ..environment = environment
      ..referenceSize = referenceSize
      ..repaintBoundary = repaintBoundary
      ..placeholder = placeholder;
  }
}

/// The render-object widget of a text node.
class StageTextWidget extends LeafRenderObjectWidget {
  const StageTextWidget({
    super.key,
    required this.node,
    required this.paragraphs,
    required this.environment,
    this.repaintBoundary = false,
  });

  final ir.TextNode node;
  final List<ir.ResolvedParagraph> paragraphs;
  final StageEnvironment environment;
  final bool repaintBoundary;

  @override
  RenderStageText createRenderObject(BuildContext context) => RenderStageText(
    node: node,
    paragraphs: paragraphs,
    environment: environment,
    repaintBoundary: repaintBoundary,
  );

  @override
  void updateRenderObject(BuildContext context, RenderStageText renderObject) {
    renderObject
      ..node = node
      ..paragraphs = paragraphs
      ..environment = environment
      ..repaintBoundary = repaintBoundary;
  }
}

/// The render-object widget of a shape (and, until M3, video and embed).
class StageShapeWidget extends LeafRenderObjectWidget {
  const StageShapeWidget({
    super.key,
    required this.node,
    required this.environment,
    this.repaintBoundary = false,
  });

  final ir.Node node;
  final StageEnvironment environment;
  final bool repaintBoundary;

  @override
  RenderStageShape createRenderObject(BuildContext context) => RenderStageShape(
    node: node,
    environment: environment,
    repaintBoundary: repaintBoundary,
  );

  @override
  void updateRenderObject(BuildContext context, RenderStageShape renderObject) {
    renderObject
      ..node = node
      ..environment = environment
      ..repaintBoundary = repaintBoundary;
  }
}
