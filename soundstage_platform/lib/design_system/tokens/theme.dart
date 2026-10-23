import 'package:flutter/material.dart';

import 'colors.dart';
import 'typography.dart';

/// The resolved editor-chrome theme: colour roles plus the type scale.
@immutable
class SsThemeData {
  SsThemeData({required this.colors})
    : text = SsTypeScale.of(
        primary: colors.textPrimary,
        secondary: colors.textSecondary,
      );

  /// The dark theme: the editor's default.
  factory SsThemeData.dark() => SsThemeData(colors: SsColors.dark);

  /// The light theme.
  factory SsThemeData.light() => SsThemeData(colors: SsColors.light);

  final SsColors colors;
  final SsTypeScale text;

  /// A Material [ThemeData] consistent with this theme, so Material widgets
  /// used inside the chrome (text selection, scrollbars) match.
  ThemeData toMaterial() {
    return ThemeData(
      useMaterial3: true,
      brightness: colors.brightness,
      fontFamily: kSsUiFont,
      scaffoldBackgroundColor: colors.surface0,
      canvasColor: colors.surface1,
      colorScheme: ColorScheme(
        brightness: colors.brightness,
        primary: colors.accent,
        onPrimary: colors.textOnAccent,
        secondary: colors.accent,
        onSecondary: colors.textOnAccent,
        error: colors.danger,
        onError: colors.textOnAccent,
        surface: colors.surface1,
        onSurface: colors.textPrimary,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.accentText,
        selectionColor: colors.selection,
        selectionHandleColor: colors.accentText,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStatePropertyAll<Color>(colors.borderStrong),
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SsThemeData && other.colors == colors;

  @override
  int get hashCode => colors.hashCode;
}

/// Provides [SsThemeData] to the chrome below it.
class SsTheme extends InheritedWidget {
  const SsTheme({required this.data, required super.child, super.key});

  final SsThemeData data;

  /// The nearest theme. Falls back to the dark theme when there is none, so
  /// a component never fails to build outside a scope.
  static SsThemeData of(BuildContext context) {
    final t = context.dependOnInheritedWidgetOfExactType<SsTheme>();
    return t?.data ?? _fallback;
  }

  static final SsThemeData _fallback = SsThemeData.dark();

  @override
  bool updateShouldNotify(SsTheme oldWidget) => data != oldWidget.data;
}

/// Roots the editor chrome: provides [SsTheme], a transparent Material for
/// widgets that need one, the default text style and icon theme.
class SsScope extends StatelessWidget {
  const SsScope({required this.child, this.theme, super.key});

  final SsThemeData? theme;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final data = theme ?? SsTheme.of(context);
    return SsTheme(
      data: data,
      child: Theme(
        data: data.toMaterial(),
        child: Material(
          type: MaterialType.transparency,
          child: DefaultTextStyle(
            style: data.text.body,
            child: IconTheme(
              data: IconThemeData(color: data.colors.textSecondary, size: 16),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Shorthand: `context.ss` is the nearest [SsThemeData].
extension SsThemeContext on BuildContext {
  SsThemeData get ss => SsTheme.of(this);
}
