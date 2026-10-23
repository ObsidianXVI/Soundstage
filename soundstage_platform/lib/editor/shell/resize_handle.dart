import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

/// A vertical divider between docked panels: drag to resize, arrow keys
/// resize by 16 px (Shift 64), double-click resets.
class ResizeHandle extends StatefulWidget {
  const ResizeHandle({
    required this.semanticLabel,
    required this.onDelta,
    this.onReset,
    super.key,
  });

  final String semanticLabel;

  /// Called with the horizontal movement in pixels (positive = right).
  final ValueChanged<double> onDelta;
  final VoidCallback? onReset;

  @override
  State<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<ResizeHandle> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent) return KeyEventResult.ignored;
        final step = HardwareKeyboard.instance.isShiftPressed ? 64.0 : 16.0;
        if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          widget.onDelta(-step);
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          widget.onDelta(step);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Builder(
        builder: (context) {
          final focused =
              Focus.of(context).hasFocus &&
              FocusManager.instance.highlightMode ==
                  FocusHighlightMode.traditional;
          final active = _hover || _drag || focused;
          return Semantics(
            label: widget.semanticLabel,
            hint: 'Drag, or use the left and right arrow keys, to resize',
            focusable: true,
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              onEnter: (_) => setState(() => _hover = true),
              onExit: (_) => setState(() => _hover = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) => Focus.of(context).requestFocus(),
                onDoubleTap: widget.onReset,
                onHorizontalDragStart: (_) => setState(() => _drag = true),
                onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
                onHorizontalDragEnd: (_) => setState(() => _drag = false),
                onHorizontalDragCancel: () => setState(() => _drag = false),
                child: SizedBox(
                  width: 7,
                  child: Center(
                    child: AnimatedContainer(
                      duration: SsMotion.fast,
                      width: active ? 3 : 1,
                      color: focused
                          ? c.focusRing
                          : active
                          ? c.accent
                          : c.borderSubtle,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
