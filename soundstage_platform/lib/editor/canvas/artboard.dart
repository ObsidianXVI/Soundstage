import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/editor/core/editor_controller.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'canvas_controller.dart';

/// One artboard: the active scene rendered by `StageSceneView` in edit mode
/// for [breakpoint] (a primary breakpoint), frozen at the playhead.
///
/// - Width: the breakpoint's `designSize.width`, or the free width
///   ([CanvasController.previewWidths]). At a free width the scene is
///   resolved for the breakpoint that width falls in (`breakpointForWidth`),
///   as the player would.
/// - Height: a pinned scene shows at the viewport size (the design height);
///   a flow scene shows its full content height, so the artboard grows.
/// - Clocks: a `StageAnimator` in edit mode holds every clock of the scene
///   at its playhead (`EditorState.playheads`; 0 without one), so every
///   track of the scene shows its value at that time; nothing ticks and
///   nothing is smoothed.
/// - **Scrubbing** (m2.md "Playheads", §17.1): a playhead change is not
///   watched by [build]. A listener hands the scene's playheads to the
///   animator, which writes the changed tracks' values into the render
///   objects directly: no widget rebuild and no document resolve per step.
///   The overlay is told the geometry changed, so selection bounds and
///   handles follow animated geometry.
/// - Edits re-resolve and reload the animator, which recompiles only the
///   tracks the edit touched (`StageAnimator.load`).
/// - The artboard is a repaint boundary with its own node registry, which
///   the overlay reads ([ArtboardInfo]).
class Artboard extends ConsumerStatefulWidget {
  const Artboard({
    required this.breakpoint,
    required this.controller,
    required this.environment,
    super.key,
  });

  final ir.Breakpoint breakpoint;
  final CanvasController controller;

  /// The document's edit-mode environment (fonts, media), shared by the
  /// artboards; each adds its own node registry.
  final StageEnvironment environment;

  /// Test counter: artboard builds (pan and zoom must not add any).
  static int debugBuildCount = 0;

  @override
  ConsumerState<Artboard> createState() => _ArtboardState();
}

