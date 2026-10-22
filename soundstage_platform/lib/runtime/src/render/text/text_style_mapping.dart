import 'package:flutter/painting.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../media/fonts.dart';
import '../../paint/stage_color.dart';
import '../../paint/text_variant.dart';

/// Flutter's decoration thickness is a multiple of the font's own
/// thickness, which is unknown until font metrics are read (T0.7). The
/// font's thickness is approximated as this fraction of the font size.
const double kAssumedDecorationThicknessEm = 1 / 16;

/// `TextStyle.height` for [lineHeight] (architecture §7): `auto` → null
/// (the font's natural height), `percent` → v/100, `px` → v/fontSize.
double? lineHeightMultiplier(ir.LineHeight lineHeight, double fontSize) =>
    switch (lineHeight) {
      ir.AutoLineHeight() => null,
      ir.PercentLineHeight(:final value) => value / 100,
      ir.PxLineHeight(:final value) => fontSize > 0 ? value / fontSize : null,
    };

/// Letter spacing in pixels: `px` as is, `percent` → fontSize × v/100.
double letterSpacingPx(ir.LetterSpacing spacing, double fontSize) =>
    switch (spacing) {
      ir.PxLetterSpacing(:final value) => value,
      ir.PercentLetterSpacing(:final value) => fontSize * value / 100,
    };

/// The text colour for [fills]: the first visible solid fill, with its
/// paint opacity. Gradient and image text fills land in T0.5 (`srcIn`
/// compositing); until then a gradient's first stop stands in, and text
/// with no visible fill is transparent.
Color textColor(List<ir.Paint> fills) {
  for (final p in fills) {
    if (p case ir.SolidPaint(
      :final visible,
      :final opacity,
      :final color,
    ) when visible) {
      return stageColor(color, opacity);
    }
  }
  for (final p in fills) {
    if (p case ir.GradientPaint(
      :final visible,
      :final opacity,
      :final stops,
    ) when visible && stops.isNotEmpty) {
      return stageColor(stops.first.color, opacity);
    }
  }
  return const Color(0x00000000);
}

/// [text] with [textCase] applied (before layout, §7). `title` capitalises
/// the first letter of each word; [startsWord] says whether [text] starts a
/// word (false when the previous span ended mid-word). `smallCaps` keeps the
/// text and is applied through OpenType features instead.
String applyTextCase(
  String text,
  ir.TextCase textCase, {
  bool startsWord = true,
}) => switch (textCase) {
  ir.TextCase.upper => text.toUpperCase(),
  ir.TextCase.lower => text.toLowerCase(),
  ir.TextCase.title => _titleCase(text, startsWord),
  ir.TextCase.none ||
  ir.TextCase.smallCaps ||
  ir.TextCase.smallCapsForced => text,
};

String _titleCase(String text, bool startsWord) {
  final b = StringBuffer();
  var atStart = startsWord;
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    final space = ch.trim().isEmpty;
    b.write(atStart && !space ? ch.toUpperCase() : ch);
    atStart = space;
  }
  return b.toString();
}

/// The OpenType features for [style]: its `openType` map, `smcp` (and `c2sc`
/// for forced small caps) for small caps, and `sups`/`subs` for baseline
/// shifts. Tags that are not four characters are dropped.
List<FontFeature> fontFeatures(ir.TextStyle style) {
  final out = <FontFeature>[
    for (final MapEntry(:key, :value) in style.openType.entries)
      if (key.length == 4) FontFeature(key, value),
  ];
  if (style.textCase == ir.TextCase.smallCaps ||
      style.textCase == ir.TextCase.smallCapsForced) {
    out.add(const FontFeature.enable('smcp'));
  }
  if (style.textCase == ir.TextCase.smallCapsForced) {
    out.add(const FontFeature.enable('c2sc'));
  }
  switch (style.baselineShift) {
    case ir.BaselineShift.superscript:
      out.add(const FontFeature.superscripts());
    case ir.BaselineShift.subscript:
      out.add(const FontFeature.subscripts());
    case ir.BaselineShift.none:
      break;
  }
  return out;
}

