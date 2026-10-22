import 'package:freezed_annotation/freezed_annotation.dart';

import '../values/stage_color.dart';
import 'paint.dart';

part 'text.freezed.dart';
part 'text.g.dart';

@JsonEnum()
enum TextAutoResize { widthAndHeight, height, fixed, truncate }

@JsonEnum()
enum TextTruncation { none, ending }

@JsonEnum()
enum TextAlignHorizontal { left, center, right, justified }

@JsonEnum()
enum TextAlignVertical { top, middle, bottom }

@JsonEnum()
enum LeadingTrim { none, capHeight }

@JsonEnum()
enum TextCase { none, upper, lower, title, smallCaps, smallCapsForced }

@JsonEnum()
enum TextDecorationKind { none, underline, strikethrough }

@JsonEnum()
enum TextDecorationStyle {
  solid,
  @JsonValue('double')
  doubleLine,
  dotted,
  dashed,
  wavy,
}

@JsonEnum()
enum BaselineShift { none, superscript, subscript }

@JsonEnum()
enum ListStyle { none, ordered, unordered }

/// Line height (architecture §7).
@Freezed(unionKey: 'type')
sealed class LineHeight with _$LineHeight {
  /// The font's natural line height.
  @FreezedUnionValue('auto')
  const factory LineHeight.auto() = AutoLineHeight;

  @FreezedUnionValue('px')
  const factory LineHeight.px(double value) = PxLineHeight;

  /// Percent of the font size (100 = 1.0).
  @FreezedUnionValue('percent')
  const factory LineHeight.percent(double value) = PercentLineHeight;

  factory LineHeight.fromJson(Map<String, dynamic> json) =>
      _$LineHeightFromJson(json);
}

/// Letter spacing (architecture §7).
@Freezed(unionKey: 'type')
sealed class LetterSpacing with _$LetterSpacing {
  @FreezedUnionValue('px')
  const factory LetterSpacing.px(double value) = PxLetterSpacing;

  /// Percent of the font size.
  @FreezedUnionValue('percent')
  const factory LetterSpacing.percent([@Default(0) double value]) =
      PercentLetterSpacing;

  factory LetterSpacing.fromJson(Map<String, dynamic> json) =>
      _$LetterSpacingFromJson(json);
}

/// Text decoration. Null `thickness` = the font's default ("auto"); null
/// `color` = the text's own fill.
@freezed
abstract class TextDecoration with _$TextDecoration {
  const factory TextDecoration({
    @Default(TextDecorationKind.none) TextDecorationKind kind,
    @Default(TextDecorationStyle.solid) TextDecorationStyle style,
    double? thickness,
    StageColor? color,
    @Default(true) bool skipInk,
  }) = _TextDecoration;

  factory TextDecoration.fromJson(Map<String, dynamic> json) =>
      _$TextDecorationFromJson(json);
}

/// The default text fill: opaque black.
const List<Paint> kDefaultTextFills = <Paint>[
  Paint.solid(id: 'text', color: StageColor.black),
];

/// A complete text style (architecture §7).
///
/// - `fontFamilyId`: a key of `StageDocument.fonts`; null = the runtime's
///   default sans.
/// - `fontVariations`: `{ axisTag: value }`.
/// - `openType`: `{ featureTag: value }` — 0 = off, 1 = on, n = alternate.
/// - `listStyle`: paragraph level.
@freezed
abstract class TextStyle with _$TextStyle {
  const factory TextStyle({
    String? fontFamilyId,
    @Default(400) int fontWeight,
    @Default(false) bool italic,
    @Default(<String, double>{}) Map<String, double> fontVariations,
    @Default(16) double fontSize,
    @Default(LineHeight.auto()) LineHeight lineHeight,
    @Default(LetterSpacing.percent()) LetterSpacing letterSpacing,
    @Default(0) double paragraphSpacing,
    @Default(0) double paragraphIndent,
    @Default(TextCase.none) TextCase textCase,
    @Default(TextDecoration()) TextDecoration decoration,
    @Default(kDefaultTextFills) List<Paint> fills,
    @Default(<String, int>{}) Map<String, int> openType,
    @Default(BaselineShift.none) BaselineShift baselineShift,
    @Default(ListStyle.none) ListStyle listStyle,
  }) = _TextStyle;

  factory TextStyle.fromJson(Map<String, dynamic> json) =>
      _$TextStyleFromJson(json);
}

/// A partial [TextStyle]: every field is nullable; null = inherit.
/// Span overrides win over paragraph style, named style and node style.
@freezed
abstract class TextStyleOverride with _$TextStyleOverride {
  const factory TextStyleOverride({
    String? fontFamilyId,
    int? fontWeight,
    bool? italic,
    Map<String, double>? fontVariations,
    double? fontSize,
    LineHeight? lineHeight,
    LetterSpacing? letterSpacing,
    double? paragraphSpacing,
    double? paragraphIndent,
    TextCase? textCase,
    TextDecoration? decoration,
    List<Paint>? fills,
    Map<String, int>? openType,
    BaselineShift? baselineShift,
    ListStyle? listStyle,
  }) = _TextStyleOverride;

  factory TextStyleOverride.fromJson(Map<String, dynamic> json) =>
      _$TextStyleOverrideFromJson(json);
}

/// Paragraph-level overrides; null = inherit from the node.
@freezed
abstract class ParagraphStyle with _$ParagraphStyle {
  const factory ParagraphStyle({
    TextAlignHorizontal? alignHorizontal,
    double? paragraphSpacing,
    double? paragraphIndent,
    ListStyle? listStyle,
  }) = _ParagraphStyle;

  factory ParagraphStyle.fromJson(Map<String, dynamic> json) =>
      _$ParagraphStyleFromJson(json);
}

/// A hyperlink on a span: an external URL or another scene in the story
/// (Figma links to a URL or a node).
@Freezed(unionKey: 'type')
sealed class SpanLink with _$SpanLink {
  @FreezedUnionValue('url')
  const factory SpanLink.url(String url, {@Default(true) bool newTab}) =
      UrlLink;

  @FreezedUnionValue('scene')
  const factory SpanLink.scene(String sceneId) = SceneLink;

  factory SpanLink.fromJson(Map<String, dynamic> json) =>
      _$SpanLinkFromJson(json);
}

/// A run of text with one style.
@freezed
abstract class Span with _$Span {
  const factory Span({
    required String text,
    @Default(TextStyleOverride()) TextStyleOverride style,
    SpanLink? link,
  }) = _Span;

  factory Span.fromJson(Map<String, dynamic> json) => _$SpanFromJson(json);
}

@freezed
abstract class Paragraph with _$Paragraph {
  const factory Paragraph({
    @Default(<Span>[]) List<Span> spans,
    ParagraphStyle? style,
  }) = _Paragraph;

  factory Paragraph.fromJson(Map<String, dynamic> json) =>
      _$ParagraphFromJson(json);
}