class _ArtboardState extends ConsumerState<Artboard>
    with TickerProviderStateMixin {
  late ArtboardInfo _info;
  late final StageAnimator _animator;
  ir.ResolvedDocument? _loaded;
  StageEnvironment? _baseEnv;
  late StageEnvironment _env;
  String? _sceneId;

  @override
  void initState() {
    super.initState();
    _register();
    _animator = StageAnimator(
      registry: _info.registry,
      vsync: this,
      mode: StageRenderMode.edit,
    );
    widget.controller.previewWidths.addListener(_widthsChanged);
    widget.controller.playheadLive.addListener(_liveChanged);
    ref.listenManual(
      editorControllerProvider.select((s) => Identity(s.playheads)),
      (_, _) => _pushPlayheads(),
    );
  }

  /// Whether this artboard follows the playhead now: always, except while
  /// it moves continuously ([CanvasController.playheadLive]) and another
  /// artboard is the edited one (DECISIONS 26/10/26 T2.1-5: rasterising
  /// every artboard per scrub step dominated the frame).
  bool get _followsPlayhead =>
      !widget.controller.playheadLive.value ||
      ref.read(editorControllerProvider).artboardId == widget.breakpoint.id;

  /// Hands the shown scene's playheads to the animator (writes render
  /// objects directly) and tells the overlay the geometry may have moved.
  void _pushPlayheads() {
    if (!_followsPlayhead) return;
    final values = ref.read(editorControllerProvider).clockValuesOf(_sceneId);
    if (identical(values, _animator.clockOverrides)) return;
    _animator.clockOverrides = values;
    widget.controller.notifyGeometry();
  }

  /// The scrub or playback stopped: catch up with the playhead.
  void _liveChanged() {
    if (!widget.controller.playheadLive.value) _pushPlayheads();
  }

  /// Each artboard registers its own info (and node registry). When one
  /// surface replaces another in the same frame (the full editor narrowing
  /// to content mode), the new artboard mounts before the old one is
  /// disposed; sharing the old entry let the old artboard's dispose remove
  /// the new one's, which left content-mode taps with no geometry (B3).
  void _register() {
    final id = widget.breakpoint.id;
    final previous = widget.controller.artboards[id];
    _info = ArtboardInfo(id);
    if (previous != null) _info.worldRect = previous.worldRect;
    widget.controller.artboards[id] = _info;
  }

  double? _width;

  void _widthsChanged() {
    final w = widget.controller.previewWidthOf(widget.breakpoint.id);
    if (w != _width) setState(() {});
  }

  @override
  void didUpdateWidget(Artboard old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.previewWidths.removeListener(_widthsChanged);
      widget.controller.previewWidths.addListener(_widthsChanged);
      old.controller.playheadLive.removeListener(_liveChanged);
      widget.controller.playheadLive.addListener(_liveChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.previewWidths.removeListener(_widthsChanged);
    widget.controller.playheadLive.removeListener(_liveChanged);
    if (identical(widget.controller.artboards[_info.breakpointId], _info)) {
      widget.controller.artboards.remove(_info.breakpointId);
    }
    _animator.dispose();
    super.dispose();
  }

  StageEnvironment _environment() {
    if (!identical(_baseEnv, widget.environment)) {
      _baseEnv = widget.environment;
      _env = widget.environment.copyWith(
        mode: StageRenderMode.edit,
        nodes: _info.registry,
      );
    }
    return _env;
  }

  @override
  Widget build(BuildContext context) {
    assert(() {
      Artboard.debugBuildCount++;
      return true;
    }());
    final bp = widget.breakpoint;
    final doc = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    final sceneId = ref.watch(
      editorControllerProvider.select((s) => s.activeSceneId),
    );
    _width = widget.controller.previewWidthOf(bp.id);
    final width = _width ?? bp.designSize.width;
    final effective = _width == null
        ? bp
        : (ir.breakpointForWidth(doc, width) ?? bp);
    final art = ref.watch(resolvedForProvider(effective.id));
    final scene = art.scene(sceneId);

    _info
      ..effectiveBreakpointId = effective.id
      ..scene = scene
      ..name = bp.name
      ..designSize = Size(bp.designSize.width, bp.designSize.height);

    _sceneId = sceneId;
    // Playheads first, so the reload evaluates new tracks at them (a
    // non-edited artboard keeps its values while the playhead is live).
    if (_followsPlayhead) {
      _animator.clockOverrides = ref
          .read(editorControllerProvider)
          .clockValuesOf(sceneId);
    }
    if (!identical(_loaded, art.resolved)) {
      _loaded = art.resolved;
      _animator.load(art.resolved);
    }

    final viewport = Size(width, bp.designSize.height);
    return RepaintBoundary(
      child: StageScope(
        environment: _environment(),
        child: SizedBox(
          width: width,
          child: scene == null
              ? SizedBox(height: viewport.height)
              : StageSceneView(
                  key: ValueKey<String>(scene.id),
                  scene: scene,
                  viewportSize: viewport,
                  breakpoint: effective,
                  extraRepaintBoundaryIds: editRepaintBoundaries(scene.root),
                ),
        ),
      ),
    );
  }
}

/// Frames with at least this many descendants are repaint boundaries on
/// the artboards.
const int kEditRepaintBoundaryMin = 16;

final Expando<int> _descendants = Expando('descendants');

int _countDescendants(ir.ResolvedNode n) {
  final cached = _descendants[n];
  if (cached != null) return cached;
  var c = 0;
  for (final k in n.children) {
    c += 1 + _countDescendants(k);
  }
  _descendants[n] = c;
  return c;
}

/// The frames of [root]'s tree (not the root, already a boundary) with at
/// least [kEditRepaintBoundaryMin] descendants.
///
/// In the editor a drag or an edit marks its node's ancestors for paint;
/// without boundaries below the scene root, every node of the scene would
/// re-record its picture each frame (9,990 paints per move on the 5,000-node
/// bench). With large subtrees isolated, an edit re-records the ancestor
/// path and the small subtrees beside it. Counts are memoised per resolved
/// node, and untouched subtrees keep their identity across edits, so this
/// costs the edited path only.
Set<String> editRepaintBoundaries(ir.ResolvedNode root) {
  final out = <String>{};
  void walk(ir.ResolvedNode n) {
    for (final k in n.children) {
      if (_countDescendants(k) >= kEditRepaintBoundaryMin) {
        out.add(k.id);
        walk(k);
      }
    }
  }

  walk(root);
  return out;
}
