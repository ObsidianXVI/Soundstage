import 'dart:math' as math;
import 'dart:ui';

// Pure geometry for the canvas transform tools (T1.5): resize per handle and
// modifier, rotation with snapping, proportional multi-selection maps and the
// insertion slot of an auto-layout reorder. Boxes are *unrotated* boxes in
// their parent's space (the runtime places a rotated node by its unrotated
// box and rotates it about the centre).

/// The eight resize handles, clockwise from the top-left corner.
enum ResizeHandle {
  topLeft(-1, -1),
  top(0, -1),
  topRight(1, -1),
  right(1, 0),
  bottomRight(1, 1),
  bottom(0, 1),
  bottomLeft(-1, 1),
  left(-1, 0);

  const ResizeHandle(this.hx, this.hy);

  /// −1: moves the left (top) edge, 1: the right (bottom) edge, 0: neither.
  final int hx, hy;

  bool get isCorner => hx != 0 && hy != 0;

  /// The handle's point on a box of [size] (local coordinates).
  Offset on(Size size) =>
      Offset((hx + 1) / 2 * size.width, (hy + 1) / 2 * size.height);
}

/// [p] rotated by [degrees] (clockwise on screen, y down) about the origin.
Offset rotateVector(Offset p, double degrees) {
  if (degrees % 360 == 0) return p;
  final a = degrees * math.pi / 180;
  final c = math.cos(a), s = math.sin(a);
  return Offset(p.dx * c - p.dy * s, p.dx * s + p.dy * c);
}

/// [p] rotated by [degrees] about [centre].
Offset rotateAbout(Offset p, Offset centre, double degrees) =>
    centre + rotateVector(p - centre, degrees);

/// The result of [resizeBox]: the new unrotated box in the parent's space
/// and which sizes changed.
typedef ResizeResult = ({Rect box, bool widthChanged, bool heightChanged});

/// Resizes [box] (unrotated, parent space; the node is rotated by
/// [rotation] degrees about the box centre) by dragging [handle] by [delta]
/// (parent space).
///
/// The drag is applied in the node's own (rotated) frame, so a rotated
/// node resizes along its own axes and the opposite handle stays put on
/// screen.
///
/// - [keepAspect] (Shift): corners follow the axis that changed most; an
///   edge handle scales the other axis about the centre.
/// - [fromCenter] (Alt): the opposite side mirrors the drag, so the centre
///   stays put.
/// - Sizes are clamped to [minSize] (no flipping through zero; Soundstage
///   has flips as properties) and to the node's min/max. A clamped edge
///   stops while the anchor stays.
ResizeResult resizeBox({
  required Rect box,
  required ResizeHandle handle,
  required Offset delta,
  double rotation = 0,
  bool keepAspect = false,
  bool fromCenter = false,
  double minSize = 1,
  double? minWidth,
  double? maxWidth,
  double? minHeight,
  double? maxHeight,
}) {
  final d = rotateVector(delta, -rotation);
  final w0 = box.width, h0 = box.height;
  var l = -w0 / 2, r = w0 / 2, t = -h0 / 2, b = h0 / 2;
  final hx = handle.hx, hy = handle.hy;
  if (hx == 1) {
    r += d.dx;
    if (fromCenter) l -= d.dx;
  } else if (hx == -1) {
    l += d.dx;
    if (fromCenter) r -= d.dx;
  }
  if (hy == 1) {
    b += d.dy;
    if (fromCenter) t -= d.dy;
  } else if (hy == -1) {
    t += d.dy;
    if (fromCenter) b -= d.dy;
  }
  var w = r - l, h = b - t;
  if (keepAspect && w0 > 0 && h0 > 0) {
    final aspect = w0 / h0;
    if (handle.isCorner) {
      if ((w / w0 - 1).abs() >= (h / h0 - 1).abs()) {
        h = w / aspect;
      } else {
        w = h * aspect;
      }
    } else if (hx == 0) {
      w = h * aspect;
    } else {
      h = w / aspect;
    }
  }
  double clampTo(double v, double? lo, double? hi) {
    var out = math.max(v, minSize);
    if (hi != null && out > hi) out = hi;
    if (lo != null && out < lo) out = lo;
    return out;
  }

  w = clampTo(w, minWidth, maxWidth);
  h = clampTo(h, minHeight, maxHeight);
  if (keepAspect && w0 > 0 && h0 > 0) {
    // Clamping one axis keeps the ratio by shrinking the other.
    final aspect = w0 / h0;
    if ((w / h - aspect).abs() > 1e-9) {
      final byW = w / aspect, byH = h * aspect;
      if (byW <= h) {
        h = clampTo(byW, minHeight, maxHeight);
      } else {
        w = clampTo(byH, minWidth, maxWidth);
      }
    }
  }
  // Re-anchor each axis: the opposite edge (or the centre) stays.
  double lo, hi;
  if (fromCenter || hx == 0) {
    lo = -w / 2;
    hi = w / 2;
  } else if (hx == 1) {
    lo = -w0 / 2;
    hi = lo + w;
  } else {
    hi = w0 / 2;
    lo = hi - w;
  }
  l = lo;
  r = hi;
  if (fromCenter || hy == 0) {
    lo = -h / 2;
    hi = h / 2;
  } else if (hy == 1) {
    lo = -h0 / 2;
    hi = lo + h;
  } else {
    hi = h0 / 2;
    lo = hi - h;
  }
  t = lo;
  b = hi;
  final localCentre = Offset((l + r) / 2, (t + b) / 2);
  final centre = box.center + rotateVector(localCentre, rotation);
  return (
    box: Rect.fromCenter(center: centre, width: w, height: h),
    widthChanged: (w - w0).abs() > 1e-9,
    heightChanged: (h - h0).abs() > 1e-9,
  );
}

