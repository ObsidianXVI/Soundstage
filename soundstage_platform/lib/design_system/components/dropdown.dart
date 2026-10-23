import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/ss_icons.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'icon.dart';
import 'interactive.dart';
import 'menu.dart';
import 'popover.dart';

/// One choice in an [SsDropdown].
class SsDropdownItem<T> {
  const SsDropdownItem({required this.value, required this.label, this.icon});

  final T value;
  final String label;
  final IconData? icon;
}

/// A select: a field that opens a list of choices.
///
/// Enter, Space and Arrow Down open it; the list supports arrow keys.
/// [mixed] shows "Mixed" when a multi-selection disagrees.
class SsDropdown<T> extends StatefulWidget {
  const SsDropdown({
    required this.items,
    required this.onChanged,
    this.value,
    this.hint = 'Select',
    this.mixed = false,
    this.enabled = true,
    this.semanticLabel,
    this.width,
    super.key,
  });

  final List<SsDropdownItem<T>> items;
  final T? value;
  final ValueChanged<T>? onChanged;
  final String hint;
  final bool mixed;
  final bool enabled;
  final String? semanticLabel;
  final double? width;

  @override
  State<SsDropdown<T>> createState() => _SsDropdownState<T>();
}

class _SsDropdownState<T> extends State<SsDropdown<T>> {
  SsPopoverHandle? _handle;
  bool _open = false;

  void _toggle() {
    if (_handle?.isOpen ?? false) {
      _handle!.close();
      return;
    }
    setState(() => _open = true);
    _handle = showSsMenu(
      context,
      anchor: ssGlobalRect(context),
      matchAnchorWidth: true,
      minWidth: 120,
      onClosed: () {
        if (mounted) setState(() => _open = false);
      },
      entries: [
        for (final item in widget.items)
          SsMenuItem(
            label: item.label,
            icon: item.icon,
            checked: !widget.mixed && item.value == widget.value,
            onSelected: () => widget.onChanged?.call(item.value),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _handle?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    SsDropdownItem<T>? selected;
    for (final i in widget.items) {
      if (i.value == widget.value) selected = i;
    }
    final text = widget.mixed ? 'Mixed' : selected?.label ?? widget.hint;
    final muted = widget.mixed || selected == null;
    final enabled = widget.enabled && widget.onChanged != null;
    return SizedBox(
      width: widget.width,
      child: SsInteractive(
        enabled: enabled,
        onTap: _toggle,
        semanticLabel: widget.semanticLabel,
        semanticValue: text,
        semanticHint: 'Opens a list of options',
        excludeSemantics: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.arrowDown &&
              enabled) {
            _toggle();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        builder: (context, s) {
          final hover = s.contains(WidgetState.hovered);
          final focused = s.contains(WidgetState.focused);
          return AnimatedContainer(
            duration: SsMotion.fast,
            height: SsSpace.controlHeight,
            padding: const EdgeInsets.only(left: SsSpace.s2, right: SsSpace.s1),
            decoration: BoxDecoration(
              color: !enabled
                  ? c.surface1
                  : hover || _open
                  ? Color.alphaBlend(c.hoverLayer, c.surface2)
                  : c.surface2,
              borderRadius: SsRadius.brMd,
              border: Border.all(
                color: focused
                    ? c.focusRing
                    : _open
                    ? c.accent
                    : c.border,
                width: focused ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                if (selected?.icon != null && !widget.mixed) ...[
                  SsIcon(selected!.icon!, size: 14),
                  const SizedBox(width: SsSpace.s2),
                ],
                Expanded(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.text.body.copyWith(
                      color: !enabled
                          ? c.textDisabled
                          : muted
                          ? c.textSecondary
                          : c.textPrimary,
                    ),
                  ),
                ),
                SsIcon(
                  SsIcons.chevronDown,
                  size: 14,
                  color: enabled ? c.textSecondary : c.textDisabled,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
