import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'auto_layout.dart';

// Grid layout (architecture §4.5; m3.md T3.5). Pure, like
// `computeAutoLayout`, so it is testable without render objects.
//
// - Tracks: `fixed(px)`, `flex(fr)` (a share of the space left after fixed
//   and hug tracks; a flex track of a grid that hugs that axis sizes like
//   hug) and `hug` (the largest natural size of the single-span items in
//   it). No columns means one flex column.
// - Placement: items with both `column` and `row` go there; an item with
//   only one of them takes the first free cell along it; the rest are
//   auto-placed in child order, row by row (`autoFlow: row`) or column by
//   column. Tracks are added on demand (implicit tracks hug), so nothing is
//   dropped; spans are clamped to the explicit track count of the axis that
//   does not grow.
// - In its cell (the union of its spanned tracks and the gaps between
//   them), an item is aligned by `alignX/alignY`; `stretch` (or `fill`
//   sizing) makes it the cell's size on that axis.

/// One child as the grid sees it: its auto-layout data plus its placement.
class GridLayoutChild {
  const GridLayoutChild(this.child, this.placement);

  final AutoLayoutChild child;
  final ir.GridPlacement placement;
}

/// Lays out [children] in [layout]. [width]/[height] are the frame's
/// definite size, or null when the frame hugs that axis.
AutoLayoutResult computeGridLayout({
  required ir.GridLayout layout,
  required List<GridLayoutChild> children,
  double? width,
  double? height,
}) {
  final rowFlow = layout.autoFlow == ir.GridAutoFlow.row;
  final explicitCols = layout.columns.isEmpty
      ? const [ir.GridTrack.flex()]
      : layout.columns;
  final explicitRows = layout.rows;

  // ---- Placement ----
  // The axis that does not grow bounds spans and auto-placement.
  final fixedCount = rowFlow
      ? explicitCols.length
      : math.max(1, explicitRows.length);
  final taken = <(int, int)>{}; // (column, row)
  bool free(int c, int r, int cs, int rs) {
    for (var x = c; x < c + cs; x++) {
      for (var y = r; y < r + rs; y++) {
        if (taken.contains((x, y))) return false;
      }
    }
    return true;
  }

  void take(int c, int r, int cs, int rs) {
    for (var x = c; x < c + cs; x++) {
      for (var y = r; y < r + rs; y++) {
        taken.add((x, y));
      }
    }
  }

  final cells = List<(int, int, int, int)?>.filled(children.length, null);
  int clampSpan(int span, int start) =>
      math.max(1, math.min(span, math.max(1, fixedCount - start)));

  // Pass 1: fully placed items; pass 2: one coordinate; pass 3: auto.
  for (var pass = 0; pass < 3; pass++) {
    var cursorMajor = 0, cursorMinor = 0;
    for (var i = 0; i < children.length; i++) {
      if (cells[i] != null || !children[i].child.inFlow) continue;
      final p = children[i].placement;
      final hasC = p.column != null, hasR = p.row != null;
      final level = hasC && hasR ? 0 : (hasC || hasR ? 1 : 2);
      if (level != pass) continue;
      var cs = math.max(1, p.columnSpan), rs = math.max(1, p.rowSpan);
      if (pass == 0) {
        final c = math.max(0, p.column!), r = math.max(0, p.row!);
        cells[i] = (c, r, cs, rs);
        take(c, r, cs, rs);
        continue;
      }
      if (pass == 1) {
        if (hasC) {
          final c = math.max(0, p.column!);
          var r = 0;
          while (!free(c, r, cs, rs)) {
            r++;
          }
          cells[i] = (c, r, cs, rs);
          take(c, r, cs, rs);
        } else {
          final r = math.max(0, p.row!);
          if (rowFlow) cs = clampSpan(cs, 0);
          var c = 0;
          while (!free(c, r, cs, rs)) {
            c++;
          }
          cells[i] = (c, r, cs, rs);
          take(c, r, cs, rs);
        }
        continue;
      }
      // Auto: walk the growing axis (major) and the bounded one (minor).
      if (rowFlow) {
        cs = clampSpan(cs, 0);
      } else {
        rs = clampSpan(rs, 0);
      }
      final span = rowFlow ? cs : rs;
      while (true) {
        if (cursorMinor + span > fixedCount) {
          cursorMinor = 0;
          cursorMajor++;
          continue;
        }
        final c = rowFlow ? cursorMinor : cursorMajor;
        final r = rowFlow ? cursorMajor : cursorMinor;
        if (free(c, r, cs, rs)) {
          cells[i] = (c, r, cs, rs);
          take(c, r, cs, rs);
          cursorMinor += span;
          break;
        }
        cursorMinor++;
      }
    }
  }

  var colCount = explicitCols.length, rowCount = explicitRows.length;
  for (final cell in cells) {
    if (cell == null) continue;
    colCount = math.max(colCount, cell.$1 + cell.$3);
    rowCount = math.max(rowCount, cell.$2 + cell.$4);
  }
  final cols = [
    for (var i = 0; i < colCount; i++)
      i < explicitCols.length ? explicitCols[i] : const ir.GridTrack.hug(),
  ];
  final rows = [
    for (var i = 0; i < rowCount; i++)
      i < explicitRows.length ? explicitRows[i] : const ir.GridTrack.hug(),
  ];

  final pad = layout.padding;
  bool stretchX(GridLayoutChild g) =>
      g.placement.alignX == ir.GridAlign.stretch ||
      g.child.horizontalSizing == StageAxisSizing.fill;
  bool stretchY(GridLayoutChild g) =>
      g.placement.alignY == ir.GridAlign.stretch ||
      g.child.verticalSizing == StageAxisSizing.fill;
  Size natural(AutoLayoutChild c, double? w, double? h) {
    final m = c.measure;
    final s = m == null ? Size(w ?? c.width, h ?? c.height) : m(w, h);
    return Size(
      _clamp(s.width, c.minWidth, c.maxWidth),
      _clamp(s.height, c.minHeight, c.maxHeight),
    );
  }

  // ---- Columns ----
  final colSizes = _sizeTracks(
    tracks: cols,
    gap: layout.columnGap,
    available: width == null ? null : width - pad.left - pad.right,
    hugOf: (t) {
      var m = 0.0;
      for (var i = 0; i < children.length; i++) {
        final cell = cells[i];
        if (cell == null || cell.$1 != t || cell.$3 != 1) continue;
        m = math.max(m, natural(children[i].child, null, null).width);
      }
      return m;
    },
  );
  double span(List<double> sizes, double gap, int start, int count) {
    var s = gap * (count - 1);
    for (var i = start; i < start + count && i < sizes.length; i++) {
      s += sizes[i];
    }
    return s;
  }

  // ---- Rows (measured at their column widths) ----
  final itemWidths = List<double>.filled(children.length, 0);
  for (var i = 0; i < children.length; i++) {
    final cell = cells[i];
    if (cell == null) continue;
    final g = children[i];
    final cellW = span(colSizes, layout.columnGap, cell.$1, cell.$3);
    itemWidths[i] = stretchX(g) ? cellW : natural(g.child, null, null).width;
  }
  final rowSizes = _sizeTracks(
    tracks: rows,
    gap: layout.rowGap,
    available: height == null ? null : height - pad.top - pad.bottom,
    hugOf: (t) {
      var m = 0.0;
      for (var i = 0; i < children.length; i++) {
        final cell = cells[i];
        if (cell == null || cell.$2 != t || cell.$4 != 1) continue;
        m = math.max(m, natural(children[i].child, itemWidths[i], null).height);
      }
      return m;
    },
  );

  final size = Size(
    width ??
        pad.left + pad.right + span(colSizes, layout.columnGap, 0, colCount),
    height ?? pad.top + pad.bottom + span(rowSizes, layout.rowGap, 0, rowCount),
  );

  // ---- Boxes ----
  double offsetOf(List<double> sizes, double gap, int index) {
    var o = 0.0;
    for (var i = 0; i < index; i++) {
      o += sizes[i] + gap;
    }
    return o;
  }

  double align(ir.GridAlign a, double cell, double item) => switch (a) {
    ir.GridAlign.center => (cell - item) / 2,
    ir.GridAlign.end => cell - item,
    _ => 0,
  };

  final boxes = List<Rect?>.filled(children.length, null);
  for (var i = 0; i < children.length; i++) {
    final cell = cells[i];
    if (cell == null) continue;
    final g = children[i];
    final cellX = pad.left + offsetOf(colSizes, layout.columnGap, cell.$1);
    final cellY = pad.top + offsetOf(rowSizes, layout.rowGap, cell.$2);
    final cellW = span(colSizes, layout.columnGap, cell.$1, cell.$3);
    final cellH = span(rowSizes, layout.rowGap, cell.$2, cell.$4);
    final sx = stretchX(g), sy = stretchY(g);
    final s = natural(g.child, sx ? cellW : null, sy ? cellH : null);
    final w = sx ? cellW : s.width;
    final h = sy ? cellH : s.height;
    boxes[i] = Rect.fromLTWH(
      cellX + align(g.placement.alignX, cellW, w),
      cellY + align(g.placement.alignY, cellH, h),
      w,
      h,
    );
  }

  return AutoLayoutResult(
    size: size,
    boxes: boxes,
    paintOrder: stagePaintOrder(children.length, reverseZIndex: false),
  );
}

