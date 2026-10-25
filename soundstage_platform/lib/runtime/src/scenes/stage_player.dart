import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../animator/node_registry.dart';
import '../animator/stage_animator.dart';
import '../clocks/clock_source.dart';
import '../clocks/timeline_clock.dart';
import '../interactions/open_url.dart';
import '../interactions/stage_interactions.dart';
import '../media/audio.dart';
import '../media/image_cache.dart';
import '../render/render_stage_box.dart';
import '../render/render_stage_frame.dart' show stageDevicePixelRatio;
import '../render/stage_environment.dart';
import '../widgets/stage_behaviors.dart' show showStageLightbox;
import '../widgets/stage_node_widget.dart';
import '../widgets/stage_scene_view.dart';
import 'scroll_anchor.dart';
import 'sliver_stage_scene.dart';
import 'wheel_smoothing.dart';

/// Talks to a mounted [StagePlayer]: timeline controls, clock values, and
/// the node registry (the editor overlay's `NodeGeometryRegistry`).
class StagePlayerController {
  StageAnimator? _animator;
  StageNodeRegistry? _nodes;
  ScrollController? _scroll;
  FocusNode? _focusNode;
  void Function(String sceneId, {bool animate})? _scrollToScene;

  /// Scrolls to the start of scene [sceneId] (no-op when it is unknown or
  /// no player is attached).
  void scrollToScene(String sceneId, {bool animate = true}) =>
      _scrollToScene?.call(sceneId, animate: animate);

  /// Gives the story keyboard focus (PageDown, Space and the arrows scroll
  /// it). Call it when something that held focus, like the enter gate, is
  /// gone; a pointer press on the story does it too.
  void requestFocus() => _focusNode?.requestFocus();

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
/// - [audio] plays the document's audio tracks: its clock sources back
///   `audio` clocks (unless [clockFactories] sets its own), seeks re-read
///   clocks at once, and scene visibility drives scene-scoped tracks.
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
    this.audio,
    this.controller,
    this.lazyWindow = 1,
    this.physics,
    this.wheelSmoothing,
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

  /// The document's audio (T0.7); null = silent, `audio` clocks hold 0.
  final StageAudioService? audio;
  final StagePlayerController? controller;

  /// Viewports around the visible range whose scenes keep a render tree.
  final double lazyWindow;
  final ScrollPhysics? physics;

  /// Opt-in smoothing of discrete mouse-wheel notches (null = the
  /// browser's native wheel behaviour). Trackpad, touch and keyboard
  /// scrolling always stay native. See [StageWheelSmoothing].
  final StageWheelSmoothing? wheelSmoothing;

  @override
  State<StagePlayer> createState() => _StagePlayerState();
}

