import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/editor/core/editor_controller.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../overlay/interaction_model.dart';
import '../overlay/overlay_geometry.dart';
import 'camera.dart';

/// Gap between side-by-side artboards, in world (design) pixels.
const double kArtboardGap = 120;

/// Range of a free-width artboard, in design pixels.
const double kMinPreviewWidth = 240;
const double kMaxPreviewWidth = 3840;

/// Keyboard zoom step (Cmd+= / Cmd+-).
const double kZoomStep = 2;

/// Duration of animated (keyboard) zooms.
const Duration kZoomAnimation = Duration(milliseconds: 200);

/// The breakpoints that get an artboard: the primary ones in document order
/// (desktop and mobile by default), else the first breakpoint.
List<ir.Breakpoint> artboardBreakpoints(ir.StageDocument doc) {
  final primary = doc.primaryBreakpoints.toList();
  if (primary.isNotEmpty) return primary;
  return doc.breakpoints.isEmpty ? const [] : [doc.breakpoints.first];
}

/// The world x of each artboard of [widths], laid out left to right with
/// [gap] between them, the first at 0. All artboards sit at y = 0 (tops
/// aligned).
List<double> artboardOffsets(List<double> widths, {double gap = kArtboardGap}) {
  final out = <double>[];
  var x = 0.0;
  for (final w in widths) {
    out.add(x);
    x += w + gap;
  }
  return out;
}

/// What an artboard shows, registered by the artboard widget and read by
/// the overlay ([OverlayGeometry]).
class ArtboardInfo {
  ArtboardInfo(this.breakpointId);

  /// The artboard's (primary) breakpoint. Overlay queries and hits name
  /// artboards by this id.
  final String breakpointId;

  /// The artboard's `nodeId → RenderStageBox` registry (edit mode).
  final StageNodeRegistry registry = StageNodeRegistry();

  /// The breakpoint in effect: [breakpointId] at its design width, else
  /// the breakpoint the free width falls in (`breakpointForWidth`).
  String effectiveBreakpointId = '';

  /// The scene on the artboard, resolved for [effectiveBreakpointId].
  ir.ResolvedScene? scene;

  /// Display name and design size of [breakpointId].
  String name = '';
  Size designSize = Size.zero;

  /// The artboard's box in world coordinates (after layout).
  Rect worldRect = Rect.zero;
}

/// The editor canvas's own state (one per editor): the camera, the
/// free-width preview widths and the artboards' live geometry. UI state, so
/// it lives here and not in `EditorState`.
///
/// - [camera] changes on pan and zoom. The canvas applies it as a layer
///   transform (no rebuild, no relayout, no repaint of the artboards).
/// - [previewWidths] holds an artboard's free width while it differs from
///   its breakpoint's `designSize` (T1.5 reads it to convert edits back
///   through inverse constraints).
/// - [geometry] fires after the artboards lay out; painters listen to it
///   (only painters: it fires during layout).
class CanvasController {
  CanvasController();

  final ValueNotifier<CanvasCamera> camera = ValueNotifier(
    const CanvasCamera(),
  );

  /// Artboard breakpoint id → free width (design pixels).
  final ValueNotifier<Map<String, double>> previewWidths = ValueNotifier(
    const {},
  );

  /// Fires when the artboards' layout changed (sizes, positions) or what
  /// they show; for painters only.
  Listenable get geometry => _geometry;
  final _Signal _geometry = _Signal();

  /// The artboards by breakpoint id, in canvas order.
  final Map<String, ArtboardInfo> artboards = {};

  /// The canvas viewport's size (screen pixels), set at layout.
  Size viewportSize = Size.zero;

  /// The render box whose coordinates are world coordinates (the artboard
  /// canvas); the camera maps them to the viewport.
  RenderBox? worldBox;

  /// Whether the initial zoom-to-fit happened.
  bool framed = false;

  AnimationController? _anim;
  CanvasCamera? _from, _to;
  Offset _focal = Offset.zero;

  /// Geometry queries for the overlay and for T1.4/T1.5.
  late final OverlayGeometry overlay = OverlayGeometry(this);

  /// The canvas tools' transient overlay state (marquee, guides, ...).
  final InteractionModel interaction = InteractionModel();

  /// Called by the artboard canvas after layout.
  void notifyGeometry() => _geometry.fire();

  // ---- Free width ---------------------------------------------------------

  /// The free width of the artboard of [breakpointId], or null at its
  /// design width.
  double? previewWidthOf(String breakpointId) =>
      previewWidths.value[breakpointId];

  /// Sets the artboard's free width (clamped); [designWidth] or null resets.
  void setPreviewWidth(
    String breakpointId,
    double? width, {
    double? designWidth,
  }) {
    final next = Map.of(previewWidths.value);
    if (width == null) {
      next.remove(breakpointId);
    } else {
      final w = width.clamp(kMinPreviewWidth, kMaxPreviewWidth).toDouble();
      if (designWidth != null && (w - designWidth).abs() < 0.5) {
        next.remove(breakpointId);
      } else {
        next[breakpointId] = w;
      }
    }
    if (!mapEquals(next, previewWidths.value)) previewWidths.value = next;
  }

