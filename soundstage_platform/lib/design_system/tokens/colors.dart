import 'dart:ui';

/// Colour roles for the editor chrome.
///
/// These are the editor's own colours. Story styling uses IR tokens; the two
/// never mix. The palette is deliberately quiet and neutral so the story is
/// the only colourful thing on screen; [accent] is the single hue of the chrome.
class SsColors {
  const SsColors({
    required this.brightness,
    required this.surface0,
    required this.surface1,
    required this.surface2,
    required this.surface3,
    required this.borderSubtle,
    required this.border,
    required this.borderStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textDisabled,
    required this.textOnAccent,
    required this.accent,
    required this.accentHover,
    required this.accentPressed,
    required this.accentText,
    required this.selection,
    required this.danger,
    required this.warning,
    required this.success,
    required this.focusRing,
    required this.hoverLayer,
    required this.pressedLayer,
    required this.scrim,
    this.measure = const Color(0xFFF24822),
    this.spacing = const Color(0xFFE84BC0),
  });

  final Brightness brightness;

  /// Canvas overlay: snapping guides and Alt measurements (Figma's red).
  /// The same in both themes: it sits on the story, not on the chrome.
  final Color measure;

  /// Canvas overlay: smart-spacing (equal gap) markers and auto-layout
  /// padding/gap hints (Figma's pink).
  final Color spacing;

  /// The canvas surround / app background.
  final Color surface0;

  /// Panels, toolbar.
  final Color surface1;

  /// Inputs, raised rows, cards.
  final Color surface2;

  /// Menus, popovers, dialogs, hovered rows.
  final Color surface3;

  final Color borderSubtle;
  final Color border;
  final Color borderStrong;

  final Color textPrimary;
  final Color textSecondary;
  final Color textDisabled;

  /// Text and icons on a solid [accent] fill.
  final Color textOnAccent;

  final Color accent;
  final Color accentHover;
  final Color accentPressed;

  /// The accent as text or an icon on a surface (lighter than [accent] in
  /// the dark theme so it stays legible).
  final Color accentText;

  /// A selected row or range: the accent at low opacity.
  final Color selection;

  final Color danger;
  final Color warning;
  final Color success;

  /// The keyboard-focus ring.
  final Color focusRing;

  /// State layers drawn over a control: hover and pressed.
  final Color hoverLayer;
  final Color pressedLayer;

  /// The barrier behind a modal dialog.
  final Color scrim;

  bool get isDark => brightness == Brightness.dark;

  /// The dark theme: the editor's default.
  static const SsColors dark = SsColors(
    brightness: Brightness.dark,
    surface0: Color(0xFF101012),
    surface1: Color(0xFF18181B),
    surface2: Color(0xFF222226),
    surface3: Color(0xFF2C2C31),
    borderSubtle: Color(0xFF26262B),
    border: Color(0xFF35353B),
    borderStrong: Color(0xFF4F4F58),
    textPrimary: Color(0xFFEDEDF0),
    textSecondary: Color(0xFFA6A6B0),
    textDisabled: Color(0xFF6C6C76),
    textOnAccent: Color(0xFFFFFFFF),
    accent: Color(0xFF2F6FED),
    accentHover: Color(0xFF4A82F0),
    accentPressed: Color(0xFF2559C4),
    accentText: Color(0xFF7FB0FF),
    selection: Color(0x472F6FED),
    danger: Color(0xFFF2646A),
    warning: Color(0xFFE5A82E),
    success: Color(0xFF3FBF7F),
    focusRing: Color(0xFF6FA3FF),
    hoverLayer: Color(0x0FFFFFFF),
    pressedLayer: Color(0x1AFFFFFF),
    scrim: Color(0xA6000000),
  );

  /// The light theme (tokens only; the editor ships dark by default).
  static const SsColors light = SsColors(
    brightness: Brightness.light,
    surface0: Color(0xFFF0F0F3),
    surface1: Color(0xFFFFFFFF),
    surface2: Color(0xFFF5F5F7),
    surface3: Color(0xFFEAEAEE),
    borderSubtle: Color(0xFFE6E6EA),
    border: Color(0xFFD4D4DA),
    borderStrong: Color(0xFF9A9AA4),
    textPrimary: Color(0xFF18181B),
    textSecondary: Color(0xFF55555F),
    textDisabled: Color(0xFF8E8E98),
    textOnAccent: Color(0xFFFFFFFF),
    accent: Color(0xFF2F6FED),
    accentHover: Color(0xFF2559C4),
    accentPressed: Color(0xFF1D479C),
    accentText: Color(0xFF2559C4),
    selection: Color(0x292F6FED),
    danger: Color(0xFFD1343B),
    warning: Color(0xFF9A6A00),
    success: Color(0xFF1F8A54),
    focusRing: Color(0xFF2F6FED),
    hoverLayer: Color(0x0F000000),
    pressedLayer: Color(0x1A000000),
    scrim: Color(0x66000000),
  );

  /// WCAG 2.x contrast ratio between two opaque colours.
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }
}
