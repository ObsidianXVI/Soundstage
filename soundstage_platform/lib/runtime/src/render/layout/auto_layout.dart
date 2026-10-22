import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/painting.dart' show EdgeInsets;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'constraints.dart' show clampSize;

/// How a child is sized along one axis inside an auto-layout parent, after
/// the node's own rules are applied (see `lib/runtime/README.md`).
enum StageAxisSizing { fixed, hug, fill }

/// Measures a child's box. A non-null [width]/[height] is a definite size the
/// child must take on that axis; a null axis is the child's natural size
/// (its content size if it hugs that axis, else its stored size).
typedef StageMeasure = Size Function(double? width, double? height);

/// A child's first baseline, from the top of its (unrotated) box, when laid
/// out at [size]. Null when the child has no text in flow.
typedef StageBaseline = double? Function(Size size);

/// A child as the auto-layout algorithm sees it. Pure data plus callbacks,
/// so the algorithm can be tested without render objects.
class AutoLayoutChild {
  const AutoLayoutChild({
    required this.width,
    required this.height,
    this.inFlow = true,
    this.horizontalSizing = StageAxisSizing.fixed,
    this.verticalSizing = StageAxisSizing.fixed,
    this.minWidth,
    this.maxWidth,
    this.minHeight,
    this.maxHeight,
    this.rotation = 0,
    this.strokeOutsets = EdgeInsets.zero,
    this.measure,
    this.baseline,
  });

  /// Stored size, used for `fixed` axes (and as the natural size when
  /// [measure] is null).
  final double width;
  final double height;

  /// False for hidden and `absolute` children (§4.4 step 1).
  final bool inFlow;
  final StageAxisSizing horizontalSizing;
  final StageAxisSizing verticalSizing;
  final double? minWidth;
  final double? maxWidth;
  final double? minHeight;
  final double? maxHeight;

  /// Geometric rotation in degrees, clockwise, about the box centre.
  final double rotation;

  /// The outside portion of the child's strokes per side. Only used when the
  /// parent has `strokesIncludedInLayout`.
  final EdgeInsets strokeOutsets;
  final StageMeasure? measure;
  final StageBaseline? baseline;

  bool get isRotated => rotation % 360 != 0;
}

/// The output of [computeAutoLayout].
class AutoLayoutResult {
  const AutoLayoutResult({
    required this.size,
    required this.boxes,
    required this.paintOrder,
  });

  /// The frame's size.
  final Size size;

  /// Per input child, its unrotated box in the frame's coordinates, placed
  /// so its rotated (and stroke-inflated) bounding box sits where layout put
  /// it. Null for children that are not in flow.
  final List<Rect?> boxes;

  /// Child indices in paint order, bottom first (§4.4 step 10).
  final List<int> paintOrder;
}

/// Child indices in paint order (bottom first): child order, or reversed
/// when [reverseZIndex] (the first child paints on top).
List<int> stagePaintOrder(int count, {required bool reverseZIndex}) => [
  for (var i = 0; i < count; i++) reverseZIndex ? count - 1 - i : i,
];

/// The bounding box of a box of [size], inflated by [outsets], after
/// rotating it by [rotation] degrees about the box centre. Returns the
/// footprint size and the offset of the box's top-left inside it.
({Size size, Offset boxOffset}) rotatedFootprint(
  Size size,
  double rotation, {
  EdgeInsets outsets = EdgeInsets.zero,
}) {
  final l = -outsets.left;
  final t = -outsets.top;
  final r = size.width + outsets.right;
  final b = size.height + outsets.bottom;
  if (rotation % 360 == 0) {
    return (size: Size(r - l, b - t), boxOffset: Offset(-l, -t));
  }
  final a = rotation * math.pi / 180;
  final cos = math.cos(a);
  final sin = math.sin(a);
  final cx = size.width / 2;
  final cy = size.height / 2;
  var minX = double.infinity;
  var minY = double.infinity;
  var maxX = -double.infinity;
  var maxY = -double.infinity;
  for (final (x, y) in [(l, t), (r, t), (r, b), (l, b)]) {
    final dx = x - cx;
    final dy = y - cy;
    final px = cx + dx * cos - dy * sin;
    final py = cy + dx * sin + dy * cos;
    minX = math.min(minX, px);
    minY = math.min(minY, py);
    maxX = math.max(maxX, px);
    maxY = math.max(maxY, py);
  }
  return (
    size: Size(maxX - minX, maxY - minY),
    boxOffset: Offset(-minX, -minY),
  );
}

