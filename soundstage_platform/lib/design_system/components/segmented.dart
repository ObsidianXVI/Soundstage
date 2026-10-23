import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'icon.dart';
import 'interactive.dart';
import 'tooltip.dart';

/// One segment of an [SsSegmented].
class SsSegment<T> {
  const SsSegment({
    required this.value,
    this.label,
    this.icon,
    this.semanticLabel,
    this.enabled = true,
  }) : assert(label != null || icon != null);

  final T value;
  final String? label;
  final IconData? icon;

  /// Required for icon-only segments; also the tooltip.
  final String? semanticLabel;
  final bool enabled;
}

/// A single-choice group of segments. Left/Right (and Up/Down) move the
/// selection, like a radio group. [selected] null means nothing or mixed.
class SsSegmented<T> extends StatefulWidget {
  const SsSegmented({
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.semanticLabel,
    this.expand = false,
    super.key,
  });

  final List<SsSegment<T>> segments;
  final T? selected;
  final ValueChanged<T>? onChanged;
  final String? semanticLabel;

  /// Stretch segments to share the available width.
  final bool expand;

  @override
  State<SsSegmented<T>> createState() => _SsSegmentedState<T>();
}

class _SsSegmentedState<T> extends State<SsSegmented<T>> {
  late List<FocusNode> _nodes = _makeNodes();

  List<FocusNode> _makeNodes() => [
    for (var i = 0; i < widget.segments.length; i++)
      FocusNode(debugLabel: 'SsSegment$i'),
  ];

  @override
  void didUpdateWidget(SsSegmented<T> old) {
    super.didUpdateWidget(old);
    if (old.segments.length != widget.segments.length) {
      for (final n in _nodes) {
        n.dispose();
      }
      _nodes = _makeNodes();
    }
  }

  @override
  void dispose() {
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _move(int from, int dir) {
    final n = widget.segments.length;
    for (var k = 1; k <= n; k++) {
      final i = (from + dir * k + n * k) % n;
      final seg = widget.segments[i];
      if (seg.enabled) {
        _nodes[i].requestFocus();
        widget.onChanged?.call(seg.value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final children = <Widget>[];
    for (var i = 0; i < widget.segments.length; i++) {
      final seg = widget.segments[i];
      final isSel = seg.value == widget.selected;
      final enabled = widget.onChanged != null && seg.enabled;
      Widget item = SsInteractive(
        focusNode: _nodes[i],
        enabled: enabled,
        selected: isSel,
        semanticLabel: seg.semanticLabel ?? seg.label,
        excludeSemantics: true,
        onTap: () => widget.onChanged?.call(seg.value),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final k = event.logicalKey;
          if (k == LogicalKeyboardKey.arrowRight ||
              k == LogicalKeyboardKey.arrowDown) {
            _move(i, 1);
            return KeyEventResult.handled;
          }
          if (k == LogicalKeyboardKey.arrowLeft ||
              k == LogicalKeyboardKey.arrowUp) {
            _move(i, -1);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        builder: (context, s) {
          final disabled = s.contains(WidgetState.disabled);
          final hover = s.contains(WidgetState.hovered);
          final fg = disabled
              ? c.textDisabled
              : isSel
              ? c.textPrimary
              : c.textSecondary;
          return SsFocusRing(
            visible: s.contains(WidgetState.focused),
            color: c.focusRing,
            borderRadius: SsRadius.brSm,
            child: AnimatedContainer(
              duration: SsMotion.fast,
              height: SsSpace.controlHeightSm,
              padding: EdgeInsets.symmetric(
                horizontal: seg.label == null
                    ? SsSpace.s2
                    : (widget.expand ? SsSpace.s1 : SsSpace.s3),
              ),
              constraints: const BoxConstraints(minWidth: 28),
              decoration: BoxDecoration(
                color: isSel
                    ? c.surface3
                    : hover && !disabled
                    ? c.hoverLayer
                    : const Color(0x00000000),
                borderRadius: SsRadius.brSm,
                border: isSel ? Border.all(color: c.border) : null,
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (seg.icon != null)
                      SsIcon(seg.icon!, size: 14, color: fg),
                    if (seg.icon != null && seg.label != null)
                      const SizedBox(width: SsSpace.s1),
                    if (seg.label != null)
                      Text(seg.label!, style: t.text.body.copyWith(color: fg)),
                  ],
                ),
              ),
            ),
          );
        },
      );
      if (seg.label == null && seg.semanticLabel != null) {
        item = SsTooltip(message: seg.semanticLabel!, child: item);
      }
      children.add(widget.expand ? Expanded(child: item) : item);
    }
    return Semantics(
      container: true,
      label: widget.semanticLabel,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: SsRadius.brMd,
          border: Border.all(color: c.borderSubtle),
        ),
        child: Row(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}
