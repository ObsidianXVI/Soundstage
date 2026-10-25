import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'focus_release.dart';

/// A single-line (or multi-line) text input in the chrome's style.
///
/// Enter submits; Escape (when [revertOnEscape]) restores the text the field
/// had on focus and drops focus.
class SsTextField extends StatefulWidget {
  const SsTextField({
    this.controller,
    this.initialValue,
    this.focusNode,
    this.placeholder,
    this.onChanged,
    this.onSubmitted,
    this.prefix,
    this.suffix,
    this.errorText,
    this.enabled = true,
    this.autofocus = false,
    this.maxLines = 1,
    this.semanticLabel,
    this.textStyle,
    this.revertOnEscape = false,
    this.releaseFocusOnSubmit = false,
    this.selectAllOnFocus = false,
    this.inputFormatters,
    this.textAlign = TextAlign.start,
    this.dense = false,
    this.bare = false,
    super.key,
  });

  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final String? placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? prefix;
  final Widget? suffix;

  /// Shows the field in the error state with this message below it.
  final String? errorText;
  final bool enabled;
  final bool autofocus;
  final int maxLines;
  final String? semanticLabel;
  final TextStyle? textStyle;
  final bool revertOnEscape;

  /// Hands focus to the nearest focusable ancestor after Enter or Escape
  /// (editor chrome fields, so the editor's shortcuts work again).
  final bool releaseFocusOnSubmit;
  final bool selectAllOnFocus;
  final List<TextInputFormatter>? inputFormatters;
  final TextAlign textAlign;
  final bool dense;

  /// No border or fill (the host draws the container).
  final bool bare;

  @override
  State<SsTextField> createState() => _SsTextFieldState();
}

class _SsTextFieldState extends State<SsTextField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController(text: widget.initialValue);
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  String _onFocusText = '';
  bool _hovered = false;
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  void _onFocus() {
    if (_focus.hasFocus) {
      _onFocusText = _controller.text;
      if (widget.selectAllOnFocus) {
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      }
    }
    if (mounted) setState(() => _hasFocus = _focus.hasFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    if (widget.focusNode == null) _focus.dispose();
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final error = widget.errorText != null;
    final style = (widget.textStyle ?? t.text.body).copyWith(
      color: widget.enabled ? c.textPrimary : c.textDisabled,
    );
    Widget field = TextField(
      controller: _controller,
      focusNode: _focus,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      maxLines: widget.maxLines,
      minLines: 1,
      style: style,
      textAlign: widget.textAlign,
      cursorColor: c.accentText,
      cursorWidth: 1.5,
      inputFormatters: widget.inputFormatters,
      onChanged: widget.onChanged,
      onSubmitted: (v) {
        widget.onSubmitted?.call(v);
        if (widget.releaseFocusOnSubmit && mounted) {
          releaseFocusToAncestor(_focus);
        }
      },
      decoration: InputDecoration.collapsed(
        hintText: widget.placeholder,
        hintStyle: style.copyWith(color: c.textDisabled),
      ),
    );
    if (widget.revertOnEscape) {
      field = Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            _controller.text = _onFocusText;
            if (widget.releaseFocusOnSubmit) {
              releaseFocusToAncestor(_focus);
            } else {
              _focus.unfocus();
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: field,
      );
    }
    if (widget.bare) {
      return Semantics(
        label: widget.semanticLabel,
        textField: true,
        child: field,
      );
    }
    final borderColor = error
        ? c.danger
        : _hasFocus
        ? c.focusRing
        : _hovered
        ? c.borderStrong
        : c.border;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          cursor: SystemMouseCursors.text,
          child: AnimatedContainer(
            duration: SsMotion.fast,
            constraints: BoxConstraints(
              minHeight: widget.dense
                  ? SsSpace.controlHeightSm
                  : SsSpace.controlHeight,
            ),
            padding: EdgeInsets.symmetric(
              horizontal: SsSpace.s2,
              vertical: widget.maxLines == 1 ? 0 : SsSpace.s1 + 2,
            ),
            decoration: BoxDecoration(
              color: widget.enabled ? c.surface2 : c.surface1,
              borderRadius: SsRadius.brMd,
              border: Border.all(color: borderColor, width: _hasFocus ? 2 : 1),
            ),
            child: Row(
              children: [
                if (widget.prefix != null) ...[
                  widget.prefix!,
                  const SizedBox(width: SsSpace.s2),
                ],
                Expanded(
                  child: Semantics(
                    label: widget.semanticLabel,
                    textField: true,
                    child: field,
                  ),
                ),
                if (widget.suffix != null) ...[
                  const SizedBox(width: SsSpace.s2),
                  widget.suffix!,
                ],
              ],
            ),
          ),
        ),
        if (error)
          Padding(
            padding: const EdgeInsets.only(top: SsSpace.s1),
            child: Text(
              widget.errorText!,
              style: t.text.caption.copyWith(color: c.danger),
            ),
          ),
      ],
    );
  }
}