/// [child] mapped proportionally from [from] to [to] (multi-selection
/// resize: every box scales with the union).
Rect mapRectProportionally(Rect child, Rect from, Rect to) {
  final sx = from.width == 0 ? 1.0 : to.width / from.width;
  final sy = from.height == 0 ? 1.0 : to.height / from.height;
  return Rect.fromLTWH(
    to.left + (child.left - from.left) * sx,
    to.top + (child.top - from.top) * sy,
    child.width * sx,
    child.height * sy,
  );
}

/// The rotation snap step with Shift held (Figma).
const double kRotationSnapDegrees = 15;

/// [degrees] normalised to (−180, 180].
double normalizeDegrees(double degrees) {
  var d = degrees % 360;
  if (d > 180) d -= 360;
  if (d <= -180) d += 360;
  return d == 0 ? 0 : d;
}

/// The rotation after dragging from [start] to [now] about [centre]
/// (screen or world space, y down: clockwise positive), starting at
/// [startRotation]. With [snap] (Shift) the result snaps to 15°.
double dragRotation({
  required Offset centre,
  required Offset start,
  required Offset now,
  required double startRotation,
  bool snap = false,
}) {
  final a0 = (start - centre).direction;
  final a1 = (now - centre).direction;
  var r = startRotation + (a1 - a0) * 180 / math.pi;
  if (snap) r = (r / kRotationSnapDegrees).round() * kRotationSnapDegrees;
  return normalizeDegrees(r);
}

/// An in-flow sibling for [flowSlot]: its index in the parent's children
/// and its laid-out box in the parent's space.
typedef FlowSibling = ({int index, Rect box});

/// Where a drag would drop into an auto-layout frame: the insertion
/// [index] in the parent's current children (counting the dragged nodes as
/// still there, as `moveNodes` takes it) and the indicator line ([a]–[b],
/// parent space).
typedef FlowSlot = ({int index, Offset a, Offset b});

/// The insertion slot for [pointer] (parent space) among [siblings] (the
/// in-flow children in flow order, without the dragged ones), Figma-style:
/// before the first sibling whose primary-axis midpoint lies past the
/// pointer. With [wrap] (horizontal only) the row is the one whose
/// vertical span contains the pointer, else the nearest. [content] is the
/// frame's content box, for the indicator of an empty frame;
/// [childCount] is the parent's child count (the slot after the last
/// child).
FlowSlot flowSlot({
  required List<FlowSibling> siblings,
  required Offset pointer,
  required bool horizontal,
  required Rect content,
  required int childCount,
  bool wrap = false,
}) {
  if (siblings.isEmpty) {
    return horizontal
        ? (
            index: childCount,
            a: Offset(content.left, content.top),
            b: Offset(content.left, content.bottom),
          )
        : (
            index: childCount,
            a: Offset(content.left, content.top),
            b: Offset(content.right, content.top),
          );
  }
  double p(Offset o) => horizontal ? o.dx : o.dy;
  double start(Rect r) => horizontal ? r.left : r.top;
  double end(Rect r) => horizontal ? r.right : r.bottom;
  var row = siblings;
  if (wrap && horizontal) {
    // Rows: consecutive siblings whose vertical spans overlap.
    final rows = <List<FlowSibling>>[];
    for (final s in siblings) {
      if (rows.isEmpty) {
        rows.add([s]);
        continue;
      }
      final last = rows.last;
      final top = last.map((e) => e.box.top).reduce(math.min);
      final bottom = last.map((e) => e.box.bottom).reduce(math.max);
      if (s.box.left >= last.last.box.right - 0.5 &&
          s.box.top < bottom &&
          s.box.bottom > top) {
        last.add(s);
      } else {
        rows.add([s]);
      }
    }
    var best = double.infinity;
    for (final r in rows) {
      final top = r.map((e) => e.box.top).reduce(math.min);
      final bottom = r.map((e) => e.box.bottom).reduce(math.max);
      final dist = pointer.dy < top
          ? top - pointer.dy
          : (pointer.dy > bottom ? pointer.dy - bottom : 0.0);
      if (dist < best) {
        best = dist;
        row = r;
      }
    }
  }
  Offset at(double primary, Rect span) =>
      horizontal ? Offset(primary, span.top) : Offset(span.left, primary);
  Offset atEnd(double primary, Rect span) =>
      horizontal ? Offset(primary, span.bottom) : Offset(span.right, primary);
  for (var i = 0; i < row.length; i++) {
    final s = row[i];
    if (p(pointer) < (start(s.box) + end(s.box)) / 2) {
      final prev = i > 0 ? row[i - 1] : null;
      final line = prev == null
          ? start(s.box)
          : (end(prev.box) + start(s.box)) / 2;
      return (index: s.index, a: at(line, s.box), b: atEnd(line, s.box));
    }
  }
  final last = row.last;
  final line = end(last.box);
  // Right after the row's last sibling (a dragged node sitting there
  // counts as still present, which `moveNodes` expects).
  return (
    index: last.index + 1,
    a: at(line, last.box),
    b: atEnd(line, last.box),
  );
}

/// The screen-space resize cursor direction for a handle drawn at angle
/// [degrees] from the box centre (0° = right, clockwise): 0 ↔ (left-right),
/// 45 ⤡ (up-left/down-right), 90 ↕, 135 ⤢. Rotated nodes get the nearest
/// of the four.
int resizeCursorAngle(double degrees) {
  final d = ((degrees % 180) + 180) % 180;
  final steps = (d / 45).round() % 4;
  return steps * 45;
}
