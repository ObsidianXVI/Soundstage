import 'package:freezed_annotation/freezed_annotation.dart';

/// Blend modes (architecture §5). Serialised by name; part of the file format.
@JsonEnum()
enum BlendMode {
  normal,

  /// Frames only: children blend with what is behind the frame, as in Figma.
  passThrough,
  darken,
  multiply,
  colorBurn,
  lighten,
  screen,
  colorDodge,
  overlay,
  softLight,
  hardLight,
  difference,
  exclusion,
  hue,
  saturation,
  color,
  luminosity,
}
