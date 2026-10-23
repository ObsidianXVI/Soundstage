import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

// Snapping and smart spacing for the canvas transform tools (T1.5), in world
// space (design pixels, artboards side by side). A [SnapIndex] is built once
// per gesture from the candidate boxes; each pointer move then costs a few
// binary searches plus one pass over the moving box's neighbours.

/// Snap distance in screen pixels; divide by the zoom for world units.
const double kSnapThresholdPx = 5;

/// Zoom from which moves and resizes snap to the pixel grid.
const double kPixelGridZoom = 4;

/// A guide line (world space), optionally with a distance [label] drawn at
/// its middle. [dashed] lines extend a measurement to the target's edge.
class Guide {
  const Guide(this.a, this.b, {this.label, this.dashed = false});

  final Offset a, b;
  final double? label;
  final bool dashed;

  @override
  String toString() => 'Guide($a → $b, $label${dashed ? ', dashed' : ''})';
}

/// An equal-spacing marker (Figma's pink gap): the gap's area between two
/// boxes (world space) and whether it is a horizontal gap (boxes side by
/// side).
class GapMarker {
  const GapMarker(this.area, {required this.horizontal});

  final Rect area;
  final bool horizontal;

  double get value => horizontal ? area.width : area.height;

  @override
  String toString() => 'GapMarker($area, ${horizontal ? 'h' : 'v'})';
}

/// What snapping did to a moving box: the correction to add to it, and
/// the guides and gap markers to draw.
class SnapResult {
  const SnapResult(
    this.offset, {
    this.guides = const [],
    this.gaps = const [],
    this.snappedX = false,
    this.snappedY = false,
  });

  static const SnapResult none = SnapResult(Offset.zero);

  final Offset offset;
  final List<Guide> guides;
  final List<GapMarker> gaps;
  final bool snappedX, snappedY;
}

/// Which edges of a box move (a resize drags only some of them).
class MovingEdges {
  const MovingEdges({
    this.left = false,
    this.right = false,
    this.top = false,
    this.bottom = false,
  });

  /// A move: every edge and both centres.
  static const MovingEdges all = MovingEdges(
    left: true,
    right: true,
    top: true,
    bottom: true,
  );

  final bool left, right, top, bottom;

  bool get isMove => left && right && top && bottom;
}

/// One axis of the index: candidate values, sorted, with the box each came
/// from.
class _Axis {
  _Axis(List<(double, int)> entries) {
    entries.sort((a, b) => a.$1.compareTo(b.$1));
    values = Float64List.fromList([for (final e in entries) e.$1]);
    sources = Int32List.fromList([for (final e in entries) e.$2]);
  }

  late final Float64List values;
  late final Int32List sources;