class _StagePlayerState extends State<StagePlayer>
    with TickerProviderStateMixin {
  final ir.Resolver _resolver = ir.Resolver();

  /// Keyboard scrolling (PageDown, Space, arrows, Home/End) needs a focused
  /// widget under the scroll view: `ScrollAction` looks up the scrollable
  /// from the primary focus. Without this node nothing has focus once the
  /// enter gate is gone, and the keys do nothing.
  final FocusNode _focus = FocusNode(debugLabel: 'StagePlayer');
  final StageNodeRegistry _registry = StageNodeRegistry();
  late final StageScrollController _scroll = StageScrollController(
    smoothing: widget.wheelSmoothing,
  );
  late StageAnimator _animator;
  late StageEnvironment _env;

  /// Decoded images, kept across environment rebuilds (a changed document
  /// keeps the other images decoded).
  final StageImageCache _images = StageImageCache();

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

  /// Scene ids in order, as of the last resolve.
  List<String> _sceneIds = const [];
  SceneScrollAnchor? _anchor;

  /// `MediaQuery.disableAnimations`: the platform's reduced-motion setting
  /// (`prefers-reduced-motion` on the web).
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    _env = _environmentFor(widget);
    _animator = _newAnimator();
    _attachController(widget.controller);
    widget.audio?.addClockListener(_audioChanged);
  }

  void _audioChanged() => _animator.notifyClockChanged();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduced == _reducedMotion) return;
    _reducedMotion = reduced;
    _animator.reducedMotion = reduced;
    _scroll.smoothing = reduced ? null : widget.wheelSmoothing;
  }

  StageClockFactories get _factories {
    final f = widget.clockFactories;
    final audio = widget.audio;
    if (audio == null || f.audio != null) return f;
    return StageClockFactories(audio: audio.clockSource, behavior: f.behavior);
  }

  StageEnvironment _environmentFor(StagePlayer w) =>
      (w.environment ??
              StageEnvironment.forDocument(
                w.document,
                mode: w.mode,
                imageCache: _images,
              ))
          .copyWith(mode: w.mode, nodes: _registry);

  StageAnimator _newAnimator() =>
      StageAnimator(
          registry: _registry,
          vsync: this,
          mode: widget.mode,
          clockOverrides: widget.clockOverrides,
          factories: _factories,
        )
        ..reducedMotion = _reducedMotion
        ..onClockValue = _onClockValue;

  // ---- Interactions (§10.3) -----------------------------------------------------

  late final StageInteractions _interactions = StageInteractions(
    StageInteractionHost(
      playTimeline: (id) => _animator.playTimeline(id),
      pauseTimeline: (id) => _animator.pauseTimeline(id),
      reverseTimeline: (id) => _animator.reverseTimeline(id),
      seekTimeline: (id, s) => _animator.seekTimeline(id, s),
      playAudio: (id) => widget.audio?.play(id),
      pauseAudio: (id) => widget.audio?.pause(id),
      seekAudio: (id, s) => widget.audio?.seek(id, s),
      setVariable: (id, v) {
        if (_variables[id] == v || !mounted) return;
        setState(() => _variables = {..._variables, id: v});
      },
      scrollToScene: (id) => _scrollToSceneStart(id),
      openUrl: (url, {required newTab}) => openStageUrl(url, newTab: newTab),
      openLightbox: _openLightbox,
    ),
  );

  /// Variable values set by interactions (they override token values when
  /// resolving, §8).
  Map<String, ir.IrValue> _variables = const {};
  Map<String, ir.IrValue>? _resolvedVariables;

  bool get _interactive => widget.mode == StageRenderMode.play;

  void _onClockValue(String clockId, double value) {
    if (_interactive) _interactions.clock(clockId, value);
  }

  void _openLightbox(String nodeId) {
    final n = _resolved?.nodeIndex[nodeId];
    if (n == null || !mounted) return;
    final c = n.node.common;
    showStageLightbox(
      context,
      index: 0,
      count: 1,
      sizes: [Size(c.width, c.height)],
      buildMember: (_) => stageNodeAlone(_env, n),
    );
  }

  /// The stage nodes under [global], innermost first.
  List<String> _nodesAt(Offset global) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      result,
      global,
      View.of(context).viewId,
    );
    return [
      for (final e in result.path)
        if (e.target case final RenderStageBox b) b.nodeId,
    ];
  }

  Offset? _downAt;

  Widget _withPointerTriggers(Widget child) {
    if (!_interactive) return child;
    return MouseRegion(
      opaque: false,
      onExit: (_) => _interactions.hover(const []),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => _downAt = e.position,
        onPointerUp: (e) {
          final d = _downAt;
          _downAt = null;
          if (d == null || (e.position - d).distance > kTouchSlop) return;
          if (_interactions.hasTapTriggers) {
            _interactions.tap(_nodesAt(e.position));
          }
        },
        onPointerHover: (e) {
          if (_interactions.hasHoverTriggers) {
            _interactions.hover(_nodesAt(e.position));
          }
        },
        child: child,
      ),
    );
  }

  void _attachController(StagePlayerController? c) {
    if (c == null) return;
    c
      .._animator = _animator
      .._nodes = _registry
      .._scroll = _scroll
      .._focusNode = _focus
      .._scrollToScene = _scrollToSceneStart;
  }

  void _detachController(StagePlayerController? c) {
    if (c == null || !identical(c._animator, _animator)) return;
    c
      .._animator = null
      .._nodes = null
      .._scroll = null
      .._focusNode = null
      .._scrollToScene = null;
  }

  @override
  void didUpdateWidget(StagePlayer old) {
    super.didUpdateWidget(old);
    _scroll.smoothing = _reducedMotion ? null : widget.wheelSmoothing;
    final envChanged =
        !identical(old.environment, widget.environment) ||
        old.mode != widget.mode ||
        (widget.environment == null &&
            !identical(old.document, widget.document));
    if (envChanged) _env = _environmentFor(widget);
    if (!identical(old.audio, widget.audio)) {
      old.audio?.removeClockListener(_audioChanged);
      widget.audio?.addClockListener(_audioChanged);
    }
    if (old.mode != widget.mode ||
        !identical(old.audio, widget.audio) ||
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
    widget.audio?.removeClockListener(_audioChanged);
    _detachController(widget.controller);
    _animator.dispose();
    _scroll.dispose();
    _focus.dispose();
    _images.clear();
    super.dispose();
  }

  /// Resolves for [width]'s breakpoint when the document or breakpoint
  /// changed, and (re)loads the animator. Returns whether it re-resolved.
  bool _ensureResolved(double width) {
    final doc = widget.document;
    final bp = ir.breakpointForWidth(doc, width);
    if (_resolved != null &&
        identical(_resolvedDoc, doc) &&
        _resolvedBreakpoint == bp?.id &&
        identical(_resolvedVariables, _variables)) {
      return false;
    }
    // Scenes may get longer or shorter: remember where the reader is, as a
    // scene and a progress, and put it back once the new layout exists.
    if (_sceneIds.isNotEmpty) _anchor = _captureAnchor();
    final resolved = _resolver.resolve(
      doc,
      ir.ResolveContext(breakpointId: bp?.id, variableState: _variables),
    );
    _resolved = resolved;
    _resolvedVariables = _variables;
    if (_interactive) _interactions.load(resolved);
    _resolvedDoc = doc;
    _resolvedBreakpoint = bp?.id;
    _sceneAssets = {for (final s in resolved.scenes) s.id: sceneAssetIds(s)};
    _sceneIds = [for (final s in resolved.scenes) s.id];
    _animator.load(resolved);
    return true;
  }

  List<Widget> _buildSlivers(ir.ResolvedDocument resolved, Size viewport) {
    final scenes = resolved.scenes;
    return [
      for (final (i, scene) in scenes.indexed)
        SliverStageScene(
          key: _sceneKeys.putIfAbsent(scene.id, GlobalKey.new),
          kind: scene.kind,
          scrollLength: scene.scrollLength,
          transitionIn: i == 0
              ? const ir.SceneTransition()
              : scene.transitionIn,
          overlapNext:
              i + 1 < scenes.length &&
                  scenes[i + 1].transitionIn.kind != ir.SceneTransitionKind.none
              ? scenes[i + 1].transitionIn.amount
              : 0,
          estimatedExtent: scene.root.node.common.height,
          windowViewports: widget.lazyWindow,
          content: (scene, viewport, resolved.breakpoint),
          onLayout: (progress, {required visible}) {
            _animator.sceneScrolled(
              scene.id,
              progress: progress,
              visible: visible,
            );
            if (widget.mode == StageRenderMode.play) {
              widget.audio?.sceneVisibilityChanged(scene.id, visible: visible);
              _interactions.sceneVisible(scene.id, visible: visible);
            }
          },
          builder: (context, inWindow) {
            _sceneWindowChanged(scene.id, inWindow, viewport.width);
            if (!inWindow) {
              // Keeps the scene's landmark while its stage is not built.
              return widget.mode == StageRenderMode.edit
                  ? const SizedBox.shrink()
                  : stageSceneLandmark(
                      scene.name,
                      child: const SizedBox.shrink(),
                    );
            }
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

  // ---- Keyboard (T2.7) ----------------------------------------------------------

  /// Scroll offsets where each scene starts, in order.
  List<double> _sceneStarts() {
    final resolved = _resolved;
    if (resolved == null) return const [];
    return [
      for (final scene in resolved.scenes)
        if (_sceneKeys[scene.id]?.currentContext?.findRenderObject()
            case final RenderSliver sliver when sliver.attached)
          sliver.constraints.precedingScrollExtent,
    ];
  }

  /// `(ids, starts, end)` of the laid-out scenes, or null when a scene has
  /// no render object yet.
  (List<String>, List<double>, double)? _sceneLayout() {
    if (!_scroll.hasClients || _sceneIds.isEmpty) return null;
    final starts = <double>[];
    for (final id in _sceneIds) {
      final ro = _sceneKeys[id]?.currentContext?.findRenderObject();
      if (ro is! RenderSliver || !ro.attached) return null;
      starts.add(ro.constraints.precedingScrollExtent);
    }
    final p = _scroll.position;
    return (_sceneIds, starts, p.maxScrollExtent + p.viewportDimension);
  }

  SceneScrollAnchor? _captureAnchor() {
    final layout = _sceneLayout();
    if (layout == null) return null;
    return captureSceneAnchor(
      ids: layout.$1,
      starts: layout.$2,
      offset: _scroll.position.pixels,
      end: layout.$3,
    );
  }

  /// After the first layout of a new resolve: back to the remembered
  /// scene and progress.
  void _restoreAnchor() {
    final anchor = _anchor;
    if (anchor == null) return;
    _anchor = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final layout = _sceneLayout();
      if (layout == null) return;
      final target = restoreSceneAnchor(
        anchor,
        ids: layout.$1,
        starts: layout.$2,
        end: layout.$3,
      );
      if (target == null) return;
      final p = _scroll.position;
      final clamped = target.clamp(p.minScrollExtent, p.maxScrollExtent);
      if ((clamped - p.pixels).abs() > 0.5) _scroll.jumpTo(clamped);
    });
  }

  void _scrollToSceneStart(String sceneId, {bool animate = true}) {
    final layout = _sceneLayout();
    if (layout == null) return;
    final i = layout.$1.indexOf(sceneId);
    if (i < 0) return;
    final p = _scroll.position;
    final target = layout.$2[i].clamp(p.minScrollExtent, p.maxScrollExtent);
    if (animate && !_reducedMotion) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_scroll.hasClients) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    final keys = HardwareKeyboard.instance;
    // Browser and OS shortcuts (history, zoom, tab switching) stay theirs.
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final shift = keys.isShiftPressed;
    final int direction;
    final bool toEdge;
    if (k == LogicalKeyboardKey.pageDown ||
        k == LogicalKeyboardKey.arrowDown ||
        (k == LogicalKeyboardKey.space && !shift)) {
      direction = 1;
      toEdge = false;
    } else if (k == LogicalKeyboardKey.pageUp ||
        k == LogicalKeyboardKey.arrowUp ||
        (k == LogicalKeyboardKey.space && shift)) {
      direction = -1;
      toEdge = false;
    } else if (k == LogicalKeyboardKey.home) {
      direction = -1;
      toEdge = true;
    } else if (k == LogicalKeyboardKey.end) {
      direction = 1;
      toEdge = true;
    } else {
      return KeyEventResult.ignored;
    }
    if (shift && k != LogicalKeyboardKey.space) return KeyEventResult.ignored;
    final p = _scroll.position;
    final target = toEdge
        ? (direction < 0 ? p.minScrollExtent : p.maxScrollExtent)
        : keyboardScrollTarget(
            offset: p.pixels,
            viewport: p.viewportDimension,
            min: p.minScrollExtent,
            max: p.maxScrollExtent,
            sceneStarts: _sceneStarts(),
            direction: direction,
          );
    if (target == p.pixels) return KeyEventResult.handled;
    if (_reducedMotion) {
      _scroll.jumpTo(target);
    } else {
      final viewports = (target - p.pixels).abs() / p.viewportDimension;
      _scroll.animateTo(
        target,
        duration: Duration(
          milliseconds: (260 + 120 * math.sqrt(viewports)).round().clamp(
            260,
            700,
          ),
        ),
        curve: Curves.easeInOutCubic,
      );
    }
    return KeyEventResult.handled;
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
          if (!resolvedAgain && _sliverViewport != null) {
            _anchor = _captureAnchor();
          }
          _sliverViewport = viewport;
          _slivers = _buildSlivers(resolved, viewport);
        }
        _maybeJumpToInitialScene();
        _restoreAnchor();
        return StageScope(
          environment: _env,
          child: MouseRegion(
            opaque: false,
            onExit: (_) => _animator.pointerExited(),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) {
                if (!_focus.hasFocus) _focus.requestFocus();
              },
              onPointerHover: (e) => _animator.pointerMoved(e.position),
              onPointerMove: (e) {
                if (e.kind == PointerDeviceKind.mouse) {
                  _animator.pointerMoved(e.position);
                }
              },
              child: SizedBox.fromSize(
                size: viewport,
                child: PrimaryScrollController(
                  controller: _scroll,
                  child: Focus(
                    focusNode: _focus,
                    autofocus: true,
                    onKeyEvent: _onKey,
                    // A text direction up the semantics tree makes the
                    // scenes (siblings in the scroll view) read in order.
                    child: Semantics(
                      container: true,
                      textDirection: TextDirection.ltr,
                      child: _withPointerTriggers(
                        CustomScrollView(
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

/// Document font family ids a resolved scene's text uses (the enter gate
/// waits for them).
Set<String> sceneFontFamilyIds(ir.ResolvedScene scene) {
  final out = <String>{};
  void visit(ir.ResolvedNode n) {
    for (final p in n.paragraphs ?? const <ir.ResolvedParagraph>[]) {
      for (final s in p.spans) {
        final id = s.style.fontFamilyId;
        if (id != null) out.add(id);
      }
    }
    final b = n.node;
    if (b is ir.FrameNode) {
      final behavior = b.behavior;
      if (behavior is ir.LyricsBehavior) {
        for (final o in [behavior.activeStyle, behavior.inactiveStyle]) {
          final id = o.fontFamilyId;
          if (id != null) out.add(id);
        }
      }
    }
    for (final c in n.children) {
      visit(c);
    }
  }

  visit(scene.root);
  return out;
}

/// Where a keyboard move from [offset] ends: a viewport on in [direction]
/// (1 down, -1 up), but never past a scene start it would cross, so every
/// scene start is reachable by keyboard and a long scene is crossed one
/// viewport at a time. Clamped to [min]…[max].
double keyboardScrollTarget({
  required double offset,
  required double viewport,
  required double min,
  required double max,
  required List<double> sceneStarts,
  required int direction,
}) {
  const eps = 0.5;
  if (direction > 0) {
    final raw = offset + viewport;
    var target = raw;
    for (final s in sceneStarts) {
      if (s > offset + eps && s <= raw && s < target) target = s;
    }
    return target.clamp(min, max);
  }
  final raw = offset - viewport;
  var target = raw;
  for (final s in sceneStarts) {
    if (s < offset - eps && s >= raw && s > target) target = s;
  }
  return target.clamp(min, max);
}
