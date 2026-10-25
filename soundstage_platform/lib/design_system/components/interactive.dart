import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'focus_release.dart';
import 'input_modality.dart';

/// Builds a control's visuals from its interaction [states]
/// (hovered, pressed, focused, disabled, selected).
typedef SsInteractiveBuilder =
    Widget Function(BuildContext context, Set<WidgetState> states);

/// The interaction primitive every chrome control is built on.
///
/// It owns focus (keyboard focus shows a ring via [WidgetState.focused] only
/// when focus came from the keyboard), hover, pressed and disabled state,
/// Enter/Space activation, the mouse cursor and the semantics node.
class SsInteractive extends StatefulWidget {
  const SsInteractive({
    required this.builder,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTapDown,
    this.enabled = true,
    this.selected = false,
    this.semanticLabel,
    this.semanticValue,
    this.semanticHint,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.excludeSemantics = false,
    this.isButton = true,
    this.cursor,
    this.onKeyEvent,
    super.key,
  });

  final SsInteractiveBuilder builder;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  /// Disabled controls ignore pointer and keyboard and report
  /// [WidgetState.disabled].
  final bool enabled;
  final bool selected;
  final String? semanticLabel;
  final String? semanticValue;
  final String? semanticHint;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool canRequestFocus;

  /// Hides the subtree's own semantics so [semanticLabel] stands alone.
  final bool excludeSemantics;

  /// Reports the semantics node as a button.
  final bool isButton;
  final MouseCursor? cursor;

  /// Extra key handling (arrow keys of a group, etc.) before activation.
  final FocusOnKeyEventCallback? onKeyEvent;

  @override
  State<SsInteractive> createState() => _SsInteractiveState();
}

class _SsInteractiveState extends State<SsInteractive> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focusVisible = false;
  FocusNode? _ownNode;

  FocusNode get _node => widget.focusNode ?? (_ownNode ??= FocusNode());

  bool get _active => widget.enabled && widget.onTap != null;

  void _set(void Function() fn) {
    if (mounted) setState(fn);
  }

  @override
  void initState() {
    super.initState();
    SsInputModality.ensureInstalled();
    SsInputModality.keyboard.addListener(_onModality);
  }

  void _onModality() {
    if (mounted && _focusVisible) setState(() {});
  }

  @override
  void dispose() {
    SsInputModality.keyboard.removeListener(_onModality);
    _ownNode?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SsInteractive old) {
    super.didUpdateWidget(old);
    if (!widget.enabled) {
      _hovered = false;
      _pressed = false;
      _focusVisible = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final states = <WidgetState>{
      if (!widget.enabled) WidgetState.disabled,
      if (_hovered && widget.enabled) WidgetState.hovered,
      if (_pressed && widget.enabled) WidgetState.pressed,
      if (_focusVisible && widget.enabled && SsInputModality.keyboard.value)
        WidgetState.focused,
      if (widget.selected) WidgetState.selected,
    };
    Widget child = widget.builder(context, states);
    child = MouseRegion(
      onEnter: (_) => _set(() => _hovered = true),
      onExit: (_) => _set(() => _hovered = false),
      child: child,
    );
    child = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _active
          ? (_) {
              _set(() => _pressed = true);
              if (widget.canRequestFocus) _node.requestFocus();
            }
          : null,
      onTapUp: _active ? (_) => _set(() => _pressed = false) : null,
      onTapCancel: _active ? () => _set(() => _pressed = false) : null,
      onTap: _active ? widget.onTap : null,
      onDoubleTap: widget.enabled ? widget.onDoubleTap : null,
      onSecondaryTapDown: widget.enabled ? widget.onSecondaryTapDown : null,
      child: child,
    );
    child = FocusableActionDetector(
      enabled: widget.enabled,
      focusNode: _node,
      autofocus: widget.autofocus,
      descendantsAreFocusable: true,
      onShowFocusHighlight: (v) => _set(() => _focusVisible = v),
      mouseCursor:
          widget.cursor ??
          (_active ? SystemMouseCursors.click : SystemMouseCursors.basic),
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: _ActivateAction(
          isActive: () => _active,
          onActivate: () => widget.onTap?.call(),
        ),
      },
      child: child,
    );
    if (widget.onKeyEvent != null) {
      // Above the detector, so it sees the key events of the detector's focus.
      child = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: widget.onKeyEvent,
        child: child,
      );
    }
    if (!widget.canRequestFocus) {
      child = ExcludeFocus(child: child);
    }
    return Semantics(
      container: true,
      button: widget.isButton,
      enabled: widget.enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      value: widget.semanticValue,
      hint: widget.semanticHint,
      excludeSemantics: widget.excludeSemantics,
      onTap: _active ? widget.onTap : null,
      child: child,
    );
  }
}

/// A rounded inset focus ring drawn over [child] when [visible].
class SsFocusRing extends StatelessWidget {
  const SsFocusRing({
    required this.visible,
    required this.color,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(4)),
    super.key,
  });

  final bool visible;
  final Color color;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        border: visible ? Border.all(color: color, width: 2) : null,
      ),
      child: child,
    );
  }
}

/// Enter/Space activation that stands down (letting the key through to a
/// child text field) when the control is inactive or a text field inside
/// it has focus (Enter must submit it, Space must type).
class _ActivateAction extends Action<ActivateIntent> {
  _ActivateAction({required this.isActive, required this.onActivate});

  final bool Function() isActive;
  final VoidCallback onActivate;

  @override
  bool isEnabled(ActivateIntent intent) =>
      isActive() && !isTextInputFocus(FocusManager.instance.primaryFocus);

  @override
  Object? invoke(ActivateIntent intent) {
    onActivate();
    return null;
  }
}
