import 'dart:math' as math;
import 'dart:ui';

import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'corner_smoothing.dart';

/// The shape a node's appearance paints into, in the node's local
/// coordinates: a (rounded, optionally smoothed) rectangle for frames,
/// rectangles and videos, or a path for other shapes. Open outlines (lines)
/// only take strokes.
class StageOutline {
  /// A box of [size] with [radius] corners and Figma corner [smoothing]
  /// (0–1). Radii are clamped as Figma does.
  factory StageOutline.box(
    Size size,
    ir.CornerRadius radius, {
    double smoothing = 0,
  }) {
    final (tl, tr, br, bl) = switch (radius) {
      ir.UniformCornerRadius(:final radius) => (radius, radius, radius, radius),
      ir.CornerRadii(:final tl, :final tr, :final br, :final bl) => (
        tl,
        tr,
        br,
        bl,
      ),
    };
    return StageOutline.boxRadii(
      Offset.zero & size,
      [tl, tr, br, bl].map(Radius.circular).toList(),
      smoothing: smoothing,
    );
  }

  /// A box with explicit (possibly elliptical) corner radii in the order
  /// top-left, top-right, bottom-right, bottom-left. Radii are clamped:
  /// to half the shorter side without smoothing, and by Figma's budget
  /// distribution with it.
  factory StageOutline.boxRadii(
    Rect bounds,
    List<Radius> radii, {
    double smoothing = 0,
  }) {
    assert(radii.length == 4);
    final s = smoothing.clamp(0.0, 1.0);
    final anyRound = radii.any((r) => r.x > 0 && r.y > 0);
    if (s <= 0 || !anyRound) {
      final limit = math.max(0.0, math.min(bounds.width, bounds.height) / 2);
      Radius c(Radius r) =>
          Radius.elliptical(r.x.clamp(0.0, limit), r.y.clamp(0.0, limit));
      final rr = RRect.fromRectAndCorners(
        bounds,
        topLeft: c(radii[0]),
        topRight: c(radii[1]),
        bottomRight: c(radii[2]),
        bottomLeft: c(radii[3]),
      );
      return StageOutline._(
        bounds: bounds,
        rrect: rr,
        path: null,
        radii: [rr.tlRadius, rr.trRadius, rr.brRadius, rr.blRadius],
        smoothing: 0,
      );
    }
    // Smoothed corners are circular (the smaller of the two radii).
    double m(Radius r) => math.min(r.x, r.y);
    final d = distributeCorners(
      tl: m(radii[0]),
      tr: m(radii[1]),
      br: m(radii[2]),
      bl: m(radii[3]),
      width: bounds.width,
      height: bounds.height,
    );
    return StageOutline._(
      bounds: bounds,
      rrect: null,
      path: smoothedRectPathRadii(
        bounds,
        d.radii[0],
        d.radii[1],
        d.radii[2],
        d.radii[3],
        s,
      ),
      radii: [for (final r in d.radii) Radius.circular(r)],
      smoothing: s,
    );
  }

  /// An arbitrary [path] inside [bounds].
  StageOutline.path(this._path, {required this.bounds, this.closed = true})
    : rrect = null,
      radii = null,
      smoothing = 0;

  StageOutline._({
    required this.bounds,
    required this.rrect,
    required this.radii,
    required this.smoothing,
    required Path? path,
  }) : _path = path, // ignore: prefer_initializing_formals
       closed = true;

  final Rect bounds;

  /// Set for unsmoothed box outlines.
  final RRect? rrect;
  final Path? _path;

  /// False for open outlines (lines), which have no inside.
  final bool closed;

  /// Corner radii (tl, tr, br, bl) of box outlines; null for path outlines.
  final List<Radius>? radii;

  /// The corner smoothing in effect (0 for plain rounded rectangles).
  final double smoothing;

  /// Whether this is a (rounded) rectangle, plain or smoothed.
  bool get isBox => radii != null;

  Path get path => _path ?? (Path()..addRRect(rrect!));

  /// This box grown by [delta] on every side (negative = shrunk); corner
  /// radii grow by the same amount (never below 0). Null for path outlines.
  StageOutline? inflated(double delta) =>
      insetBy(left: -delta, top: -delta, right: -delta, bottom: -delta);

  /// This box with each side moved inwards by the given amounts (negative =
  /// outwards). A corner's radius shrinks by the adjacent insets, so
  /// offsets keep concentric corners. Null for path outlines.
  StageOutline? insetBy({
    double left = 0,
    double top = 0,
    double right = 0,
    double bottom = 0,
  }) {
    final rs = radii;
    if (rs == null) return null;
    final b = Rect.fromLTRB(
      bounds.left + left,
      bounds.top + top,
      math.max(bounds.left + left, bounds.right - right),
      math.max(bounds.top + top, bounds.bottom - bottom),
    );
    Radius r(Radius o, double dx, double dy) =>
        Radius.elliptical(math.max(0, o.x - dx), math.max(0, o.y - dy));
    return StageOutline.boxRadii(b, [
      r(rs[0], left, top),
      r(rs[1], right, top),
      r(rs[2], right, bottom),
      r(rs[3], left, bottom),
    ], smoothing: smoothing);
  }

  /// Clips [canvas] to the outline (no layer: a canvas clip).
  void clip(Canvas canvas) {
    final r = rrect;
    if (r != null) {
      if (r.isRect) {
        canvas.clipRect(r.outerRect);
      } else {
        canvas.clipRRect(r);
      }
    } else {
      canvas.clipPath(path);
    }
  }

  /// Fills the outline with [paint].
  void fill(Canvas canvas, Paint paint) {
    final r = rrect;
    if (r == null) {
      canvas.drawPath(path, paint);
    } else if (r.isRect) {
      canvas.drawRect(r.outerRect, paint);
    } else {
      canvas.drawRRect(r, paint);
    }
  }
}

/// [rect] with [radius] corners. Each radius is clamped to half the shorter
/// side, as in Figma.
RRect stageRRect(Rect rect, ir.CornerRadius radius) =>
    StageOutline.box(rect.size, radius).rrect!.shift(rect.topLeft);

/// Everything inside [outer] except [hole], as one even-odd path (a clip or
/// fill region). Used instead of `Path.combine`, whose boolean operations
/// are not reliable across CanvasKit and the VM.
Path complementPath(Rect outer, Path hole) => Path()
  ..fillType = PathFillType.evenOdd
  ..addRect(outer)
  ..addPath(hole, Offset.zero);
