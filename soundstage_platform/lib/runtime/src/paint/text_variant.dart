import 'dart:ui' show Color, StrokeJoin;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'stage_color.dart';

/// Whether a span's [fills] can be painted as one text colour: no visible
/// paint (transparent), or exactly one visible, normally blended solid.
/// Anything else (gradients, images, stacks, blend modes) is painted through
/// a glyph mask.
bool isSimpleTextFill(List<ir.Paint> fills) {
  ir.Paint? only;
  for (final p in fills) {
    final visible = switch (p) {
      ir.SolidPaint(:final visible, :final opacity) ||
      ir.GradientPaint(:final visible, :final opacity) ||
      ir.ImagePaint(:final visible, :final opacity) => visible && opacity > 0,
    };
    if (!visible) continue;
    if (only != null) return false;
    only = p;
  }
  return only == null ||
      (only is ir.SolidPaint && only.blendMode == ir.BlendMode.normal);
}

/// The colour of a simple text fill (transparent when there is none).
Color simpleTextColor(List<ir.Paint> fills, [double opacity = 1]) {
  for (final p in fills) {
    if (p is ir.SolidPaint && p.visible && p.opacity > 0) {
      return stageColor(p.color, p.opacity * opacity);
    }
  }
  return const Color(0x00000000);
}

enum TextVariantKind { base, mask, stroke, shadow }

/// A way of painting the same laid-out text: the layout (line breaks,
/// positions) is shared, only the glyph colours or paints change.
///
/// - [TextVariantKind.base]: spans with a simple fill in their colour
///   (times [opacity]); spans with complex fills are transparent.
/// - [TextVariantKind.mask]: opaque black glyphs of the spans whose fills
///   equal [fills] (all spans when null); other spans are transparent. The
///   fill stack is composited through it.
/// - [TextVariantKind.stroke]: glyph outlines of [width], in [color].
/// - [TextVariantKind.shadow]: all glyphs in [color].
class StageTextVariant {
  const StageTextVariant.base({this.opacity = 1})
    : kind = TextVariantKind.base,
      fills = null,
      color = null,
      width = 0,
      join = StrokeJoin.miter,
      miterLimit = 4;

  const StageTextVariant.mask({this.fills})
    : kind = TextVariantKind.mask,
      opacity = 1,
      color = null,
      width = 0,
      join = StrokeJoin.miter,
      miterLimit = 4;

  const StageTextVariant.stroke({
    required this.width,
    required Color this.color,
    this.join = StrokeJoin.miter,
    this.miterLimit = 4,
  }) : kind = TextVariantKind.stroke,
       opacity = 1,
       fills = null;

  const StageTextVariant.shadow(Color this.color)
    : kind = TextVariantKind.shadow,
      opacity = 1,
      fills = null,
      width = 0,
      join = StrokeJoin.miter,
      miterLimit = 4;

  final TextVariantKind kind;
  final double opacity;
  final List<ir.Paint>? fills;
  final Color? color;
  final double width;
  final StrokeJoin join;
  final double miterLimit;

  /// The glyph colour for a span styled [s], or null when the span paints
  /// as a stroke ([kind] stroke uses a foreground paint instead).
  Color? colorFor(ir.TextStyle s) => switch (kind) {
    TextVariantKind.base =>
      isSimpleTextFill(s.fills)
          ? simpleTextColor(s.fills, opacity)
          : const Color(0x00000000),
    TextVariantKind.mask =>
      fills == null || listEquals(fills, s.fills)
          ? const Color(0xFF000000)
          : const Color(0x00000000),
    TextVariantKind.shadow => color,
    TextVariantKind.stroke => null,
  };

  /// Whether decorations (underline, strikethrough) are drawn.
  bool get drawsDecorations => kind != TextVariantKind.stroke;

  /// A stable key to cache a painter set per variant.
  String get key => switch (kind) {
    TextVariantKind.base => 'base:$opacity',
    TextVariantKind.mask =>
      'mask:${fills == null ? 'all' : Object.hashAll(fills!)}',
    TextVariantKind.stroke =>
      'stroke:$width:${color?.toARGB32()}:$join:$miterLimit',
    TextVariantKind.shadow => 'shadow:${color?.toARGB32()}',
  };
}
