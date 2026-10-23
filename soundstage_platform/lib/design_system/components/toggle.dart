import 'package:flutter/material.dart';

import '../icons/ss_icons.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'icon.dart';
import 'interactive.dart';

/// A switch: an on/off setting that takes effect immediately.
class SsToggle extends StatelessWidget {
  const SsToggle({
    required this.value,
    required this.onChanged,
    this.label,
    this.semanticLabel,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Visible label to the right of the switch.
  final String? label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return SsInteractive(
      enabled: onChanged != null,
      selected: value,
      semanticLabel: semanticLabel ?? label,
      semanticValue: value ? 'On' : 'Off',
      excludeSemantics: true,
      onTap: () => onChanged?.call(!value),
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final hover = s.contains(WidgetState.hovered);
        final track = disabled
            ? c.surface3
            : value
            ? (hover ? c.accentHover : c.accent)
            : (hover ? c.borderStrong : c.border);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsFocusRing(
              visible: s.contains(WidgetState.focused),
              color: c.focusRing,
              borderRadius: SsRadius.brLg,
              child: AnimatedContainer(
                duration: SsMotion.base,
                curve: SsMotion.easeOut,
                width: 28,
                height: 16,
                padding: const EdgeInsets.all(2),
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                decoration: BoxDecoration(
                  color: track,
                  borderRadius: SsRadius.brLg,
                ),
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: disabled ? c.textDisabled : const Color(0xFFFFFFFF),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
            if (label != null) ...[
              const SizedBox(width: SsSpace.s2),
              Text(
                label!,
                style: t.text.body.copyWith(
                  color: disabled ? c.textDisabled : c.textPrimary,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A checkbox. [value] null is the indeterminate ("mixed") state.
class SsCheckbox extends StatelessWidget {
  const SsCheckbox({
    required this.value,
    required this.onChanged,
    this.label,
    this.semanticLabel,
    super.key,
  });

  /// true, false, or null for mixed.
  final bool? value;
  final ValueChanged<bool>? onChanged;
  final String? label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return SsInteractive(
      enabled: onChanged != null,
      selected: value ?? false,
      semanticLabel: semanticLabel ?? label,
      semanticValue: value == null
          ? 'Mixed'
          : (value! ? 'Checked' : 'Unchecked'),
      excludeSemantics: true,
      // Mixed resolves to checked, like native checkboxes.
      onTap: () => onChanged?.call(value != true),
      builder: (context, s) {
        final disabled = s.contains(WidgetState.disabled);
        final hover = s.contains(WidgetState.hovered);
        final filled = value != false;
        final bg = !filled
            ? (hover ? c.surface3 : c.surface2)
            : disabled
            ? c.surface3
            : (hover ? c.accentHover : c.accent);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SsFocusRing(
              visible: s.contains(WidgetState.focused),
              color: c.focusRing,
              borderRadius: SsRadius.brSm,
              child: AnimatedContainer(
                duration: SsMotion.fast,
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: SsRadius.brSm,
                  border: Border.all(
                    color: filled ? bg : (disabled ? c.border : c.borderStrong),
                  ),
                ),
                child: filled
                    ? Center(
                        child: SsIcon(
                          value == null ? SsIcons.minus : SsIcons.check,
                          size: 12,
                          color: disabled ? c.textDisabled : c.textOnAccent,
                        ),
                      )
                    : null,
              ),
            ),
            if (label != null) ...[
              const SizedBox(width: SsSpace.s2),
              Text(
                label!,
                style: t.text.body.copyWith(
                  color: disabled ? c.textDisabled : c.textPrimary,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