/// The first baseline of a frame whose children were placed at [boxes]
/// (§4.4 step 7): that of its first child, in child order, that has text in
/// flow. Rotated children and children without a box are skipped. Null when
/// there is none (the parent then uses the frame's bottom edge).
double? firstBaselineOf(List<AutoLayoutChild> children, List<Rect?> boxes) {
  for (var i = 0; i < children.length; i++) {
    final box = boxes[i];
    final c = children[i];
    if (box == null || c.isRotated) continue;
    final b = c.baseline?.call(box.size);
    if (b != null) return box.top + b;
  }
  return null;
}

/// Lays out an auto-layout frame (architecture §4.4, steps 1–8 and 10; step
/// 9, absolute children, is the caller's job via `resolveConstraints`).
///
/// [width]/[height] are the frame's definite size; null means the frame
/// hugs that axis, clamped by [minWidth]…[maxHeight]. Vertical layouts are
/// the transpose of horizontal ones. `wrap` applies to horizontal layouts
/// with a definite width only.
AutoLayoutResult computeAutoLayout({
  required ir.AutoLayout layout,
  required List<AutoLayoutChild> children,
  double? width,
  double? height,
  double? minWidth,
  double? maxWidth,
  double? minHeight,
  double? maxHeight,
}) {
  final a = _Axes(layout.direction == ir.LayoutDirection.horizontal);
  final pad = layout.padding;
  final padMainStart = a.h ? pad.left : pad.top;
  final padMainEnd = a.h ? pad.right : pad.bottom;
  final padCrossStart = a.h ? pad.top : pad.left;
  final padCrossEnd = a.h ? pad.bottom : pad.right;
  final padMain = padMainStart + padMainEnd;
  final padCross = padCrossStart + padCrossEnd;

  final frameMain = a.h ? width : height;
  final frameCross = a.h ? height : width;
  final frameMainMin = a.h ? minWidth : minHeight;
  final frameMainMax = a.h ? maxWidth : maxHeight;
  final frameCrossMin = a.h ? minHeight : minWidth;
  final frameCrossMax = a.h ? maxHeight : maxWidth;

  // Step 1: content box.
  double? contentMain = frameMain == null
      ? null
      : math.max(0.0, frameMain - padMain);
  double? contentCross = frameCross == null
      ? null
      : math.max(0.0, frameCross - padCross);
  final wrap = layout.wrap && a.h && contentMain != null;
  final gapAuto = layout.gap is ir.AutoGap;
  final gapFixed = switch (layout.gap) {
    ir.FixedGap(:final value) => value,
    ir.AutoGap() => 0.0,
  };
  final crossGapAuto = layout.counterAxisGap is ir.AutoGap;
  final crossGapFixed = switch (layout.counterAxisGap) {
    ir.FixedGap(:final value) => value,
    ir.AutoGap() => 0.0,
  };
  final strokes = layout.strokesIncludedInLayout;

  final items = <_Item>[
    for (var i = 0; i < children.length; i++)
      if (children[i].inFlow) _Item(i, children[i], a, strokes),
  ];
  for (final it in items) {
    // Step 4: in a hugging primary axis, `fill` behaves as `hug`.
    if (it.main == StageAxisSizing.fill && contentMain == null) {
      it.main = StageAxisSizing.hug;
    }
  }

  // The definite cross size a child gets in the first pass: fixed → stored;
  // fill → the content box when known (and not wrapping, where it is the
  // row's height instead); hug → natural.
  double? crossGiven(_Item it) => switch (it.cross) {
    StageAxisSizing.fixed => a.cross(it.c.width, it.c.height),
    StageAxisSizing.fill =>
      !wrap && contentCross != null
          ? math.max(0.0, contentCross - it.outCross)
          : null,
    StageAxisSizing.hug => null,
  };

  // Steps 2–3: measure non-fill children on both axes.
  for (final it in items) {
    if (it.main == StageAxisSizing.fill) continue;
    it.setBox(
      _sizeChild(
        it.c,
        a,
        main: it.main == StageAxisSizing.fixed
            ? a.main(it.c.width, it.c.height)
            : null,
        cross: crossGiven(it),
      ),
    );
  }

  // Step 8: break into rows (a single row without wrap).
  final rows = <List<_Item>>[];
  if (!wrap) {
    rows.add(items);
  } else {
    var row = <_Item>[];
    var used = 0.0;
    for (final it in items) {
      final w = it.main == StageAxisSizing.fill
          ? clampSize(0, it.minMain, it.maxMain) + it.outMain
          : it.footMain;
      final g = gapAuto ? 0.0 : gapFixed;
      if (row.isNotEmpty && used + g + w > contentMain + 1e-9) {
        rows.add(row);
        row = <_Item>[];
        used = 0;
      }
      used += (row.isEmpty ? 0 : g) + w;
      row.add(it);
    }
    if (row.isNotEmpty) rows.add(row);
  }

  // Step 5: split free space among fill children, per row; then size
  // children that fill the cross axis of a hugging or wrapped row.
  for (final row in rows) {
    final n = row.length;
    final gapTotal = gapAuto ? 0.0 : gapFixed * math.max(0, n - 1);
    final fills = [
      for (final it in row)
        if (it.main == StageAxisSizing.fill) it,
    ];
    if (fills.isNotEmpty) {
      var nonFill = 0.0;
      for (final it in row) {
        if (it.main != StageAxisSizing.fill) nonFill += it.footMain;
      }
      final free = contentMain! - nonFill - gapTotal;
      final shares = _distribute(free, fills);
      for (var i = 0; i < fills.length; i++) {
        final it = fills[i];
        it.setBox(_sizeChild(it.c, a, main: shares[i], cross: crossGiven(it)));
      }
    }
    if (wrap || contentCross == null) {
      var target = 0.0;
      var any = false;
      for (final it in row) {
        if (it.cross == StageAxisSizing.fill) continue;
        target = math.max(target, it.footCross);
        any = true;
      }
      if (!any) {
        for (final it in row) {
          target = math.max(target, it.footCross);
        }
      }
      for (final it in row) {
        if (it.cross != StageAxisSizing.fill) continue;
        it.setBox(
          _sizeChild(
            it.c,
            a,
            main: a.main(it.box.width, it.box.height),
            cross: math.max(0.0, target - it.outCross),
          ),
        );
      }
    }
  }

  // Step 4: a hugging primary axis sums the children.
  if (contentMain == null) {
    var widest = 0.0;
    for (final row in rows) {
      var sum = 0.0;
      for (final it in row) {
        sum += it.footMain;
      }
      final g = gapAuto ? 0.0 : gapFixed;
      widest = math.max(widest, sum + g * math.max(0, row.length - 1));
    }
    final fm = clampSize(widest + padMain, frameMainMin, frameMainMax);
    contentMain = math.max(0.0, fm - padMain);
  }

  // Step 7 (counter axis): row extents, with baseline alignment.
  final baseline = a.h && layout.counterAlign == ir.CounterAlign.baseline;
  final rowExtents = <double>[];
  final baselineTops = <_Item, double>{};
  for (final row in rows) {
    var extent = 0.0;
    if (baseline) {
      var maxBase = 0.0;
      final bases = <_Item, double>{};
      for (final it in row) {
        final b = it.c.isRotated
            ? it.footCross
            : it.boxOffset.dy + (it.c.baseline?.call(it.box) ?? it.box.height);
        bases[it] = b;
        maxBase = math.max(maxBase, b);
      }
      for (final it in row) {
        final top = maxBase - bases[it]!;
        baselineTops[it] = top;
        extent = math.max(extent, top + it.footCross);
      }
    } else {
      for (final it in row) {
        extent = math.max(extent, it.footCross);
      }
    }
    rowExtents.add(extent);
  }

  // Step 8: a hugging counter axis sums the rows.
  final nRows = rows.length;
  var block = 0.0;
  for (final e in rowExtents) {
    block += e;
  }
  final rowGap = crossGapAuto ? 0.0 : crossGapFixed;
  block += wrap ? rowGap * math.max(0, nRows - 1) : 0;
  if (contentCross == null) {
    final fc = clampSize(block + padCross, frameCrossMin, frameCrossMax);
    contentCross = math.max(0.0, fc - padCross);
  }
  final cMain = contentMain;
  final cCross = contentCross;

  // Position the block of rows (wrap) and the rows' items.
  var rowCursor = 0.0;
  var rowSpacing = rowGap;
  if (wrap) {
    final leftover = cCross - block;
    if (crossGapAuto) {
      // Like `gap = auto`: rows spread out; a single row sits at the start.
      rowSpacing = nRows > 1 ? math.max(0.0, leftover / (nRows - 1)) : 0;
    } else {
      rowCursor = _align(layout.rowAlign.index, leftover);
    }
  }

  final boxes = List<Rect?>.filled(children.length, null);
  for (var r = 0; r < nRows; r++) {
    final row = rows[r];
    final n = row.length;
    final extent = wrap ? rowExtents[r] : cCross;
    var sum = 0.0;
    for (final it in row) {
      sum += it.footMain;
    }
    double gap;
    double cursor;
    if (gapAuto) {
      // Step 6: space-between; a single child sits at the start.
      gap = n > 1 ? math.max(0.0, (cMain - sum) / (n - 1)) : 0;
      cursor = 0;
    } else {
      gap = gapFixed;
      final leftover = cMain - sum - gap * math.max(0, n - 1);
      cursor = _align(layout.primaryAlign.index, leftover);
    }
    for (final it in row) {
      final double crossOffset;
      if (baseline) {
        crossOffset = baselineTops[it]!;
      } else {
        final free = extent - it.footCross;
        crossOffset = switch (layout.counterAlign) {
          ir.CounterAlign.start || ir.CounterAlign.baseline => 0.0,
          ir.CounterAlign.center => free / 2,
          ir.CounterAlign.end => free,
        };
      }
      final footMain = padMainStart + cursor;
      final footCross = padCrossStart + rowCursor + crossOffset;
      final origin = a.h
          ? Offset(footMain, footCross)
          : Offset(footCross, footMain);
      boxes[it.index] = (origin + it.boxOffset) & it.box;
      cursor += it.footMain + gap;
    }
    rowCursor += rowExtents[r] + rowSpacing;
  }

  return AutoLayoutResult(
    size: a.size(cMain + padMain, cCross + padCross),
    boxes: boxes,
    paintOrder: stagePaintOrder(
      children.length,
      reverseZIndex: layout.reverseZIndex,
    ),
  );
}

