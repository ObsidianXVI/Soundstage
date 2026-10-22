import 'package:soundstage_platform/ir/ir.dart' as ir;

/// Maps a text style's `fontFamilyId` to the family name text is laid out
/// with (architecture §7, §12).
///
/// T0.4 only maps names: a family whose bytes are not loaded renders in the
/// platform's default font, which stands in for every generic fallback until
/// T0.7 loads font files with `FontLoader` and relays text out.
class StageFontTable {
  const StageFontTable([this.families = const {}]);

  /// The document's font table.
  factory StageFontTable.fromDocument(ir.StageDocument doc) =>
      StageFontTable(doc.fonts);

  final Map<String, ir.FontFamily> families;

  /// The family name for [fontFamilyId]; null (the default font) when the id
  /// is null or unknown.
  String? familyName(String? fontFamilyId) =>
      fontFamilyId == null ? null : families[fontFamilyId]?.name;

  /// The generic fallback of [fontFamilyId] (sans when unknown).
  ir.FontFallback fallback(String? fontFamilyId) =>
      (fontFamilyId == null ? null : families[fontFamilyId]?.fallback) ??
      ir.FontFallback.sans;
}
