import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/elevation.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';

/// Where a popover sits relative to its anchor rectangle.
enum SsPlacement {
  belowStart,
  belowCenter,
  belowEnd,
  aboveCenter,
  rightStart,

  /// At the anchor's top-left corner (context menus, anchored on a point).
  pointer,
}

/// A handle to an open popover.
class SsPopoverHandle {
  SsPopoverHandle._(
    this._entry,
    this._onClosed,
    this._restoreFocus,
    this._scope,
  );

  OverlayEntry? _entry;
  final FocusScopeNode? _scope;
  final VoidCallback? _onClosed;
  final FocusNode? _restoreFocus;

  bool get isOpen => _entry != null;

  /// Closes the popover (idempotent).
  void close() {
    final e = _entry;
    if (e == null) return;
    _entry = null;
    e.remove();
    e.dispose();
    _scope?.dispose();
    final focus = _restoreFocus;
    if (focus != null && focus.context != null && focus.canRequestFocus) {
      focus.requestFocus();
    }
    _onClosed?.call();
  }
}

class _PopoverLayout extends SingleChildLayoutDelegate {
  const _PopoverLayout({
    required this.anchor,
    required this.placement,
    required this.gap,
    required this.matchWidth,
  });

  final Rect anchor;
  final SsPlacement placement;
  final double gap;
  final bool matchWidth;

  static const double margin = 8;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      minWidth: matchWidth ? math.min(anchor.width, constraints.maxWidth) : 0,
      maxWidth: math.max(0, constraints.maxWidth - margin * 2),
      maxHeight: math.max(0, constraints.maxHeight - margin * 2),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    double x;
    double y;
    switch (placement) {
      case SsPlacement.belowStart:
        x = anchor.left;
        y = anchor.bottom + gap;
      case SsPlacement.belowCenter:
        x = anchor.center.dx - child.width / 2;
        y = anchor.bottom + gap;
      case SsPlacement.belowEnd:
        x = anchor.right - child.width;
        y = anchor.bottom + gap;
      case SsPlacement.aboveCenter:
        x = anchor.center.dx - child.width / 2;
        y = anchor.top - gap - child.height;
      case SsPlacement.rightStart:
        x = anchor.right + gap;
        y = anchor.top;
      case SsPlacement.pointer:
        x = anchor.left;
        y = anchor.top;
    }
    final below =
        placement == SsPlacement.belowStart ||
        placement == SsPlacement.belowCenter ||
        placement == SsPlacement.belowEnd;
    if (below && y + child.height > size.height - margin) {
      final above = anchor.top - gap - child.height;
      if (above >= margin) y = above;
    }
    if (placement == SsPlacement.aboveCenter && y < margin) {
      y = anchor.bottom + gap;
    }
    if (placement == SsPlacement.rightStart &&
        x + child.width > size.width - margin) {
      x = anchor.left - gap - child.width;
    }
    x = x.clamp(margin, math.max(margin, size.width - child.width - margin));
    y = y.clamp(margin, math.max(margin, size.height - child.height - margin));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PopoverLayout old) =>
      old.anchor != anchor ||
      old.placement != placement ||
      old.gap != gap ||
      old.matchWidth != matchWidth;
}

/// The global rectangle of the render box behind [context].
Rect ssGlobalRect(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// Opens [builder]'s widget in the root overlay next to [anchor] (a global
/// rectangle).
///
/// With [barrier], a press outside closes it (and is swallowed). Escape
/// closes it, and focus returns to what had it before. Tooltips pass
/// `barrier: false, interactive: false`.
SsPopoverHandle showSsPopover(
  BuildContext context, {
  required Rect anchor,
  required WidgetBuilder builder,
  SsPlacement placement = SsPlacement.belowStart,
  double gap = 4,
  bool barrier = true,
  bool interactive = true,
  bool matchAnchorWidth = false,
  bool autofocus = true,
  VoidCallback? onClosed,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final overlayBox = overlay.context.findRenderObject()! as RenderBox;
  final topLeft = overlayBox.globalToLocal(anchor.topLeft);
  final local = topLeft & anchor.size;
  final theme = SsTheme.of(context);
  final previous = FocusManager.instance.primaryFocus;
  final scope = interactive ? FocusScopeNode(debugLabel: 'SsPopover') : null;
  late SsPopoverHandle handle;
  final entry = OverlayEntry(
    builder: (overlayContext) {
      Widget content = CustomSingleChildLayout(
        delegate: _PopoverLayout(
          anchor: local,
          placement: placement,
          gap: gap,
          matchWidth: matchAnchorWidth,
        ),
        child: builder(overlayContext),
      );
      if (!interactive) content = IgnorePointer(child: content);
      if (interactive) {
        content = Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  handle.close();
                  return null;
                },
              ),
            },
            child: FocusScope(node: scope, child: content),
          ),
        );
      }
      return SsScope(
        theme: theme,
        child: Stack(
          children: [
            if (barrier)
              Positioned.fill(
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) => handle.close(),
                  child: const SizedBox.expand(),
                ),
              ),
            Positioned.fill(child: content),
          ],
        ),
      );
    },
  );
  handle = SsPopoverHandle._(
    entry,
    onClosed,
    interactive ? previous : null,
    scope,
  );
  overlay.insert(entry);
  if (autofocus && scope != null) {
    // The popover takes focus even when a text field has it (so Escape and
    // the arrow keys reach the popover).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (handle.isOpen) scope.requestFocus();
    });
  }
  return handle;
}

/// The surface of a popover: menu, dropdown list, colour picker.
class SsPopoverSurface extends StatelessWidget {
  const SsPopoverSurface({
    required this.child,
    this.padding = const EdgeInsets.all(SsSpace.s1),
    this.width,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return Container(
      width: width,
      padding: padding,
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: SsRadius.brLg,
        border: Border.all(color: c.border),
        boxShadow: SsElevation.e2,
      ),
      child: child,
    );
  }
}