/// Offset of a run for a start/center/end alignment index (0/1/2).
double _align(int index, double leftover) => switch (index) {
  0 => 0.0,
  1 => leftover / 2,
  _ => leftover,
};

/// Splits [free] equally among [fills], freezing children that hit their
/// min/max and redistributing the rest (the CSS flex freeze loop with equal
/// grow factors and zero basis). Returns each child's box size on the main
/// axis.
List<double> _distribute(double free, List<_Item> fills) {
  final result = List<double>.filled(fills.length, 0);
  final active = [for (var i = 0; i < fills.length; i++) i];
  var remaining = free;
  while (active.isNotEmpty) {
    final share = remaining / active.length;
    final clamped = <int, double>{};
    var total = 0.0;
    for (final i in active) {
      final target = share - fills[i].outMain;
      final v = clampSize(target, fills[i].minMain, fills[i].maxMain);
      clamped[i] = v;
      total += v - target;
    }
    if (total.abs() < 1e-9) {
      for (final i in active) {
        result[i] = clamped[i]!;
      }
      break;
    }
    final freezeMin = total > 0;
    active.removeWhere((i) {
      final target = share - fills[i].outMain;
      final diff = clamped[i]! - target;
      final freeze = freezeMin ? diff > 1e-9 : diff < -1e-9;
      if (freeze) {
        result[i] = clamped[i]!;
        remaining -= clamped[i]! + fills[i].outMain;
      }
      return freeze;
    });
  }
  return result;
}

