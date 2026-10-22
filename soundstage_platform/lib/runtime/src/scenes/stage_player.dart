import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../animator/node_registry.dart';
import '../animator/stage_animator.dart';
import '../clocks/clock_source.dart';
import '../clocks/timeline_clock.dart';
import '../render/render_stage_frame.dart' show stageDevicePixelRatio;
import '../render/stage_environment.dart';
import '../widgets/stage_node_widget.dart';
import '../widgets/stage_scene_view.dart';
import 'sliver_stage_scene.dart';

/// Talks to a mounted [StagePlayer]: timeline controls, clock values, and
/// the node registry (the editor overlay's `NodeGeometryRegistry`).
class StagePlayerController {
  StageAnimator? _animator;
  StageNodeRegistry? _nodes;
  ScrollController? _scroll;

  /// Whether a player is attached.
  bool get isAttached => _animator != null;

  /// The attached player's animator.
  StageAnimator? get animator => _animator;

  /// `nodeId → render object` for the nodes currently on stage.
  StageNodeRegistry? get nodes => _nodes;

  /// The story's scroll controller.
  ScrollController? get scrollController => _scroll;

  StageTimelineSource? timeline(String clockId) => _animator?.timeline(clockId);
  void playTimeline(String clockId) => _animator?.playTimeline(clockId);
  void pauseTimeline(String clockId) => _animator?.pauseTimeline(clockId);
  void seekTimeline(String clockId, double seconds) =>
      _animator?.seekTimeline(clockId, seconds);
  double? clockValue(String clockId) => _animator?.clockValue(clockId);
}

/// Plays a story (architecture §14): one [SliverStageScene] per scene in a
/// `CustomScrollView`, with clocks and the animator driving the stage's
/// render objects.
///
/// - Resolves [document] for the viewport's breakpoint with a long-lived
///   `ir.Resolver` (incremental across edits), and re-resolves only when
///   the breakpoint or the document changes. Resizing within a breakpoint
///   relayouts without re-resolving.
/// - [mode] `edit` freezes clocks at [clockOverrides] (clock id → value),
///   makes pointer and behaviour clocks inert, and shows error boxes.
/// - [viewportOverride] renders at a fixed viewport size (editor canvas,
///   tests) instead of the available space.
/// - [initialSceneId] scrolls to that scene's start after the first layout.
/// - [clockFactories] plugs in `audio` (T0.7) and `behavior` (M3) clocks.
/// - Scrolling never rebuilds widgets or calls `setState`: scenes publish
///   progress from layout, and the animator writes into render objects.
///   The only builds are a scene entering or leaving the lazy window
///   ([lazyWindow] viewports around the visible range).
class StagePlayer extends StatefulWidget {
  const StagePlayer({
    super.key,
    required this.document,
    this.mode = StageRenderMode.play,
    this.viewportOverride,
    this.initialSceneId,
    this.clockOverrides = const {},
    this.environment,
    this.clockFactories = const StageClockFactories(),
    this.controller,
    this.lazyWindow = 1,
    this.physics,
  });

  final ir.StageDocument document;
  final StageRenderMode mode;
  final Size? viewportOverride;
  final String? initialSceneId;

  /// Edit mode: clock id → frozen value (the editor's playhead).
  final Map<String, double> clockOverrides;

  /// Fonts, media and painter for [document]; default
  /// `StageEnvironment.forDocument(document)`. The player adds its node
  /// registry and [mode].
  final StageEnvironment? environment;
  final StageClockFactories clockFactories;
  final StagePlayerController? controller;

  /// Viewports around the visible range whose scenes keep a render tree.
  final double lazyWindow;
  final ScrollPhysics? physics;

  @override
  State<StagePlayer> createState() => _StagePlayerState();
}

