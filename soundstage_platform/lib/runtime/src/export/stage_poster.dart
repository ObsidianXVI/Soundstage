import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../animator/node_registry.dart';
import '../animator/stage_animator.dart';
import '../render/stage_environment.dart';
import '../scenes/stage_player.dart' show sceneAssetIds, sceneFontFamilyIds;
import '../widgets/stage_node_widget.dart' show StageScope;
import '../widgets/stage_scene_view.dart';

/// A scene, or one node of it, rasterised by the real renderer (architecture
/// §16.1 poster frames, m4.md T4.5b) off screen: nothing is mounted in the
/// app. The scene's scroll clock is held at [clock] (default: the scene's
/// poster clock), behaviours render as authored, and fonts and images are
/// loaded first. Returns PNG bytes, or null if the scene or node is not
/// there.
///
/// [breakpointId]: the layout to render (default: primary, else widest).
/// [nodeId]: crop to that node's box (a figure without an image file).
Future<Uint8List?> renderStagePoster(
  ir.StageDocument doc,
  StageEnvironment environment, {
  required String sceneId,
  double? clock,
  String? nodeId,
  String? breakpointId,
  double pixelRatio = 1,
}) async {
  final bp = _breakpoint(doc, breakpointId);
  if (bp == null) return null;
  final resolved = ir.resolveDocument(
    doc,
    ir.ResolveContext(breakpointId: bp.id),
  );
  ir.ResolvedScene? scene;
  for (final s in resolved.scenes) {
    if (s.id == sceneId) scene = s;
  }
  if (scene == null) return null;
  final source = doc.scenes.where((s) => s.id == sceneId).firstOrNull;
  final at = clock ?? source?.effectivePosterClock ?? ir.kDefaultPosterClock;

  // Fonts and images first, so the one frame we take is complete.
  await Future.wait([
    environment.fonts.ensureLoaded(sceneFontFamilyIds(scene)),
    if (environment.media case final media?)
      for (final id in sceneAssetIds(scene)) media.ready(id),
  ]);

  final registry = StageNodeRegistry();
  final animator = StageAnimator(
    registry: registry,
    vsync: const _NoVsync(),
    mode: StageRenderMode.edit,
    clockOverrides: {
      for (final c in scene.clocks)
        if (c is ir.SceneScrollClock) c.id: at,
    },
  );
  final env = environment.copyWith(mode: StageRenderMode.edit, nodes: registry);
  final size = Size(bp.designSize.width, bp.designSize.height);
  try {
    final image = await renderWidgetOffscreen(
      MediaQuery(
        data: MediaQueryData(size: size, devicePixelRatio: pixelRatio),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: StageScope(
            environment: env,
            child: SizedBox.fromSize(
              size: size,
              child: StageSceneView(
                scene: scene,
                viewportSize: size,
                breakpoint: bp,
              ),
            ),
          ),
        ),
      ),
      size: size,
      pixelRatio: pixelRatio,
      beforeCapture: () => animator.load(resolved),
      crop: nodeId == null ? null : (root) => _boxOf(registry, nodeId, root),
    );
    if (image == null) return null;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return png?.buffer.asUint8List();
  } finally {
    animator.dispose();
  }
}

ir.Breakpoint? _breakpoint(ir.StageDocument doc, String? id) {
  if (doc.breakpoints.isEmpty) return null;
  for (final b in doc.breakpoints) {
    if (b.id == id) return b;
  }
  for (final b in doc.breakpoints) {
    if (b.primary) return b;
  }
  return doc.breakpoints.reduce(
    (a, b) => a.designSize.width >= b.designSize.width ? a : b,
  );
}

/// [nodeId]'s box in the rendered scene's coordinates, or null.
Rect? _boxOf(StageNodeRegistry registry, String nodeId, RenderBox root) {
  final box = registry.boxOf(nodeId);
  if (box == null || !box.attached || !box.hasSize) return null;
  final topLeft = box.localToGlobal(Offset.zero, ancestor: root);
  return topLeft & box.size;
}

class _NoVsync implements TickerProvider {
  const _NoVsync();

  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

/// Builds, lays out and paints [widget] in a detached pipeline of [size]
/// logical pixels and returns the picture, or only the part [crop] gives
/// (in the coordinates of the captured root), or null when it gives none.
///
/// [beforeCapture] runs after the first layout (render objects exist), for
/// writes that need them (the animator applying tracks). Images that finish
/// decoding during the passes are picked up: the tree is pumped a few times
/// with short pauses before the capture.
Future<ui.Image?> renderWidgetOffscreen(
  Widget widget, {
  required Size size,
  double pixelRatio = 1,
  VoidCallback? beforeCapture,
  Rect? Function(RenderBox root)? crop,
  int passes = 3,
}) async {
  final boundary = RenderRepaintBoundary();
  final view =
      WidgetsBinding.instance.platformDispatcher.implicitView ??
      WidgetsBinding.instance.platformDispatcher.views.first;
  final renderView = RenderView(
    view: view,
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size * pixelRatio),
      devicePixelRatio: pixelRatio,
    ),
    child: RenderPositionedBox(child: boundary),
  );
  final pipeline = PipelineOwner()..rootNode = renderView;
  renderView.prepareInitialFrame();
  final focus = FocusManager();
  final build = BuildOwner(focusManager: focus);
  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: widget,
  ).attachToRenderTree(build);

  void pump() {
    build
      ..buildScope(root)
      ..finalizeTree();
    pipeline
      ..flushLayout()
      ..flushCompositingBits()
      ..flushPaint();
  }

  try {
    pump();
    beforeCapture?.call();
    for (var i = 0; i < passes; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 16));
      pump();
    }
    final full = await boundary.toImage(pixelRatio: pixelRatio);
    final rect = crop?.call(boundary);
    if (crop == null) return full;
    if (rect == null || rect.isEmpty) {
      full.dispose();
      return null;
    }
    final recorder = ui.PictureRecorder();
    final px = Rect.fromLTWH(
      rect.left * pixelRatio,
      rect.top * pixelRatio,
      rect.width * pixelRatio,
      rect.height * pixelRatio,
    );
    ui.Canvas(
      recorder,
    ).drawImageRect(full, px, Offset.zero & px.size, ui.Paint());
    final cropped = await recorder.endRecording().toImage(
      px.width.ceil(),
      px.height.ceil(),
    );
    full.dispose();
    return cropped;
  } finally {
    // Unmount: element tree, then render tree.
    RenderObjectToWidgetAdapter<RenderBox>(
      container: boundary,
    ).attachToRenderTree(build, root);
    build.finalizeTree();
    focus.dispose();
    pipeline.rootNode = null;
    renderView.dispose();
  }
}