/// Sizes [c] with definite [main]/[cross] sizes where given (clamped by the
/// child's min/max) and its natural size elsewhere, clamped too. A clamped
/// natural width is measured again at that width (text rewraps).
Size _sizeChild(
  AutoLayoutChild c,
  _Axes a, {
  required double? main,
  required double? cross,
}) => sizeStageChild(c, width: a.h ? main : cross, height: a.h ? cross : main);

/// Sizes [c] for a definite [width]/[height] (null = natural), applying the
/// child's min/max (architecture §4.4 step 3).
Size sizeStageChild(AutoLayoutChild c, {double? width, double? height}) {
  final gw = width == null ? null : clampSize(width, c.minWidth, c.maxWidth);
  final gh = height == null
      ? null
      : clampSize(height, c.minHeight, c.maxHeight);
  var s = _measure(c, gw, gh);
  if (gw == null) {
    final cw = clampSize(s.width, c.minWidth, c.maxWidth);
    if (cw != s.width) s = _measure(c, cw, gh);
  }
  if (gh == null) {
    s = Size(s.width, clampSize(s.height, c.minHeight, c.maxHeight));
  }
  return s;
}

Size _measure(AutoLayoutChild c, double? w, double? h) {
  final m = c.measure;
  final r = m == null ? Size(w ?? c.width, h ?? c.height) : m(w, h);
  return Size(w ?? r.width, h ?? r.height);
}