class _StagePlayerState extends State<StagePlayer>
    with TickerProviderStateMixin {
  final ir.Resolver _resolver = ir.Resolver();
  final StageNodeRegistry _registry = StageNodeRegistry();
  final ScrollController _scroll = ScrollController();
  late StageAnimator _animator;
  late StageEnvironment _env;

  ir.StageDocument? _resolvedDoc;
  String? _resolvedBreakpoint;
  ir.ResolvedDocument? _resolved;

  Size? _sliverViewport;
  List<Widget> _slivers = const [];
  final Map<String, GlobalKey> _sceneKeys = {};

  /// Scenes currently within the lazy window (their images are kept).
  final Set<String> _windowScenes = {};
  Map<String, Set<String>> _sceneAssets = const {};
  bool _jumped = false;

  @override
  void initState() {
    super.initState();
    _env = _environmentFor(widget);
    _animator = _newAnimator();
    _attachController(widget.controller);
  }

  StageEnvironment _environmentFor(StagePlayer w) =>
      (w.environment ?? StageEnvironment.forDocument(w.document, mode: w.mode))
          .copyWith(mode: w.mode, nodes: _registry);

  StageAnimator _newAnimator() => StageAnimator(
    registry: _registry,
    vsync: this,
    mode: widget.mode,
    clockOverrides: widget.clockOverrides,
    factories: widget.clockFactories,
  );

  void _attachController(StagePlayerController? c) {
    if (c == null) return;
    c
      .._animator = _animator
      .._nodes = _registry
      .._scroll = _scroll;
  }

  void _detachController(StagePlayerController? c) {
    if (c == null || !identical(c._animator, _animator)) return;
    c
      .._animator = null
      .._nodes = null
      .._scroll = null;
  }

  @override
  void didUpdateWidget(StagePlayer old) {
    super.didUpdateWidget(old);
    final envChanged =
        !identical(old.environment, widget.environment) ||
        old.mode != widget.mode ||
        (widget.environment == null &&
            !identical(old.document, widget.document));
    if (envChanged) _env = _environmentFor(widget);
    if (old.mode != widget.mode ||
        !identical(old.clockFactories, widget.clockFactories)) {
      _detachController(old.controller);
      _animator.dispose();
      _animator = _newAnimator();
      _resolved = null; // reload into the new animator
      _attachController(widget.controller);
    } else {
      _animator.clockOverrides = widget.clockOverrides;
      if (!identical(old.controller, widget.controller)) {
        _detachController(old.controller);
        _attachController(widget.controller);
      }
    }
    if (envChanged || !identical(old.document, widget.document)) {
      _resolved = null;
    }
  }

  @override
  void dispose() {
    _detachController(widget.controller);
    _animator.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Resolves for [width]'s breakpoint when the document or breakpoint
  /// changed, and (re)loads the animator. Returns whether it re-resolved.
  bool _ensureResolved(double width) {
    final doc = widget.document;
    final bp = ir.breakpointForWidth(doc, width);
    if (_resolved != null &&
        identical(_resolvedDoc, doc) &&
        _resolvedBreakpoint == bp?.id) {
      return false;
    }
    final resolved = _resolver.resolve(
      doc,
      ir.ResolveContext(breakpointId: bp?.id),
    );
    _resolved = resolved;
    _resolvedDoc = doc;
    _resolvedBreakpoint = bp?.id;
    _sceneAssets = {for (final s in resolved.scenes) s.id: sceneAssetIds(s)};
    _animator.load(resolved);
    return true;
  }

  List<Widget> _buildSlivers(ir.ResolvedDocument resolved, Size viewport) {
    return [
      for (final scene in resolved.scenes)
        SliverStageScene(
          key: _sceneKeys.putIfAbsent(scene.id, GlobalKey.new),
          kind: scene.kind,
          scrollLength: scene.scrollLength,
          estimatedExtent: scene.root.node.common.height,
          windowViewports: widget.lazyWindow,
          content: (scene, viewport, resolved.breakpoint),
          onLayout: (progress, {required visible}) => _animator.sceneScrolled(
            scene.id,
            progress: progress,
            visible: visible,
          ),
          builder: (context, inWindow) {
            _sceneWindowChanged(scene.id, inWindow, viewport.width);
            if (!inWindow) return const SizedBox.shrink();
            return StageSceneView(
              key: ValueKey<String>(scene.id),
              scene: scene,
              viewportSize: viewport,
              breakpoint: resolved.breakpoint,
            );
          },
        ),
    ];
  }

  /// Prefetches a scene's images as it enters the lazy window and releases
  /// those no other windowed scene uses as it leaves (§17.1).
  void _sceneWindowChanged(String sceneId, bool inWindow, double width) {
    final media = _env.media;
    if (inWindow) {
      if (!_windowScenes.add(sceneId) || media == null) return;
      final dpr = stageDevicePixelRatio();
      for (final id in _sceneAssets[sceneId] ?? const <String>{}) {
        media.prefetch(id, targetWidth: width * dpr);
      }
      return;
    }
    if (!_windowScenes.remove(sceneId) || media == null) return;
    final keep = {for (final s in _windowScenes) ...?_sceneAssets[s]};
    for (final id in _sceneAssets[sceneId] ?? const <String>{}) {
      if (!keep.contains(id)) media.releaseAsset(id);
    }
  }

  void _maybeJumpToInitialScene() {
    final id = widget.initialSceneId;
    if (_jumped || id == null) return;
    _jumped = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final ro = _sceneKeys[id]?.currentContext?.findRenderObject();
      if (ro is RenderSliver) {
        _scroll.jumpTo(ro.constraints.precedingScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = widget.viewportOverride ?? constraints.biggest;
        final resolvedAgain = _ensureResolved(viewport.width);
        final resolved = _resolved!;
        if (resolvedAgain || _sliverViewport != viewport) {
          _sliverViewport = viewport;
          _slivers = _buildSlivers(resolved, viewport);
        }
        _maybeJumpToInitialScene();
        return StageScope(
          environment: _env,
          child: MouseRegion(
            opaque: false,
            onExit: (_) => _animator.pointerExited(),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerHover: (e) => _animator.pointerMoved(e.position),
              onPointerMove: (e) {
                if (e.kind == PointerDeviceKind.mouse) {
                  _animator.pointerMoved(e.position);
                }
              },
              child: SizedBox.fromSize(
                size: viewport,
                child: CustomScrollView(
                  controller: _scroll,
                  physics: widget.physics,
                  scrollCacheExtent: ScrollCacheExtent.viewport(
                    widget.lazyWindow,
                  ),
                  slivers: _slivers,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Asset ids a resolved scene paints with (image fills and strokes, and
/// the scene background).
Set<String> sceneAssetIds(ir.ResolvedScene scene) {
  final out = <String>{};
  void paints(List<ir.Paint> ps) {
    for (final p in ps) {
      if (p is ir.ImagePaint) out.add(p.assetId);
    }
  }

  void visit(ir.ResolvedNode n) {
    switch (n.node) {
      case ir.FrameNode(:final appearance) ||
          ir.ShapeNode(:final appearance) ||
          ir.VideoNode(:final appearance):
        paints(appearance.fills);
        paints(appearance.strokes.paints);
      case ir.TextNode(:final appearance):
        paints(appearance.strokes.paints);
      default:
        break;
    }
    for (final c in n.children) {
      visit(c);
    }
  }

  paints(scene.background);
  visit(scene.root);
  return out;
}
