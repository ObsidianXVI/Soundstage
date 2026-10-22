import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../render/render_stage_frame.dart';
import '../render/render_stage_shape.dart';
import '../render/render_stage_text.dart';
import '../render/stage_environment.dart';

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
class StageNodeWidget extends StatelessWidget {
  const StageNodeWidget({
    super.key,
    required this.node,
    this.referenceSize,
    this.repaintBoundaryIds = const {},
  });

  final ir.ResolvedNode node;
  final Size? referenceSize;
  final Set<String> repaintBoundaryIds;

  @override
  Widget build(BuildContext context) {
    final env = StageScope.of(context);
    final boundary = repaintBoundaryIds.contains(node.id);
    return switch (node.node) {
      final ir.FrameNode frame => StageFrameWidget(
        node: frame,
        environment: env,
        referenceSize: referenceSize,
        repaintBoundary: boundary,
        placeholder: node.isPlaceholder,
        children: [
          for (final child in node.children)
            StageNodeWidget(
              key: ValueKey<String>(child.id),
              node: child,
              repaintBoundaryIds: repaintBoundaryIds,
            ),
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
