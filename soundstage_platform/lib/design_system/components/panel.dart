import 'package:flutter/material.dart';

import '../icons/ss_icons.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'icon.dart';
import 'interactive.dart';

/// A section with a header and (optionally collapsible) body: an inspector
/// section, a panel group.
///
/// Uncontrolled by default ([initiallyExpanded]); pass [expanded] and
/// [onExpandedChanged] to control it. The header toggles with click, Enter
/// or Space and reports expanded/collapsed to assistive tech.
class SsPanel extends StatefulWidget {
  const SsPanel({
    required this.title,
    required this.child,
    this.actions,
    this.collapsible = true,
    this.initiallyExpanded = true,
    this.expanded,
    this.onExpandedChanged,
    this.padding = const EdgeInsets.fromLTRB(
      SsSpace.s3,
      SsSpace.s1,
      SsSpace.s3,
      SsSpace.s3,
    ),
    this.divider = true,
    super.key,
  });

  final String title;
  final Widget child;

  /// Icon buttons at the end of the header.
  final List<Widget>? actions;
  final bool collapsible;
  final bool initiallyExpanded;
  final bool? expanded;
  final ValueChanged<bool>? onExpandedChanged;
  final EdgeInsetsGeometry padding;

  /// A hairline under the section.
  final bool divider;

  @override
  State<SsPanel> createState() => _SsPanelState();
}

class _SsPanelState extends State<SsPanel> {
  late bool _expanded = widget.initiallyExpanded;

  bool get _isExpanded => widget.expanded ?? _expanded;

  void _toggle() {
    final next = !_isExpanded;
    if (widget.expanded == null) setState(() => _expanded = next);
    widget.onExpandedChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final open = !widget.collapsible || _isExpanded;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: widget.divider
            ? Border(bottom: BorderSide(color: c.borderSubtle))
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                Expanded(
                  child: SsInteractive(
                    enabled: widget.collapsible,
                    semanticLabel: widget.title,
                    semanticValue: widget.collapsible
                        ? (open ? 'Expanded' : 'Collapsed')
                        : null,
                    excludeSemantics: true,
                    onTap: _toggle,
                    builder: (context, s) {
                      final hover =
                          s.contains(WidgetState.hovered) && widget.collapsible;
                      return SsFocusRing(
                        visible: s.contains(WidgetState.focused),
                        color: c.focusRing,
                        borderRadius: SsRadius.brSm,
                        child: Container(
                          color: hover ? c.hoverLayer : const Color(0x00000000),
                          padding: const EdgeInsets.only(
                            left: SsSpace.s2,
                            right: SsSpace.s2,
                          ),
                          alignment: Alignment.centerLeft,
                          child: Row(
                            children: [
                              if (widget.collapsible)
                                AnimatedRotation(
                                  turns: open ? 0 : -0.25,
                                  duration: SsMotion.base,
                                  curve: SsMotion.easeOut,
                                  child: const SsIcon(
                                    SsIcons.chevronDown,
                                    size: 14,
                                  ),
                                )
                              else
                                const SizedBox(width: SsSpace.s1),
                              const SizedBox(width: SsSpace.s1),
                              Expanded(
                                child: Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: t.text.bodyStrong,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                if (widget.actions != null)
                  Padding(
                    padding: const EdgeInsets.only(right: SsSpace.s1),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: widget.actions!,
                    ),
                  ),
              ],
            ),
          ),
          AnimatedSize(
            duration: SsMotion.base,
            curve: SsMotion.easeOut,
            alignment: Alignment.topCenter,
            child: open
                ? Padding(padding: widget.padding, child: widget.child)
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}
