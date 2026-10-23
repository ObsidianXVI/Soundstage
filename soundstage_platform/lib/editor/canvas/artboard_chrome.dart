import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/editor_controller.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'canvas_controller.dart';

/// The artboards' screen-space controls: a free-width handle on each
/// artboard's right edge, and a badge with the free width, the breakpoint
/// in effect and a reset while the width differs from `designSize`.
///
/// Positioned by a `Flow` from the camera and the artboards' geometry, so
/// pan and zoom only repaint it (no rebuild, no relayout).
class ArtboardChrome extends StatelessWidget {
  const ArtboardChrome({
    required this.controller,
    required this.breakpoints,
    super.key,
  });

  final CanvasController controller;
  final List<ir.Breakpoint> breakpoints;

  @override
  Widget build(BuildContext context) {
    return Flow(
      delegate: _ChromeDelegate(controller, [
        for (final b in breakpoints) b.id,
      ]),
      children: [
        for (final b in breakpoints) ...[
          WidthHandle(
            key: ValueKey<String>('width-handle-${b.id}'),
            controller: controller,
            breakpoint: b,
          ),
          WidthBadge(
            key: ValueKey<String>('width-badge-${b.id}'),
            controller: controller,
            breakpoint: b,
          ),
        ],
      ],
    );
  }
}

class _ChromeDelegate extends FlowDelegate {
  _ChromeDelegate(this.controller, this.ids)
    : super(
        repaint: Listenable.merge([controller.camera, controller.geometry]),
      );

  final CanvasController controller;
  final List<String> ids;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      constraints.loosen();

  @override
  void paintChildren(FlowPaintingContext context) {
    final cam = controller.camera.value;
    final view = Offset.zero & context.size;
    for (var i = 0; i < ids.length; i++) {
      final a = controller.artboards[ids[i]];
      if (a == null || a.worldRect.isEmpty) continue;
      final r = cam.rectToScreen(a.worldRect);
      // Handle: just right of the edge, centred on the visible part.
      final handle = context.getChildSize(i * 2)!;
      final top = r.top < view.top ? view.top : r.top;
      final bottom = r.bottom > view.bottom ? view.bottom : r.bottom;
      if (bottom > top) {
        final cy = (top + bottom) / 2;
        context.paintChild(
          i * 2,
          transform: Matrix4.translationValues(
            r.right + 2,
            cy - handle.height / 2,
            0,
          ),
        );
      }
      // Badge: above the artboard's top-right corner.
      final badge = context.getChildSize(i * 2 + 1)!;
      if (!badge.isEmpty) {
        context.paintChild(
          i * 2 + 1,
          transform: Matrix4.translationValues(
            r.right - badge.width,
            r.top - badge.height - 4,
            0,
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_ChromeDelegate old) =>
      !identical(old.controller, controller) || old.ids.length != ids.length;
}

/// The drag handle on an artboard's right edge: drags its width freely
/// (to test responsiveness); double-click resets to `designSize`.
class WidthHandle extends StatefulWidget {
  const WidthHandle({
    required this.controller,
    required this.breakpoint,
    super.key,
  });

  final CanvasController controller;
  final ir.Breakpoint breakpoint;

  @override
  State<WidthHandle> createState() => _WidthHandleState();
}

class _WidthHandleState extends State<WidthHandle> {
  double _start = 0;
  double _dx = 0;
  bool _hover = false;
  bool _dragging = false;

  double get _design => widget.breakpoint.designSize.width;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    final active = _hover || _dragging;
    return Semantics(
      label: 'Resize ${widget.breakpoint.name} artboard width',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Count the movement from the pointer-down, not after the slop.
          dragStartBehavior: DragStartBehavior.down,
          onDoubleTap: () =>
              widget.controller.resetPreviewWidth(widget.breakpoint.id),
          onHorizontalDragStart: (_) {
            _start =
                widget.controller.previewWidthOf(widget.breakpoint.id) ??
                _design;
            _dx = 0;
            setState(() => _dragging = true);
          },
          onHorizontalDragUpdate: (d) {
            _dx += d.delta.dx;
            widget.controller.setPreviewWidth(
              widget.breakpoint.id,
              _start + _dx / widget.controller.camera.value.zoom,
              designWidth: _design,
            );
          },
          onHorizontalDragEnd: (_) => setState(() => _dragging = false),
          onHorizontalDragCancel: () => setState(() => _dragging = false),
          child: SizedBox(
            width: 12,
            height: 40,
            child: Center(
              child: AnimatedContainer(
                duration: SsMotion.fast,
                width: 4,
                height: 32,
                decoration: BoxDecoration(
                  color: active ? c.accent : c.borderStrong,
                  borderRadius: BorderRadius.circular(SsRadius.pill),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The free-width badge: "834 px · Tablet" and a reset button, shown while
/// the artboard's width differs from its breakpoint's `designSize`.
class WidthBadge extends ConsumerWidget {
  const WidthBadge({
    required this.controller,
    required this.breakpoint,
    super.key,
  });

  final CanvasController controller;
  final ir.Breakpoint breakpoint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final doc = ref
        .watch(editorControllerProvider.select((s) => Identity(s.document)))
        .value;
    return ValueListenableBuilder<Map<String, double>>(
      valueListenable: controller.previewWidths,
      builder: (context, widths, _) {
        final w = widths[breakpoint.id];
        if (w == null) return const SizedBox.shrink();
        final t = context.ss;
        final effective = ir.breakpointForWidth(doc, w) ?? breakpoint;
        return Container(
          key: const ValueKey<String>('width-badge'),
          height: 22,
          padding: const EdgeInsets.only(left: SsSpace.s2),
          decoration: BoxDecoration(
            color: t.colors.surface2,
            borderRadius: BorderRadius.circular(SsRadius.sm),
            border: Border.all(color: t.colors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${w.round()} px', style: t.text.numeric),
              Text(
                '  ·  ${effective.name}',
                style: t.text.caption.copyWith(
                  color: effective.id == breakpoint.id
                      ? t.colors.textSecondary
                      : t.colors.accentText,
                ),
              ),
              SsIconButton(
                icon: SsIcons.rotateCcw,
                semanticLabel: 'Reset ${breakpoint.name} width',
                size: 22,
                iconSize: 12,
                onPressed: () => controller.resetPreviewWidth(breakpoint.id),
              ),
            ],
          ),
        );
      },
    );
  }
}
