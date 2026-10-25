import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'focus_release.dart';
import 'number_expression.dart';

/// A numeric input in the Figma idiom.
///
/// - Drag the [label] horizontally to scrub the value. Shift scrubs x10,
///   Alt x0.1.
/// - Arrow Up/Down step by [step] (Shift x10, Alt x0.1).
/// - Typing accepts arithmetic: `120/2`, `+8` (relative to the current
///   value), `*2`, `(4+4)*3`.
/// - Enter or blur commits, Escape cancels. The result is clamped to
///   [min]/[max] and rounded to [fractionDigits].
/// - [mixed] shows "Mixed" (a multi-selection that disagrees); any entry
///   or step replaces it.
///
/// [onChangeStart]/[onChangeEnd] bracket continuous gestures (scrub), so a
/// history can coalesce them into one undo step.
class SsNumberField extends StatefulWidget {
  const SsNumberField({
    required this.value,
    required this.onChanged,
    this.label,
    this.unit,
    this.min,
    this.max,
    this.step = 1,
    this.fractionDigits = 2,
    this.mixed = false,
    this.enabled = true,
    this.semanticLabel,
    this.onChangeStart,
    this.onChangeEnd,
    this.width,
    this.textAlign = TextAlign.start,
    super.key,
  });

  final double? value;
  final ValueChanged<double>? onChanged;

  /// A short label drawn inside the field (`X`, `W`, `R`). Dragging it
  /// scrubs.
  final String? label;

  /// A unit shown after the number (`px`, `°`, `%`).
  final String? unit;
  final double? min;
  final double? max;

  /// The change per arrow press and per scrubbed pixel.
  final double step;
  final int fractionDigits;
  final bool mixed;
  final bool enabled;
  final String? semanticLabel;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;
  final double? width;
  final TextAlign textAlign;

  @override
  State<SsNumberField> createState() => _SsNumberFieldState();
}

class _SsNumberFieldState extends State<SsNumberField> {
  late final TextEditingController _controller = TextEditingController(
    text: _format(),
  );
  final FocusNode _focus = FocusNode(debugLabel: 'SsNumberField');
  bool _hovered = false;
  bool _hasFocus = false;

  /// Whether the text was typed since it was last committed or shown. Only
  /// typed text commits on blur: after Enter (or a nudge) the field may stay
  /// focused while its target changes (another node, another text range),
  /// and the old number must not be written to the new target.
  bool _dirty = false;
  bool _scrubbing = false;

  /// The text last committed, so the blur that follows an Enter does not
  /// emit the same value twice. Cleared when the field gains focus.
  String? _committedText;
  double _scrubStart = 0;
  double _scrubAccum = 0;

  /// The value last committed (what Escape restores).
  double? get _current => widget.value;