  int _lowerBound(double v) {
    var lo = 0, hi = values.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (values[mid] < v) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The nearest candidate to [v] within [threshold] (signed distance
  /// candidate − v), or null.
  double? nearest(double v, double threshold) {
    if (values.isEmpty) return null;
    final i = _lowerBound(v);
    double? best;
    for (final j in [i - 1, i]) {
      if (j < 0 || j >= values.length) continue;
      final d = values[j] - v;
      if (d.abs() <= threshold && (best == null || d.abs() < best.abs())) {
        best = d;
      }
    }
    return best;
  }

  /// Sources of candidates equal to [v] (within [eps]).
  Iterable<int> sourcesAt(double v, {double eps = 0.01}) sync* {
    var i = _lowerBound(v - eps);
    while (i < values.length && values[i] <= v + eps) {
      yield sources[i];
      i++;
    }
  }
}

/// A precomputed pair of neighbours with the gap between them.
typedef _Pair = ({int a, int b, double gap});

/// Snapping candidates for one gesture (precomputed; m1.md, §18).
///
/// - Alignment: the left/centre/right (top/middle/bottom) of every sibling
///   box, of the parent and of the artboard.
/// - Smart spacing: the gaps between neighbouring siblings (side by side
///   with overlapping spans, nothing in between), so a moving box can take
///   an existing gap next to a neighbour, or sit centred between two.
///
/// Boxes are world-space axis-aligned bounds.
class SnapIndex {
  SnapIndex({required List<Rect> siblings, Rect? parent, Rect? artboard})
    : boxes = [...siblings, ?parent, ?artboard],
      _siblingCount = siblings.length {
    final xs = <(double, int)>[], ys = <(double, int)>[];
    for (final (i, r) in boxes.indexed) {
      xs
        ..add((r.left, i))
        ..add((r.center.dx, i))
        ..add((r.right, i));
      ys
        ..add((r.top, i))
        ..add((r.center.dy, i))
        ..add((r.bottom, i));
    }
    _x = _Axis(xs);
    _y = _Axis(ys);
    _hPairs = _pairs(horizontal: true);
    _vPairs = _pairs(horizontal: false);
  }

  /// Every candidate box: siblings, then the parent, then the artboard.
  final List<Rect> boxes;
  final int _siblingCount;
  late final _Axis _x, _y;
  late final List<_Pair> _hPairs, _vPairs;

  /// Maximum neighbours scanned per box when pairing (keeps building the
  /// index linear-ish on large flat frames).
  static const int _pairScan = 64;

  List<Rect> get siblings => boxes.sublist(0, _siblingCount);

  static bool _overlap(double a0, double a1, double b0, double b1) =>
      a0 < b1 && b0 < a1;

  List<_Pair> _pairs({required bool horizontal}) {
    final n = _siblingCount;
    final order = List<int>.generate(n, (i) => i)
      ..sort(
        (a, b) => horizontal
            ? boxes[a].left.compareTo(boxes[b].left)
            : boxes[a].top.compareTo(boxes[b].top),
      );
    final out = <_Pair>[];
    for (var k = 0; k < n; k++) {
      final a = boxes[order[k]];
      final aEnd = horizontal ? a.right : a.bottom;
      var scanned = 0;
      for (var m = k + 1; m < n && scanned < _pairScan; m++) {
        final b = boxes[order[m]];
        final bStart = horizontal ? b.left : b.top;
        if (bStart < aEnd) continue;
        scanned++;
        final crosses = horizontal
            ? _overlap(a.top, a.bottom, b.top, b.bottom)
            : _overlap(a.left, a.right, b.left, b.right);
        if (!crosses) continue;
        out.add((a: order[k], b: order[m], gap: bStart - aEnd));
        break; // the nearest neighbour on that side
      }
    }
    return out;
  }

  /// Snaps a box that moves (all of [edges]) or resizes (some of them).
  ///
  /// [threshold] is in world units (`kSnapThresholdPx / zoom`). With
  /// [pixelGrid], an axis that did not snap moves its edges onto whole
  /// pixels (zoom ≥ 400%).
  SnapResult snap(
    Rect moving,
    double threshold, {
    MovingEdges edges = MovingEdges.all,
    bool pixelGrid = false,
  }) {
    final xq = [
      if (edges.left) moving.left,
      if (edges.isMove) moving.center.dx,
      if (edges.right) moving.right,
    ];
    final yq = [
      if (edges.top) moving.top,
      if (edges.isMove) moving.center.dy,
      if (edges.bottom) moving.bottom,
    ];
    double? best(_Axis axis, List<double> qs) {
      double? out;
      for (final q in qs) {
        final d = axis.nearest(q, threshold);
        if (d != null && (out == null || d.abs() < out.abs())) out = d;
      }
      return out;
    }

    final ax = best(_x, xq), ay = best(_y, yq);
    var dx = ax, dy = ay;
    // Smart spacing competes with alignment: the nearer wins, and when
    // both land on the same place both are drawn.
    _Spacing? hs, vs;
    if (edges.isMove) {
      hs = _spacing(moving, threshold, horizontal: true);
      vs = _spacing(moving, threshold, horizontal: false);
      if (hs != null && (dx == null || hs.delta.abs() < dx.abs() - 1e-9)) {
        dx = hs.delta;
      }
      if (vs != null && (dy == null || vs.delta.abs() < dy.abs() - 1e-9)) {
        dy = vs.delta;
      }
      if (hs != null && (hs.delta - dx!).abs() > 1e-9) hs = null;
      if (vs != null && (vs.delta - dy!).abs() > 1e-9) vs = null;
    }
    final alignX = ax != null && (ax - dx!).abs() <= 1e-9;
    final alignY = ay != null && (ay - dy!).abs() <= 1e-9;
    final snappedX = dx != null, snappedY = dy != null;
    if (pixelGrid) {
      dx ??= _gridDelta(
        edges.left || !edges.right ? moving.left : moving.right,
      );
      dy ??= _gridDelta(
        edges.top || !edges.bottom ? moving.top : moving.bottom,
      );
    }
    final offset = Offset(dx ?? 0, dy ?? 0);
    final r = moving.shift(offset);
    final guides = <Guide>[];
    final gaps = <GapMarker>[];
    // Alignment: a line per aligned value, and one distance label per axis
    // on the gap to the nearest aligned box.
    void align(List<double> qs, _Axis axis, {required bool vertical}) {
      _Gap? best;
      for (final q in qs) {
        final g = _alignGuide(r, q, axis.sourcesAt(q), vertical: vertical);
        if (g == null) continue;
        guides.add(g.$1);
        final gap = g.$2;
        if (gap != null && (best == null || gap.size < best.size)) best = gap;
      }
      if (best != null) {
        guides.add(
          vertical
              ? Guide(
                  Offset(best.q, best.from),
                  Offset(best.q, best.to),
                  label: best.size,
                )
              : Guide(
                  Offset(best.from, best.q),
                  Offset(best.to, best.q),
                  label: best.size,
                ),
        );
      }
    }

    if (alignX) {
      align(
        [
          if (edges.left) r.left,
          if (edges.isMove) r.center.dx,
          if (edges.right) r.right,
        ],
        _x,
        vertical: true,
      );
    }
    if (alignY) {
      align(
        [
          if (edges.top) r.top,
          if (edges.isMove) r.center.dy,
          if (edges.bottom) r.bottom,
        ],
        _y,
        vertical: false,
      );
    }
    if (hs != null) gaps.addAll(_markers(r, hs, horizontal: true));
    if (vs != null) gaps.addAll(_markers(r, vs, horizontal: false));
    return SnapResult(
      offset,
      guides: guides,
      gaps: gaps,
      snappedX: snappedX,
      snappedY: snappedY,
    );
  }

  static double _gridDelta(double v) => v.roundToDouble() - v;

  /// A red alignment guide through [q] spanning [r] and the aligned boxes
  /// (unlabelled), and the gap from [r] to the nearest aligned box along
  /// it, or null when no box is aligned there.
  (Guide, _Gap?)? _alignGuide(
    Rect r,
    double q,
    Iterable<int> sources, {
    required bool vertical,
  }) {
    var lo = vertical ? r.top : r.left;
    var hi = vertical ? r.bottom : r.right;
    final r0 = vertical ? r.top : r.left, r1 = vertical ? r.bottom : r.right;
    _Gap? nearest;
    var any = false;
    for (final i in sources) {
      any = true;
      final s = boxes[i];
      final s0 = vertical ? s.top : s.left, s1 = vertical ? s.bottom : s.right;
      lo = math.min(lo, s0);
      hi = math.max(hi, s1);
      final gap = s0 >= r1
          ? _Gap(q, r1, s0)
          : (r0 >= s1 ? _Gap(q, s1, r0) : null);
      if (gap != null && (nearest == null || gap.size < nearest.size)) {
        nearest = gap;
      }
    }
    if (!any) return null;
    return (
      vertical
          ? Guide(Offset(q, lo), Offset(q, hi))
          : Guide(Offset(lo, q), Offset(hi, q)),
      nearest,
    );
  }

  /// The best equal-spacing position for [m] on one axis, or null.
  _Spacing? _spacing(Rect m, double threshold, {required bool horizontal}) {
    // Nearest siblings before and after [m] whose cross spans overlap it.
    int? before, after;
    double s(Rect r) => horizontal ? r.left : r.top;
    double e(Rect r) => horizontal ? r.right : r.bottom;
    bool crosses(Rect r) => horizontal
        ? _overlap(r.top, r.bottom, m.top, m.bottom)
        : _overlap(r.left, r.right, m.left, m.right);
    for (var i = 0; i < _siblingCount; i++) {
      final r = boxes[i];
      if (!crosses(r)) continue;
      if (e(r) <= s(m) + threshold) {
        if (before == null || e(r) > e(boxes[before])) before = i;
      } else if (s(r) >= e(m) - threshold) {
        if (after == null || s(r) < s(boxes[after])) after = i;
      }
    }
    if (before == null && after == null) return null;
    final pairs = horizontal ? _hPairs : _vPairs;
    final size = e(m) - s(m);
    _Spacing? best;
    void consider(double target, double gap, _Side side) {
      final d = target - s(m);
      if (d.abs() > threshold) return;
      if (best == null || d.abs() < best!.delta.abs()) {
        best = _Spacing(d, gap, side, before, after);
      }
    }

    // Centred between both neighbours wins ties (it shows both gaps).
    if (before != null && after != null) {
      final free = s(boxes[after]) - e(boxes[before]) - size;
      if (free > 0) {
        consider(e(boxes[before]) + free / 2, free / 2, _Side.between);
      }
    }
    if (before != null) {
      for (final p in pairs) {
        if (p.gap <= 0) continue;
        consider(e(boxes[before]) + p.gap, p.gap, _Side.before);
      }
    }
    if (after != null) {
      for (final p in pairs) {
        if (p.gap <= 0) continue;
        consider(s(boxes[after]) - p.gap - size, p.gap, _Side.after);
      }
    }
    return best;
  }

  /// Gap markers for a smart-spacing snap: the moving box's gap(s) and every
  /// sibling pair with the same gap.
  List<GapMarker> _markers(Rect r, _Spacing sp, {required bool horizontal}) {
    final out = <GapMarker>[];
    Rect between(Rect a, Rect b) {
      if (horizontal) {
        final top = math.max(a.top, b.top),
            bottom = math.min(a.bottom, b.bottom);
        return Rect.fromLTRB(a.right, top, b.left, bottom);
      }
      final left = math.max(a.left, b.left), right = math.min(a.right, b.right);
      return Rect.fromLTRB(left, a.bottom, right, b.top);
    }

    if (sp.side != _Side.after && sp.before != null) {
      out.add(GapMarker(between(boxes[sp.before!], r), horizontal: horizontal));
    }
    if (sp.side != _Side.before && sp.after != null) {
      out.add(GapMarker(between(r, boxes[sp.after!]), horizontal: horizontal));
    }
    if (sp.side == _Side.between) return out;
    for (final p in horizontal ? _hPairs : _vPairs) {
      if ((p.gap - sp.gap).abs() > 0.01) continue;
      // Only pairs in the moving box's row (column), as Figma shows them:
      // the gap itself must share the box's band.
      final area = between(boxes[p.a], boxes[p.b]);
      final inBand = horizontal
          ? _overlap(area.top, area.bottom, r.top, r.bottom)
          : _overlap(area.left, area.right, r.left, r.right);
      if (!inBand) continue;
      out.add(
        GapMarker(between(boxes[p.a], boxes[p.b]), horizontal: horizontal),
      );
      if (out.length > 16) break;
    }
    return out;
  }
}

enum _Side { before, after, between }

/// A gap along an alignment guide at [q], from [from] to [to].
class _Gap {
  _Gap(this.q, this.from, this.to);

  final double q, from, to;
  double get size => to - from;
}

class _Spacing {
  _Spacing(this.delta, this.gap, this.side, this.before, this.after);

  final double delta, gap;
  final _Side side;
  final int? before, after;
}

/// Figma's Alt measurement between the selection [a] and another box [b]
/// (world space): red lines with distances.
///
/// - One box inside the other (a parent, an overlapping container): the
///   four distances from the inner box's edges to the outer box's.
/// - Apart: the horizontal and/or vertical distance between the facing
///   edges, drawn from the selection's centre line, with a dashed extension
///   to [b] when the line misses it.
/// - Overlapping without containment: the edge-to-edge distances on the
///   sides where they differ.
List<Guide> measureBetween(Rect a, Rect b) {
  final out = <Guide>[];
  bool contains(Rect outer, Rect inner) =>
      outer.left <= inner.left &&
      outer.top <= inner.top &&
      outer.right >= inner.right &&
      outer.bottom >= inner.bottom;
  void inside(Rect inner, Rect outer) {
    final cy = inner.center.dy, cx = inner.center.dx;
    if (inner.left > outer.left) {
      out.add(
        Guide(
          Offset(outer.left, cy),
          Offset(inner.left, cy),
          label: inner.left - outer.left,
        ),
      );
    }
    if (outer.right > inner.right) {
      out.add(
        Guide(
          Offset(inner.right, cy),
          Offset(outer.right, cy),
          label: outer.right - inner.right,
        ),
      );
    }
    if (inner.top > outer.top) {
      out.add(
        Guide(
          Offset(cx, outer.top),
          Offset(cx, inner.top),
          label: inner.top - outer.top,
        ),
      );
    }
    if (outer.bottom > inner.bottom) {
      out.add(
        Guide(
          Offset(cx, inner.bottom),
          Offset(cx, outer.bottom),
          label: outer.bottom - inner.bottom,
        ),
      );
    }
  }

  if (contains(b, a)) {
    inside(a, b);
    return out;
  }
  if (contains(a, b)) {
    inside(b, a);
    return out;
  }
  final apartX = b.left >= a.right || a.left >= b.right;
  final apartY = b.top >= a.bottom || a.top >= b.bottom;
  if (!apartX && !apartY) {
    // Overlapping: distances between corresponding edges.
    final cy = a.center.dy, cx = a.center.dx;
    void edge(double from, double to, {required bool horizontal}) {
      if ((from - to).abs() < 1e-9) return;
      out.add(
        horizontal
            ? Guide(Offset(from, cy), Offset(to, cy), label: (to - from).abs())
            : Guide(Offset(cx, from), Offset(cx, to), label: (to - from).abs()),
      );
    }

    edge(a.left, b.left, horizontal: true);
    edge(a.right, b.right, horizontal: true);
    edge(a.top, b.top, horizontal: false);
    edge(a.bottom, b.bottom, horizontal: false);
    return out;
  }
  if (apartX) {
    final y = math.max(a.top, b.top) < math.min(a.bottom, b.bottom)
        ? (math.max(a.top, b.top) + math.min(a.bottom, b.bottom)) / 2
        : a.center.dy;
    final (x0, x1) = b.left >= a.right ? (a.right, b.left) : (b.right, a.left);
    out.add(Guide(Offset(x0, y), Offset(x1, y), label: x1 - x0));
    if (y < b.top || y > b.bottom) {
      final x = b.left >= a.right ? b.left : b.right;
      out.add(
        Guide(
          Offset(x, y),
          Offset(x, y < b.top ? b.top : b.bottom),
          dashed: true,
        ),
      );
    }
  }
  if (apartY) {
    final x = math.max(a.left, b.left) < math.min(a.right, b.right)
        ? (math.max(a.left, b.left) + math.min(a.right, b.right)) / 2
        : a.center.dx;
    final (y0, y1) = b.top >= a.bottom ? (a.bottom, b.top) : (b.bottom, a.top);
    out.add(Guide(Offset(x, y0), Offset(x, y1), label: y1 - y0));
    if (x < b.left || x > b.right) {
      final y = b.top >= a.bottom ? b.top : b.bottom;
      out.add(
        Guide(
          Offset(x, y),
          Offset(x < b.left ? b.left : b.right, y),
          dashed: true,
        ),
      );
    }
  }
  return out;
}
