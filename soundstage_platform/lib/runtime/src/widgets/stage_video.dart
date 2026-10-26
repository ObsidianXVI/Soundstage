import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../media/video_surface.dart' deferred as video;
import '../render/render_stage_host.dart';
import '../render/stage_environment.dart';

/// The stage box of a media node with its content widget [child] (see
/// [RenderStageHost]).
class StageHostWidget extends SingleChildRenderObjectWidget {
  const StageHostWidget({
    required this.node,
    required this.environment,
    this.repaintBoundary = false,
    super.child,
    super.key,
  });

  final ir.Node node;
  final StageEnvironment environment;
  final bool repaintBoundary;

  @override
  RenderStageHost createRenderObject(BuildContext context) => RenderStageHost(
    node: node,
    environment: environment,
    repaintBoundary: repaintBoundary,
  );

  @override
  void updateRenderObject(BuildContext context, RenderStageHost renderObject) {
    renderObject
      ..node = node
      ..environment = environment
      ..repaintBoundary = repaintBoundary;
  }
}

Future<void>? _videoLoaded;

/// A video node's content: the player, loaded on first use (a deferred
/// library, so stories without video never fetch it). Plays only in play
/// mode; the editor shows its first frame.
class StageVideoView extends StatefulWidget {
  const StageVideoView({
    required this.node,
    required this.environment,
    super.key,
  });

  final ir.VideoNode node;
  final StageEnvironment environment;

  @override
  State<StageVideoView> createState() => _StageVideoViewState();
}

class _StageVideoViewState extends State<StageVideoView> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    (_videoLoaded ??= video.loadLibrary()).then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.environment.media;
    if (!_ready || media == null) return const SizedBox.expand();
    return video.buildVideoSurface(
      node: widget.node,
      asset: media.resolver.asset(widget.node.assetId),
      resolver: media.resolver,
      interactive: widget.environment.mode == StageRenderMode.play,
      reducedMotion: MediaQuery.maybeDisableAnimationsOf(context) ?? false,
    );
  }
}