double _clamp(double v, double? min, double? max) {
  var out = v;
  if (max != null && out > max) out = max;
  if (min != null && out < min) out = min;
  return out;
}

/// Track sizes for one axis: fixed, hug (from [hugOf]), and flex sharing
/// what is left of [available] (null: the axis hugs, flex sizes like hug).
List<double> _sizeTracks({
  required List<ir.GridTrack> tracks,
  required double gap,
  required double? available,
  required double Function(int track) hugOf,
}) {
  final sizes = List<double>.filled(tracks.length, 0);
  var used = gap * math.max(0, tracks.length - 1);
  var fr = 0.0;
  for (var i = 0; i < tracks.length; i++) {
    switch (tracks[i]) {
      case ir.FixedGridTrack(:final px):
        sizes[i] = math.max(0, px);
        used += sizes[i];
      case ir.HugGridTrack():
        sizes[i] = hugOf(i);
        used += sizes[i];
      case ir.FlexGridTrack(fr: final f):
        if (available == null) {
          sizes[i] = hugOf(i);
          used += sizes[i];
        } else {
          fr += math.max(0, f);
        }
    }
  }
  if (available != null && fr > 0) {
    final left = math.max(0.0, available - used);
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i] case ir.FlexGridTrack(fr: final f)) {
        sizes[i] = left * math.max(0, f) / fr;
      }
    }
  }
  return sizes;
}