/// Maps primary/counter values to x/y for a layout direction.
class _Axes {
  const _Axes(this.h);

  /// Horizontal layout.
  final bool h;

  double main(double width, double height) => h ? width : height;
  double cross(double width, double height) => h ? height : width;
  Size size(double main, double cross) =>
      h ? Size(main, cross) : Size(cross, main);
}

/// Working state for one in-flow child.
class _Item {
  _Item(this.index, this.c, this.a, bool strokes)
    : out = strokes ? c.strokeOutsets : EdgeInsets.zero {
    var hz = c.horizontalSizing;
    var vt = c.verticalSizing;
    if (c.isRotated) {
      // A rotated child keeps its stored size where it would fill: the
      // rotated footprint of a stretched box is not well defined.
      if (hz == StageAxisSizing.fill) hz = StageAxisSizing.fixed;
      if (vt == StageAxisSizing.fill) vt = StageAxisSizing.fixed;
    }
    main = a.h ? hz : vt;
    cross = a.h ? vt : hz;
  }

  final int index;
  final AutoLayoutChild c;
  final _Axes a;
  final EdgeInsets out;
  late StageAxisSizing main;
  late StageAxisSizing cross;

  Size box = Size.zero;
  Size foot = Size.zero;
  Offset boxOffset = Offset.zero;

  void setBox(Size s) {
    box = s;
    final f = rotatedFootprint(s, c.rotation, outsets: out);
    foot = f.size;
    boxOffset = f.boxOffset;
  }

  double get footMain => a.main(foot.width, foot.height);
  double get footCross => a.cross(foot.width, foot.height);
  double get outMain => a.h ? out.horizontal : out.vertical;
  double get outCross => a.h ? out.vertical : out.horizontal;
  double? get minMain => a.h ? c.minWidth : c.minHeight;
  double? get maxMain => a.h ? c.maxWidth : c.maxHeight;
}
