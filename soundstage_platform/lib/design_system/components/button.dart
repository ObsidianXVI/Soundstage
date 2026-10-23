import 'package:flutter/material.dart';

import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'icon.dart';
import 'interactive.dart';
import 'tooltip.dart';

/// Visual weight of an [SsButton].
enum SsButtonVariant { primary, secondary, ghost, danger }

/// A text button with optional leading icon.
class SsButton extends StatelessWidget {
  const SsButton({
    required this.label,
    this.onPressed,
    this.variant = SsButtonVariant.secondary,
    this.icon,
    this.autofocus = false,
    this.focusNode,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final SsButtonVariant variant;
  final IconData? icon;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return SsInteractive(
      onTap: onPressed,
      enabled: onPressed != null,
      semanticLabel: label,
      excludeSemantics: true,
      autofocus: autofocus,
      focusNode: focusNode,
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final hover = s.contains(WidgetState.hovered);
        final press = s.contains(WidgetState.pressed);
        Color bg;
        Color fg;
        Color? border;
        switch (variant) {
          case SsButtonVariant.primary:
            bg = disabled
                ? c.surface3
                : press
                ? c.accentPressed
                : hover
                ? c.accentHover
                : c.accent;
            fg = disabled ? c.textDisabled : c.textOnAccent;
          case SsButtonVariant.danger:
            bg = disabled
                ? c.surface3
                : Color.alphaBlend(
                    press
                        ? c.pressedLayer
                        : hover
                        ? c.hoverLayer
                        : const Color(0x00000000),
                    c.danger,
                  );
            fg = disabled ? c.textDisabled : const Color(0xFF1A0808);
          case SsButtonVariant.secondary:
            bg = Color.alphaBlend(
              press
                  ? c.pressedLayer
                  : hover
                  ? c.hoverLayer
                  : const Color(0x00000000),
              c.surface2,
            );
            fg = disabled ? c.textDisabled : c.textPrimary;
            border = c.border;
          case SsButtonVariant.ghost:
            bg = press
                ? c.pressedLayer
                : hover
                ? c.hoverLayer
                : const Color(0x00000000);
            fg = disabled ? c.textDisabled : c.textPrimary;
        }
        return SsFocusRing(
          visible: s.contains(WidgetState.focused),
          color: c.focusRing,
          borderRadius: SsRadius.brMd,
          child: AnimatedContainer(
            duration: SsMotion.fast,
            height: SsSpace.controlHeight,
            padding: const EdgeInsets.symmetric(horizontal: SsSpace.s3),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: SsRadius.brMd,
              border: border == null ? null : Border.all(color: border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  SsIcon(icon!, size: 14, color: fg),
                  const SizedBox(width: SsSpace.s2),
                ],
                Text(label, style: t.text.bodyStrong.copyWith(color: fg)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A square icon-only button. [semanticLabel] is required: it names the
/// button for assistive tech and is the default tooltip.
class SsIconButton extends StatelessWidget {
  const SsIconButton({
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.selected = false,
    this.size = SsSpace.hitTarget,
    this.iconSize = 16,
    this.tooltip,
    this.shortcut,
    this.focusNode,
    this.autofocus = false,
    super.key,
  });

  final IconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;

  /// A toggled-on tool (selected-tool, panel open).
  final bool selected;
  final double size;
  final double iconSize;

  /// Overrides the tooltip text (defaults to [semanticLabel]).
  final String? tooltip;

  /// Shortcut hint shown in the tooltip.
  final String? shortcut;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return SsTooltip(
      message: tooltip ?? semanticLabel,
      shortcut: shortcut,
      child: SsInteractive(
        onTap: onPressed,
        enabled: onPressed != null,
        selected: selected,
        semanticLabel: semanticLabel,
        excludeSemantics: true,
        focusNode: focusNode,
        autofocus: autofocus,
        builder: (context, s) {
          final disabled = s.contains(WidgetState.disabled);
          final bg = selected
              ? c.selection
              : s.contains(WidgetState.pressed)
              ? c.pressedLayer
              : s.contains(WidgetState.hovered)
              ? c.hoverLayer
              : const Color(0x00000000);
          final fg = disabled
              ? c.textDisabled
              : selected
              ? c.accentText
              : c.textSecondary;
          return SsFocusRing(
            visible: s.contains(WidgetState.focused),
            color: c.focusRing,
            borderRadius: SsRadius.brMd,
            child: AnimatedContainer(
              duration: SsMotion.fast,
              width: size,
              height: size,
              decoration: BoxDecoration(color: bg, borderRadius: SsRadius.brMd),
              child: Center(
                child: SsIcon(icon, size: iconSize, color: fg),
              ),
            ),
          );
        },
      ),
    );
  }
}
