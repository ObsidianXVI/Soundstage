import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'icon.dart';
import 'interactive.dart';

/// One tab of an [SsTabs].
class SsTab {
  const SsTab({required this.id, required this.label, this.icon});

  final String id;
  final String label;
  final IconData? icon;
}

/// A tab strip. Each tab is focusable; Left/Right/Home/End move and select.
/// Pair with [SsTabPanel] for the content.
class SsTabs extends StatefulWidget {
  const SsTabs({
    required this.tabs,
    required this.selectedId,
    required this.onChanged,
    this.trailing,
    super.key,
  });

  final List<SsTab> tabs;
  final String selectedId;
  final ValueChanged<String> onChanged;

  /// Widgets at the end of the strip (e.g. a panel's actions).
  final Widget? trailing;

  @override
  State<SsTabs> createState() => _SsTabsState();
}

class _SsTabsState extends State<SsTabs> {
  late List<FocusNode> _nodes = _make();

  List<FocusNode> _make() => [
    for (var i = 0; i < widget.tabs.length; i++)
      FocusNode(debugLabel: 'SsTab$i'),
  ];

  @override
  void didUpdateWidget(SsTabs old) {
    super.didUpdateWidget(old);
    if (old.tabs.length != widget.tabs.length) {
      for (final n in _nodes) {
        n.dispose();
      }
      _nodes = _make();
    }
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _select(int i) {
    final n = widget.tabs.length;
    final idx = (i + n) % n;
    _nodes[idx].requestFocus();
    widget.onChanged(widget.tabs[idx].id);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return Container(
      height: 36,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                for (var i = 0; i < widget.tabs.length; i++)
                  Flexible(child: _tab(context, i, widget.tabs[i])),
              ],
            ),
          ),
          if (widget.trailing != null) widget.trailing!,
        ],
      ),
    );
  }

  Widget _tab(BuildContext context, int i, SsTab tab) {
    final t = context.ss;
    final c = t.colors;
    final selected = tab.id == widget.selectedId;
    return SsInteractive(
      focusNode: _nodes[i],
      selected: selected,
      semanticLabel: tab.label,
      excludeSemantics: true,
      onTap: () => widget.onChanged(tab.id),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.arrowRight) {
          _select(i + 1);
        } else if (k == LogicalKeyboardKey.arrowLeft) {
          _select(i - 1);
        } else if (k == LogicalKeyboardKey.home) {
          _select(0);
        } else if (k == LogicalKeyboardKey.end) {
          _select(widget.tabs.length - 1);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      builder: (context, s) {
        final hover = s.contains(WidgetState.hovered);
        final fg = selected
            ? c.textPrimary
            : hover
            ? c.textPrimary
            : c.textSecondary;
        return SsFocusRing(
          visible: s.contains(WidgetState.focused),
          color: c.focusRing,
          borderRadius: SsRadius.brSm,
          child: Stack(
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2 + 2),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (tab.icon != null) ...[
                      SsIcon(tab.icon!, size: 14, color: fg),
                      const SizedBox(width: SsSpace.s1 + 2),
                    ],
                    Flexible(
                      child: Text(
                        tab.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.text.bodyStrong.copyWith(
                          color: fg,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                left: SsSpace.s2,
                right: SsSpace.s2,
                bottom: 0,
                child: AnimatedContainer(
                  duration: SsMotion.base,
                  height: 2,
                  color: selected ? c.accent : const Color(0x00000000),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The content region of a tab: carries the tabpanel semantics.
class SsTabPanel extends StatelessWidget {
  const SsTabPanel({required this.label, required this.child, super.key});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(container: true, label: label, child: child);
  }
}
