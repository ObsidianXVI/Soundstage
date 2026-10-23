import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/rendering.dart' show Matrix4;
import 'package:freezed_annotation/freezed_annotation.dart';

part 'camera.freezed.dart';

/// Smallest zoom: 2%.
const double kMinZoom = 0.02;

/// Largest zoom: 6400%.
const double kMaxZoom = 64;

/// [zoom] clamped to [kMinZoom]..[kMaxZoom].
double clampZoom(double zoom) => zoom.clamp(kMinZoom, kMaxZoom).toDouble();

/// The canvas camera: a uniform scale and a translation, mapping world
/// coordinates (design pixels; artboards sit side by side at y = 0) to the
/// canvas viewport's local coordinates (logical screen pixels):
///
/// `screen = world × zoom + (panX, panY)`.
///
/// Pure value maths; the editor's camera notifier holds the current one
/// (`CanvasController.camera`), never `EditorState`.
@freezed
abstract class CanvasCamera with _$CanvasCamera {
  const factory CanvasCamera({
    @Default(1) double zoom,
    @Default(0) double panX,
    @Default(0) double panY,
  }) = _CanvasCamera;

  const CanvasCamera._();

  Offset get pan => Offset(panX, panY);

  /// The world → screen transform (for `TransformLayer`s and overlay
  /// geometry).
  Matrix4 get matrix => Matrix4.identity()
    ..setEntry(0, 0, zoom)
    ..setEntry(1, 1, zoom)
    ..setEntry(0, 3, panX)
    ..setEntry(1, 3, panY);

  Offset toScreen(Offset world) =>
      Offset(world.dx * zoom + panX, world.dy * zoom + panY);

  Offset toWorld(Offset screen) =>
      Offset((screen.dx - panX) / zoom, (screen.dy - panY) / zoom);

  Rect rectToScreen(Rect world) =>
      Rect.fromPoints(toScreen(world.topLeft), toScreen(world.bottomRight));

  Rect rectToWorld(Rect screen) =>
      Rect.fromPoints(toWorld(screen.topLeft), toWorld(screen.bottomRight));

  /// The camera moved by [screenDelta] screen pixels.
  CanvasCamera panned(Offset screenDelta) =>
      copyWith(panX: panX + screenDelta.dx, panY: panY + screenDelta.dy);

  /// The camera zoomed to [newZoom] (clamped) keeping the world point under
  /// [focal] (a screen point) fixed.
  CanvasCamera zoomedAbout(Offset focal, double newZoom) {
    final z = clampZoom(newZoom);
    final world = toWorld(focal);
    return CanvasCamera(
      zoom: z,
      panX: focal.dx - world.dx * z,
      panY: focal.dy - world.dy * z,
    );
  }

  /// The camera zoomed by [factor] about [focal] (see [zoomedAbout]).
  CanvasCamera scaledAbout(Offset focal, double factor) =>
      zoomedAbout(focal, zoom * factor);

  /// The camera that centres [world] in [viewport] at the largest zoom that
  /// fits it inside [padding] screen pixels on every side, clamped to
  /// [maxZoom] (and to [kMinZoom]..[kMaxZoom]).
  ///
  /// An empty [world] rect keeps its centre and uses [maxZoom].
  static CanvasCamera framing(
    Rect world,
    Size viewport, {
    double padding = 48,
    double maxZoom = kMaxZoom,
  }) {
    final availW = math.max(1.0, viewport.width - padding * 2);
    final availH = math.max(1.0, viewport.height - padding * 2);
    var z = maxZoom;
    if (world.width > 0) z = math.min(z, availW / world.width);
    if (world.height > 0) z = math.min(z, availH / world.height);
    z = clampZoom(z);
    final c = world.center;
    return CanvasCamera(
      zoom: z,
      panX: viewport.width / 2 - c.dx * z,
      panY: viewport.height / 2 - c.dy * z,
    );
  }

  /// Linear interpolation for animated zooms: the zoom interpolates in log
  /// space, and the pan so that the world point at the viewport's [focal]
  /// moves on a straight line (no swing while zooming).
  static CanvasCamera lerp(
    CanvasCamera a,
    CanvasCamera b,
    double t, {
    required Offset focal,
  }) {
    if (t <= 0) return a;
    if (t >= 1) return b;
    final z = math.exp(
      math.log(a.zoom) + (math.log(b.zoom) - math.log(a.zoom)) * t,
    );
    final wa = a.toWorld(focal);
    final wb = b.toWorld(focal);
    final w = Offset.lerp(wa, wb, t)!;
    return CanvasCamera(
      zoom: z,
      panX: focal.dx - w.dx * z,
      panY: focal.dy - w.dy * z,
    );
  }
}
