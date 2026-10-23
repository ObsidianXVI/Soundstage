import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/ss_icons.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'icon.dart';
import 'popover.dart';

/// An entry in an [SsMenu].
sealed class SsMenuEntry {
  const SsMenuEntry();
}

/// A selectable command.
class SsMenuItem extends SsMenuEntry {
  const SsMenuItem({
    required this.label,
    this.onSelected,
    this.icon,
    this.shortcut,
    this.enabled = true,
    this.danger = false,
    this.checked,
  });

  final String label;
  final VoidCallback? onSelected;
  final IconData? icon;

  /// Display text for the shortcut (e.g. `⌘D`).
  final String? shortcut;
  final bool enabled;
  final bool danger;

  /// Shows a check mark when true (and reserves the space when non-null).
  final bool? checked;

  bool get isSelectable => enabled && onSelected != null;
}

/// A separator line.
class SsMenuDivider extends SsMenuEntry {
  const SsMenuDivider();
}

/// A non-interactive group label.
class SsMenuLabel extends SsMenuEntry {
  const SsMenuLabel(this.text);
  final String text;
}

/// Opens a menu of [entries] next to [anchor] (a global rectangle).
///
/// Up/Down/Home/End move, Enter and Space select, Escape closes. The chosen
/// item's callback runs after the menu has closed.
SsPopoverHandle showSsMenu(
  BuildContext context, {
  required Rect anchor,
  required List<SsMenuEntry> entries,
  SsPlacement placement = SsPlacement.belowStart,
  bool matchAnchorWidth = false,
  double minWidth = 180,
  VoidCallback? onClosed,
}) {
  late SsPopoverHandle handle;
  handle = showSsPopover(
    context,
    anchor: anchor,
    placement: placement,
    matchAnchorWidth: matchAnchorWidth,
    onClosed: onClosed,
    builder: (_) => SsMenu(
      entries: entries,
      minWidth: minWidth,
      onSelected: (item) {
        handle.close();
        item.onSelected?.call();
      },
    ),
  );
  return handle;
}

/// Opens a context menu at the global [position].
SsPopoverHandle showSsContextMenu(
  BuildContext context, {
  required Offset position,
  required List<SsMenuEntry> entries,
}) {
  return showSsMenu(
    context,
    anchor: position & Size.zero,
    entries: entries,
    placement: SsPlacement.pointer,
  );
}

/// Shows a context menu on secondary click or long press over [child].
class SsContextMenuRegion extends StatelessWidget {
  const SsContextMenuRegion({
    required this.entries,
    required this.child,
    super.key,
  });

  final List<SsMenuEntry> Function() entries;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapDown: (d) => showSsContextMenu(
        context,
        position: d.globalPosition,
        entries: entries(),
      ),
      onLongPressStart: (d) => showSsContextMenu(
        context,
        position: d.globalPosition,
        entries: entries(),
      ),
      child: child,
    );
  }
}

/// The menu list itself (also used by the dropdown).
class SsMenu extends StatefulWidget {
  const SsMenu({
    required this.entries,
    required this.onSelected,
    this.minWidth = 180,
    this.semanticLabel,
    super.key,
  });

  final List<SsMenuEntry> entries;
  final ValueChanged<SsMenuItem> onSelected;
  final double minWidth;
  final String? semanticLabel;

  @override
  State<SsMenu> createState() => _SsMenuState();
}

class _SsMenuState extends State<SsMenu> {
  late int _highlight = _first();
  final FocusNode _focus = FocusNode(debugLabel: 'SsMenu');

  bool _selectable(int i) {
    final e = widget.entries[i];
    return e is SsMenuItem && e.isSelectable;
  }

  int _first() {
    for (var i = 0; i < widget.entries.length; i++) {
      if (_selectable(i)) return i;
    }
    return -1;
  }

  int _step(int from, int dir) {
    final n = widget.entries.length;
    if (n == 0) return -1;
    var i = from;
    for (var k = 0; k < n; k++) {
      i = (i + dir + n) % n;
      if (_selectable(i)) return i;
    }
    return from;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = _step(_highlight, 1));
    } else if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight = _step(_highlight, -1));
    } else if (key == LogicalKeyboardKey.home) {
      setState(() => _highlight = _first());
    } else if (key == LogicalKeyboardKey.end) {
      setState(() {
        _highlight = _step(0, -1);
      });
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space) {
      if (_highlight >= 0 && _selectable(_highlight)) {
        widget.onSelected(widget.entries[_highlight] as SsMenuItem);
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final hasCheck = widget.entries.any(
      (e) => e is SsMenuItem && e.checked != null,
    );
    return SsPopoverSurface(
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: widget.minWidth),
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Semantics(
            container: true,
            label: widget.semanticLabel ?? 'Menu',
            child: IntrinsicWidth(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < widget.entries.length; i++)
                      switch (widget.entries[i]) {
                        SsMenuDivider() => Container(
                          height: 1,
                          margin: const EdgeInsets.symmetric(
                            vertical: SsSpace.s1,
                            horizontal: SsSpace.s1,
                          ),
                          color: t.colors.border,
                        ),
                        SsMenuLabel(:final text) => Padding(
                          padding: const EdgeInsets.fromLTRB(
                            SsSpace.s2,
                            SsSpace.s2,
                            SsSpace.s2,
                            SsSpace.s1,
                          ),
                          child: Text(text, style: t.text.overline),
                        ),
                        final SsMenuItem item => _MenuRow(
                          item: item,
                          highlighted: i == _highlight,
                          reserveCheck: hasCheck,
                          onHover: () {
                            if (item.isSelectable && _highlight != i) {
                              setState(() => _highlight = i);
                            }
                          },
                          onTap: () => widget.onSelected(item),
                        ),
                      },
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.item,
    required this.highlighted,
    required this.reserveCheck,
    required this.onHover,
    required this.onTap,
  });

  final SsMenuItem item;
  final bool highlighted;
  final bool reserveCheck;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final enabled = item.isSelectable;
    final fg = !enabled
        ? c.textDisabled
        : item.danger
        ? c.danger
        : c.textPrimary;
    return Semantics(
      button: true,
      enabled: enabled,
      checked: item.checked,
      label: item.label,
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: MouseRegion(
        onHover: (_) => onHover(),
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: SsMotion.instant,
            height: SsSpace.controlHeight,
            padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
            decoration: BoxDecoration(
              color: highlighted ? c.pressedLayer : const Color(0x00000000),
              borderRadius: SsRadius.brSm,
            ),
            child: Row(
              children: [
                if (reserveCheck)
                  SizedBox(
                    width: 20,
                    child: item.checked == true
                        ? SsIcon(SsIcons.check, size: 14, color: fg)
                        : null,
                  ),
                if (item.icon != null) ...[
                  SsIcon(item.icon!, size: 14, color: fg),
                  const SizedBox(width: SsSpace.s2),
                ],
                Expanded(
                  child: Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.text.body.copyWith(color: fg),
                  ),
                ),
                if (item.shortcut != null) ...[
                  const SizedBox(width: SsSpace.s6),
                  Text(
                    item.shortcut!,
                    style: t.text.caption.copyWith(
                      color: enabled ? c.textSecondary : c.textDisabled,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
