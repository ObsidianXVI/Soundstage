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
///   at the controller's playhead (0 in M1), so tracks show their values
///   at that time; nothing ticks.
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
  Map<String, double> _overrides = const {};
  ir.ResolvedScene? _overridesScene;
  double _overridesAt = 0;

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
  }

  void _register() {
    _info = widget.controller.artboards[widget.breakpoint.id] ??= ArtboardInfo(
      widget.breakpoint.id,
    );
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
    }
  }

  @override
  void dispose() {
    widget.controller.previewWidths.removeListener(_widthsChanged);
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
    final playhead = ref.watch(
      editorControllerProvider.select((s) => s.playheads[sceneId] ?? 0.0),
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

    if (!identical(_loaded, art.resolved)) {
      _loaded = art.resolved;
      _animator.load(art.resolved);
    }
    if (!identical(_overridesScene, scene) || _overridesAt != playhead) {
      _overridesScene = scene;
      _overridesAt = playhead;
      _overrides = {
        for (final c in scene?.clocks ?? const <ir.Clock>[]) c.id: playhead,
      };
      _animator.clockOverrides = _overrides;
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
                ),
        ),
      ),
    );
  }
}