/// The font variations for [s] rendered with [face]: the style's own
/// `fontVariations`, plus, on a variable face, the axes CSS and Figma set
/// automatically unless the style sets them:
/// - `wght` = the style's weight (clamped to the axis),
/// - `opsz` = the font size (optical sizing "auto"),
/// - italic on a face that is not italic: `ital` = 1, else `slnt` = the
///   axis minimum (the most slanted).
List<FontVariation> fontVariationsFor(ir.TextStyle s, StageFontFace? face) {
  final out = <FontVariation>[
    for (final MapEntry(:key, :value) in s.fontVariations.entries)
      if (key.length == 4) FontVariation(key, value),
  ];
  if (face == null || !face.face.variable) return out;
  final own = s.fontVariations;
  void auto(String tag, double v) {
    final a = face.axis(tag);
    if (a == null || own.containsKey(tag)) return;
    out.add(FontVariation(tag, v.clamp(a.min, a.max)));
  }

  auto('wght', s.fontWeight.toDouble());
  auto('opsz', s.fontSize);
  if (s.italic && !face.italic) {
    if (face.axis('ital') != null) {
      auto('ital', 1);
    } else {
      final slnt = face.axis('slnt');
      if (slnt != null) auto('slnt', slnt.min);
    }
  }
  return out;
}

/// Maps a resolved IR text style to a Flutter [TextStyle] (architecture §7).
///
/// With a [variant] the glyphs are painted for a mask, a stroke or a shadow
/// instead of in the span's own fill colour (see `StageTextVariant`).
TextStyle stageTextStyle(
  ir.TextStyle s,
  StageFontTable fonts, {
  StageTextVariant? variant,
}) {
  final features = fontFeatures(s);
  final face = fonts.faceFor(s.fontFamilyId, s.fontWeight, s.italic);
  final variations = fontVariationsFor(s, face);
  final d = s.decoration;
  final v = variant;
  final decorated =
      d.kind != ir.TextDecorationKind.none && (v?.drawsDecorations ?? true);
  final variantColor = v?.colorFor(s);
  final isStroke = v?.kind == TextVariantKind.stroke;
  // Decorations follow the glyph colour when it is overridden.
  final overridden =
      v != null &&
      variantColor != null &&
      (v.kind != TextVariantKind.base || !isSimpleTextFill(s.fills));
  return TextStyle(
    color: isStroke ? null : (v != null ? variantColor : textColor(s.fills)),
    foreground: isStroke
        ? (Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = v!.width
            ..color = v.color!
            ..strokeJoin = v.join
            ..strokeMiterLimit = v.miterLimit)
        : null,
    fontFamily: face?.name ?? fonts.fallbackFamily(s.fontFamilyId),
    fontSize: s.fontSize,
    fontWeight: face == null
        ? FontWeight(s.fontWeight.clamp(1, 1000))
        : (face.axis('wght') != null
              ? FontWeight.w400
              : FontWeight(face.weight.clamp(1, 1000))),
    fontStyle: (face?.italic ?? s.italic) ? FontStyle.italic : FontStyle.normal,
    letterSpacing: letterSpacingPx(s.letterSpacing, s.fontSize),
    height: lineHeightMultiplier(s.lineHeight, s.fontSize),
    leadingDistribution: TextLeadingDistribution.even,
    textBaseline: TextBaseline.alphabetic,
    fontFeatures: features.isEmpty ? null : features,
    fontVariations: variations.isEmpty ? null : variations,
    decoration: !decorated
        ? TextDecoration.none
        : switch (d.kind) {
            ir.TextDecorationKind.none => TextDecoration.none,
            ir.TextDecorationKind.underline => TextDecoration.underline,
            ir.TextDecorationKind.strikethrough => TextDecoration.lineThrough,
          },
    decorationStyle: decorated
        ? switch (d.style) {
            ir.TextDecorationStyle.solid => TextDecorationStyle.solid,
            ir.TextDecorationStyle.doubleLine => TextDecorationStyle.double,
            ir.TextDecorationStyle.dotted => TextDecorationStyle.dotted,
            ir.TextDecorationStyle.dashed => TextDecorationStyle.dashed,
            ir.TextDecorationStyle.wavy => TextDecorationStyle.wavy,
          }
        : null,
    decorationColor: !decorated
        ? null
        : overridden
        ? variantColor
        : (d.color != null ? stageColor(d.color!) : null),
    decorationThickness: decorated && d.thickness != null && s.fontSize > 0
        ? d.thickness! / (s.fontSize * kAssumedDecorationThicknessEm)
        : null,
  );
}
