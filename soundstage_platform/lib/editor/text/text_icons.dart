import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

/// Lucide icons for the text inspector (lucide-static 1.61.0, the bundled
/// font; codepoints from its `codepoints.json`). Kept beside the text
/// editor rather than in the generated `SsIcons` so parallel work does not
/// regenerate that file; fold them into `tool/gen_lucide_icons.dart` later.
abstract final class TextIcons {
  static const IconData alignLeft = IconData(
    0xe185,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData alignCenter = IconData(
    0xe182,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData alignRight = IconData(
    0xe183,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData alignJustify = IconData(
    0xe184,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData alignTop = IconData(
    0xe279,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData alignMiddle = IconData(
    0xe277,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData alignBottom = IconData(
    0xe278,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData bold = IconData(0xe05d, fontFamily: SsIcons.fontFamily);
  static const IconData italic = IconData(
    0xe0fb,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData underline = IconData(
    0xe19a,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData strikethrough = IconData(
    0xe177,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData list = IconData(0xe106, fontFamily: SsIcons.fontFamily);
  static const IconData listOrdered = IconData(
    0xe1d1,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData caseSensitive = IconData(
    0xe3d9,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData baseline = IconData(
    0xe285,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData superscript = IconData(
    0xe25e,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData subscript = IconData(
    0xe25c,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData pilcrow = IconData(
    0xe3a3,
    fontFamily: SsIcons.fontFamily,
  );
  static const IconData indent = IconData(
    0xe108,
    fontFamily: SsIcons.fontFamily,
  );
}
