import 'package:freezed_annotation/freezed_annotation.dart';

part 'stage_color.freezed.dart';
part 'stage_color.g.dart';

/// An sRGB colour with components in 0–1 (architecture §3).
@freezed
abstract class StageColor with _$StageColor {
  const factory StageColor({
    required double r,
    required double g,
    required double b,
    @Default(1) double a,
  }) = _StageColor;

  const StageColor._();

  /// Parses `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA` (alpha last, as in CSS).
  /// The leading `#` is optional.
  factory StageColor.fromHex(String hex) {
    var h = hex.trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length == 3 || h.length == 4) {
      h = h.split('').map((c) => '$c$c').join();
    }
    if ((h.length != 6 && h.length != 8) ||
        !RegExp(r'^[0-9a-fA-F]+$').hasMatch(h)) {
      throw FormatException('Not a hex colour', hex);
    }
    double channel(int i) => int.parse(h.substring(i, i + 2), radix: 16) / 255;
    return StageColor(
      r: channel(0),
      g: channel(2),
      b: channel(4),
      a: h.length == 8 ? channel(6) : 1,
    );
  }

  factory StageColor.fromJson(Map<String, dynamic> json) =>
      _$StageColorFromJson(json);

  static const StageColor black = StageColor(r: 0, g: 0, b: 0);
  static const StageColor white = StageColor(r: 1, g: 1, b: 1);
  static const StageColor transparent = StageColor(r: 0, g: 0, b: 0, a: 0);

  /// `#rrggbb`, or `#rrggbbaa` when not fully opaque. Components are rounded
  /// to 8 bits, so `fromHex(toHex())` is exact only for 8-bit colours.
  String toHex({bool includeAlpha = false}) {
    String c(double v) =>
        (v.clamp(0.0, 1.0) * 255).round().toRadixString(16).padLeft(2, '0');
    final rgb = '#${c(r)}${c(g)}${c(b)}';
    return includeAlpha || a < 1 ? '$rgb${c(a)}' : rgb;
  }

  /// This colour with alpha replaced.
  StageColor withAlpha(double alpha) => copyWith(a: alpha);
}