  String _format([double? v]) {
    final value = v ?? widget.value;
    if (widget.mixed && v == null) return '';
    if (value == null) return '';
    return formatNumber(value, fractionDigits: widget.fractionDigits);
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(SsNumberField old) {
    super.didUpdateWidget(old);
    if ((old.value != widget.value ||
            old.mixed != widget.mixed ||
            old.fractionDigits != widget.fractionDigits) &&
        (!_focus.hasFocus || !_dirty)) {
      _controller.text = _format();
      if (_focus.hasFocus) _selectAll();
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    final has = _focus.hasFocus;
    if (has) {
      _committedText = null;
      _selectAll();
    } else {
      _commit();
    }
    if (mounted) setState(() => _hasFocus = has);
  }

  void _selectAll() {
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _controller.text.length,
    );
  }

  double _clamp(double v) {
    var r = v;
    if (widget.min != null) r = math.max(widget.min!, r);
    if (widget.max != null) r = math.min(widget.max!, r);
    return roundToDigits(r, widget.fractionDigits);
  }

  void _emit(double v) {
    widget.onChanged?.call(v);
  }

  /// Parses the text and applies it; invalid input reverts.
  void _commit() {
    if (!_dirty) {
      _controller.text = _format();
      return;
    }
    _dirty = false;
    final text = _controller.text.trim();
    if (text == _committedText) return;
    if (text.isEmpty) {
      _controller.text = _format();
      return;
    }
    final parsed = evaluateNumberExpression(text, current: _current);
    if (parsed == null) {
      _controller.text = _format();
      return;
    }
    final v = _clamp(parsed);
    _controller.text = _format(v);
    _committedText = _controller.text;
    if (widget.mixed || v != _current) _emit(v);
  }

  void _cancel() {
    _dirty = false;
    _controller.text = _format();
    releaseFocusToAncestor(_focus);
  }

  double get _modifier {
    final kb = HardwareKeyboard.instance;
    if (kb.isShiftPressed) return 10;
    if (kb.isAltPressed) return 0.1;
    return 1;
  }

  /// Arrow-key step from the (possibly edited) text.
  void _nudge(int dir) {
    final parsed = evaluateNumberExpression(
      _controller.text,
      current: _current,
    );
    final base = parsed ?? _current ?? 0;
    final v = _clamp(base + dir * widget.step * _modifier);
    _dirty = false;
    _controller.text = _format(v);
    _selectAll();
    _emit(v);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _nudge(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _nudge(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _scrubStartAt() {
    _scrubbing = true;
    _scrubStart = _current ?? 0;
    _scrubAccum = 0;
    widget.onChangeStart?.call();
    setState(() {});
  }

  void _scrubUpdate(double dx) {
    _scrubAccum += dx * widget.step * _modifier;
    final v = _clamp(_scrubStart + _scrubAccum);
    _controller.text = _format(v);
    if (v != _current || widget.mixed) _emit(v);
  }

  void _scrubEnd() {
    _scrubbing = false;
    widget.onChangeEnd?.call();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final enabled = widget.enabled && widget.onChanged != null;
    final borderColor = _hasFocus
        ? c.focusRing
        : (_hovered || _scrubbing)
        ? c.borderStrong
        : c.border;
    final textStyle = t.text.numeric.copyWith(
      color: enabled ? c.textPrimary : c.textDisabled,
    );
    final unit = widget.unit;
    final label = widget.label;
    return SizedBox(
      width: widget.width,
      child: Semantics(
        container: true,
        label: widget.semanticLabel ?? label,
        value: widget.mixed
            ? 'Mixed'
            : (_current == null
                  ? 'Not set'
                  : '${_format()}${unit == null ? '' : ' $unit'}'),
        increasedValue: enabled
            ? _format(_clamp((_current ?? 0) + widget.step))
            : null,
        decreasedValue: enabled
            ? _format(_clamp((_current ?? 0) - widget.step))
            : null,
        onIncrease: enabled ? () => _nudge(1) : null,
        onDecrease: enabled ? () => _nudge(-1) : null,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            duration: SsMotion.fast,
            height: SsSpace.controlHeight,
            decoration: BoxDecoration(
              color: enabled ? c.surface2 : c.surface1,
              borderRadius: SsRadius.brMd,
              border: Border.all(color: borderColor, width: _hasFocus ? 2 : 1),
            ),
            child: Row(
              children: [
                if (label != null)
                  MouseRegion(
                    cursor: enabled
                        ? SystemMouseCursors.resizeLeftRight
                        : SystemMouseCursors.basic,
                    child: GestureDetector(
                      key: const ValueKey<String>('ss-number-scrub'),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: enabled
                          ? (_) => _scrubStartAt()
                          : null,
                      onHorizontalDragUpdate: enabled
                          ? (d) => _scrubUpdate(d.delta.dx)
                          : null,
                      onHorizontalDragEnd: enabled ? (_) => _scrubEnd() : null,
                      onHorizontalDragCancel: enabled && _scrubbing
                          ? _scrubEnd
                          : null,
                      child: Container(
                        width: 24,
                        alignment: Alignment.center,
                        child: ExcludeSemantics(
                          child: Text(
                            label,
                            style: t.text.caption.copyWith(
                              color: _scrubbing || (_hovered && enabled)
                                  ? c.textPrimary
                                  : (enabled
                                        ? c.textSecondary
                                        : c.textDisabled),
                            ),
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  const SizedBox(width: SsSpace.s2),
                Expanded(
                  child: Focus(
                    canRequestFocus: false,
                    skipTraversal: true,
                    onKeyEvent: _onKey,
                    child: TextField(
                      controller: _controller,
                      onChanged: (_) => _dirty = true,
                      focusNode: _focus,
                      enabled: enabled,
                      style: textStyle,
                      textAlign: widget.textAlign,
                      cursorColor: c.accentText,
                      cursorWidth: 1.5,
                      maxLines: 1,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9a-zA-Z%°+\-*/().×÷ ]'),
                        ),
                      ],
                      onEditingComplete: () {
                        _commit();
                        _selectAll();
                        // Hand focus back so editor shortcuts work again.
                        releaseFocusToAncestor(_focus);
                      },
                      decoration: InputDecoration.collapsed(
                        hintText: widget.mixed ? 'Mixed' : null,
                        hintStyle: textStyle.copyWith(color: c.textSecondary),
                      ),
                    ),
                  ),
                ),
                if (unit != null && !widget.mixed)
                  Padding(
                    padding: const EdgeInsets.only(right: SsSpace.s2),
                    child: ExcludeSemantics(
                      child: Text(
                        unit,
                        style: t.text.caption.copyWith(color: c.textSecondary),
                      ),
                    ),
                  )
                else
                  const SizedBox(width: SsSpace.s2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