  void resetPreviewWidth(String breakpointId) =>
      setPreviewWidth(breakpointId, null);

  // ---- Camera -------------------------------------------------------------

  /// The union of the artboards' world rects, or null before layout.
  Rect? get contentBounds {
    Rect? r;
    for (final a in artboards.values) {
      if (a.worldRect.isEmpty) continue;
      r = r == null ? a.worldRect : r.expandToInclude(a.worldRect);
    }
    return r;
  }

  /// The world rect visible in the viewport.
  Rect get visibleWorldRect =>
      camera.value.rectToWorld(Offset.zero & viewportSize);

  void _stopAnimation() {
    _anim?.stop();
    _from = _to = null;
  }

  /// Sets the camera at once (pan, pinch, wheel), cancelling any animation.
  void setCamera(CanvasCamera c) {
    _stopAnimation();
    camera.value = c;
  }

  void panBy(Offset screenDelta) => setCamera(camera.value.panned(screenDelta));

  void zoomAbout(Offset focal, double factor) =>
      setCamera(camera.value.scaledAbout(focal, factor));

  /// Moves to [target], animated when the canvas attached a ticker (keyboard
  /// zoom), else at once.
  void animateTo(CanvasCamera target, {bool animate = true}) {
    final a = _anim;
    if (!animate || a == null) {
      setCamera(target);
      return;
    }
    _from = camera.value;
    _to = target;
    _focal = viewportSize.center(Offset.zero);
    a.forward(from: 0);
  }

  Offset get _center => viewportSize.center(Offset.zero);

  void zoomIn({bool animate = true}) => animateTo(
    (_to ?? camera.value).scaledAbout(_center, kZoomStep),
    animate: animate,
  );

  void zoomOut({bool animate = true}) => animateTo(
    (_to ?? camera.value).scaledAbout(_center, 1 / kZoomStep),
    animate: animate,
  );

  /// 100% about the viewport centre.
  void zoomTo100({bool animate = true}) =>
      animateTo(camera.value.zoomedAbout(_center, 1), animate: animate);

  /// Frames [world] (design pixels) in the viewport.
  void zoomToRect(Rect world, {bool animate = true, double? maxZoom}) {
    if (viewportSize.isEmpty) return;
    animateTo(
      CanvasCamera.framing(world, viewportSize, maxZoom: maxZoom ?? kMaxZoom),
      animate: animate,
    );
  }

  /// Frames every artboard. Returns false before the artboards laid out.
  bool zoomToFit({bool animate = true, double? maxZoom}) {
    final b = contentBounds;
    if (b == null || viewportSize.isEmpty) return false;
    zoomToRect(b, animate: animate, maxZoom: maxZoom);
    return true;
  }

  /// Frames the nodes [ids] on the artboard of [breakpointId] (default: the
  /// first artboard that shows them). Returns false when none is on screen.
  bool zoomToNodes(
    Iterable<String> ids, {
    String? breakpointId,
    bool animate = true,
  }) {
    final order = [
      if (breakpointId != null && artboards.containsKey(breakpointId))
        breakpointId,
      ...artboards.keys.where((k) => k != breakpointId),
    ];
    for (final bp in order) {
      Rect? r;
      for (final id in ids) {
        final w = overlay.worldRectFor(id, bp);
        if (w == null) continue;
        r = r == null ? w : r.expandToInclude(w);
      }
      if (r != null) {
        zoomToRect(r, animate: animate);
        return true;
      }
    }
    return false;
  }

  /// Animation for keyboard zoom; the canvas attaches its ticker.
  void attachTicker(TickerProvider vsync) {
    _anim?.dispose();
    _anim = AnimationController(vsync: vsync, duration: kZoomAnimation)
      ..addListener(() {
        final from = _from, to = _to;
        if (from == null || to == null) return;
        final t = Curves.easeOutCubic.transform(_anim!.value);
        camera.value = CanvasCamera.lerp(from, to, t, focal: _focal);
        if (_anim!.isCompleted) _from = _to = null;
      });
  }

  void detachTicker() {
    _anim?.dispose();
    _anim = null;
    final to = _to;
    _from = _to = null;
    if (to != null && !_disposed) camera.value = to;
  }

  /// The zoom as a whole percentage, for the toolbar.
  static String zoomLabel(double zoom) {
    final p = zoom * 100;
    return p < 10 ? '${p.toStringAsFixed(1)}%' : '${p.round()}%';
  }

  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _anim?.dispose();
    _anim = null;
    camera.dispose();
    previewWidths.dispose();
    interaction.dispose();
    _geometry.dispose();
  }
}

class _Signal extends ChangeNotifier {
  void fire() => notifyListeners();
}

/// The canvas state of the editor in scope (one per editor: it is scoped
/// with `initialDocumentProvider`, so each opened story gets its own).
final canvasControllerProvider = Provider<CanvasController>((ref) {
  ref.watch(initialDocumentProvider);
  final c = CanvasController();
  ref.onDispose(c.dispose);
  return c;
}, dependencies: [initialDocumentProvider]);
