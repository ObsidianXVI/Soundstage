import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/elevation.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'input_modality.dart';
import 'popover.dart';

/// A tooltip that shows after [SsMotion.tooltipDelay] on hover, immediately
/// on keyboard focus, and hides on press, Escape or leave. It also labels
/// [child] for assistive tech.
class SsTooltip extends StatefulWidget {
  const SsTooltip({
    required this.message,
    required this.child,
    this.shortcut,
    this.placement = SsPlacement.belowCenter,
    this.waitDuration = SsMotion.tooltipDelay,
    super.key,
  });

  final String message;

  /// A shortcut hint, shown beside the message (e.g. `⌘Z`).
  final String? shortcut;
  final SsPlacement placement;
  final Duration waitDuration;
  final Widget child;

  @override
  State<SsTooltip> createState() => _SsTooltipState();
}

class _SsTooltipState extends State<SsTooltip> {
  Timer? _timer;
  SsPopoverHandle? _handle;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    SsInputModality.ensureInstalled();
    SsInputModality.keyboard.addListener(_onModality);
  }

  void _onModality() {
    if (_focused && SsInputModality.keyboard.value) {
      _timer?.cancel();
      _show();
    }
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(widget.waitDuration, _show);
  }

  void _show() {
    if (!mounted || (_handle?.isOpen ?? false)) return;
    final message = widget.message;
    final shortcut = widget.shortcut;
    _handle = showSsPopover(
      context,
      anchor: ssGlobalRect(context),
      placement: widget.placement,
      barrier: false,
      interactive: false,
      builder: (_) => _TooltipBubble(message: message, shortcut: shortcut),
    );
  }

  void _hide() {
    _timer?.cancel();
    _handle?.close();
    _handle = null;
  }

  @override
  void dispose() {
    SsInputModality.keyboard.removeListener(_onModality);
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      tooltip: widget.message,
      child: MouseRegion(
        onEnter: (_) => _schedule(),
        onExit: (_) => _hide(),
        child: Listener(
          onPointerDown: (_) => _hide(),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (focused) {
              _focused = focused;
              if (!focused) {
                _hide();
              } else if (SsInputModality.keyboard.value) {
                _timer?.cancel();
                _show();
              }
            },
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape &&
                  (_handle?.isOpen ?? false)) {
                _hide();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _TooltipBubble extends StatelessWidget {
  const _TooltipBubble({required this.message, this.shortcut});

  final String message;
  final String? shortcut;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(
        horizontal: SsSpace.s2,
        vertical: SsSpace.s1,
      ),
      decoration: BoxDecoration(
        color: t.colors.isDark
            ? const Color(0xFF0A0A0B)
            : const Color(0xFF18181B),
        borderRadius: SsRadius.brSm,
        border: Border.all(color: t.colors.border),
        boxShadow: SsElevation.e2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              message,
              style: t.text.small.copyWith(color: const Color(0xFFEDEDF0)),
            ),
          ),
          if (shortcut != null) ...[
            const SizedBox(width: SsSpace.s2),
            Text(
              shortcut!,
              style: t.text.caption.copyWith(color: const Color(0xFFA6A6B0)),
            ),
          ],
        ],
      ),
    );
  }
}
