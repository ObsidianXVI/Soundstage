import 'package:flutter/painting.dart';

/// The editor's UI font: Inter, bundled locally (SIL OFL 1.1). Never fetched
/// at runtime.
const String kSsUiFont = 'Inter';

/// The chrome type scale: sizes 11/12/13/14/16/20 with explicit line heights.
///
/// Inter is a variable font; the weight is applied through both
/// [FontWeight] and the `wght` axis so every renderer picks it up.
class SsTypeScale {
  const SsTypeScale._(this._color, this._secondary);

  /// The scale in [primary] text colour, with [secondary] for muted text.
  factory SsTypeScale.of({required Color primary, required Color secondary}) =>
      SsTypeScale._(primary, secondary);

  final Color _color;
  final Color _secondary;

  static TextStyle _style(
    double size,
    double lineHeight,
    int weight,
    Color color, {
    double letterSpacing = 0,
    bool tabular = false,
  }) {
    return TextStyle(
      fontFamily: kSsUiFont,
      fontSize: size,
      height: lineHeight / size,
      fontWeight: FontWeight.values[(weight ~/ 100) - 1],
      fontVariations: <FontVariation>[FontVariation('wght', weight.toDouble())],
      fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
      letterSpacing: letterSpacing,
      color: color,
      decoration: TextDecoration.none,
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// 11 / 16: captions, shortcut hints, badges.
  TextStyle get caption => _style(11, 16, 400, _secondary, letterSpacing: 0.1);

  /// 11 / 16, medium, uppercase section labels.
  TextStyle get overline => _style(11, 16, 600, _secondary, letterSpacing: 0.6);

  /// 12 / 16: secondary UI text.
  TextStyle get small => _style(12, 16, 400, _color);

  /// 12 / 16, tabular figures: number fields and readouts.
  TextStyle get numeric => _style(12, 16, 400, _color, tabular: true);

  /// 13 / 20: the default UI text.
  TextStyle get body => _style(13, 20, 400, _color);

  /// 13 / 20, medium.
  TextStyle get bodyStrong => _style(13, 20, 550, _color);

  /// 14 / 20: prominent UI text, dialog body.
  TextStyle get large => _style(14, 20, 400, _color);

  /// 16 / 24: dialog and page titles.
  TextStyle get title => _style(16, 24, 600, _color, letterSpacing: -0.1);

  /// 20 / 28: the largest chrome heading.
  TextStyle get heading => _style(20, 28, 650, _color, letterSpacing: -0.2);
}
