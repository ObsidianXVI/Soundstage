import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'toggle.dart';

/// A position on one axis of the 3x3 matrix.
enum SsAlign3 { start, center, end }

/// Figma-style 3x3 alignment matrix for an auto-layout container, with an
/// optional "space between" mode.
///
/// [direction] is the container's main axis. With [spaceBetween] the
/// main-axis position is inert (items spread along it), so only the
/// cross-axis choice matters and the selected row/column shows as a line of
/// dots. A null [horizontal]/[vertical] means "mixed".
///
/// One tab stop; arrow keys move the selection.
class SsAlignmentMatrix extends StatefulWidget {
  const SsAlignmentMatrix({
    required this.horizontal,
    required this.vertical,
    required this.onChanged,
    this.direction = Axis.horizontal,
    this.spaceBetween = false,
    this.onSpaceBetweenChanged,
    this.size = 60,
    super.key,
  });

  final SsAlign3? horizontal;
  final SsAlign3? vertical;
  final void Function(SsAlign3 horizontal, SsAlign3 vertical)? onChanged;
  final Axis direction;
  final bool spaceBetween;

  /// Shows the "Space between" toggle when set.
  final ValueChanged<bool>? onSpaceBetweenChanged;
  final double size;

  @override
  State<SsAlignmentMatrix> createState() => _SsAlignmentMatrixState();
}

const _vNames = ['Top', 'Middle', 'Bottom'];
const _hNames = ['left', 'center', 'right'];

String _cellName(int row, int col) {
  if (row == 1 && col == 1) return 'Center';
  if (row == 1) return 'Middle ${_hNames[col]}';
  if (col == 1) return '${_vNames[row]} center';
  return '${_vNames[row]} ${_hNames[col]}';
}

class _SsAlignmentMatrixState extends State<SsAlignmentMatrix> {
  int? _hover;
  bool _focused = false;

  bool get _enabled => widget.onChanged != null;
  int? get _col => widget.horizontal?.index;
  int? get _row => widget.vertical?.index;

  void _select(int row, int col) {
    if (!_enabled) return;
    var r = row;
    var c = col;
    // In space-between the main-axis coordinate is not editable.
    if (widget.spaceBetween) {
      if (widget.direction == Axis.horizontal) {
        c = _col ?? 0;
      } else {
        r = _row ?? 0;
      }
    }
    widget.onChanged!(SsAlign3.values[c], SsAlign3.values[r]);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_enabled || event is KeyUpEvent) return KeyEventResult.ignored;
    var r = _row ?? 0;
    var c = _col ?? 0;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      c = (c - 1).clamp(0, 2);
    } else if (k == LogicalKeyboardKey.arrowRight) {
      c = (c + 1).clamp(0, 2);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      r = (r - 1).clamp(0, 2);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      r = (r + 1).clamp(0, 2);
    } else {
      return KeyEventResult.ignored;
    }
    _select(r, c);
    return KeyEventResult.handled;
  }

  bool _isOn(int row, int col) {
    if (widget.spaceBetween) {
      return widget.direction == Axis.horizontal ? row == _row : col == _col;
    }
    return row == _row && col == _col;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final s = widget.size;
    final grid = Focus(
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(
        () => _focused =
            f &&
            FocusManager.instance.highlightMode ==
                FocusHighlightMode.traditional,
      ),
      canRequestFocus: _enabled,
      child: Semantics(
        container: true,
        label: 'Alignment',
        focusable: _enabled,
        child: AnimatedContainer(
          duration: SsMotion.fast,
          width: s,
          height: s,
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: SsRadius.brMd,
            border: Border.all(
              color: _focused ? c.focusRing : c.border,
              width: _focused ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              for (var r = 0; r < 3; r++)
                Expanded(
                  child: Row(
                    children: [
                      for (var col = 0; col < 3; col++)
                        Expanded(child: _cell(r, col)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (widget.onSpaceBetweenChanged == null) return grid;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        grid,
        const SizedBox(height: SsSpace.s2),
        SsToggle(
          value: widget.spaceBetween,
          onChanged: widget.onSpaceBetweenChanged,
          label: 'Space between',
        ),
      ],
    );
  }

  Widget _cell(int row, int col) {
    final c = context.ss.colors;
    final on = _isOn(row, col);
    final exact = row == _row && col == _col;
    final idx = row * 3 + col;
    final hovered = _hover == idx && _enabled;
    // The marker: a dot; in space-between a short bar along the main axis.
    final horizontalBar =
        widget.spaceBetween && widget.direction == Axis.horizontal;
    final verticalBar =
        widget.spaceBetween && widget.direction == Axis.vertical;
    final w = on && horizontalBar ? 10.0 : (on ? 6.0 : 4.0);
    final h = on && verticalBar ? 10.0 : (on ? 6.0 : 4.0);
    return Semantics(
      label: _cellName(row, col),
      selected: exact,
      button: true,
      enabled: _enabled,
      onTap: _enabled ? () => _select(row, col) : null,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = idx),
        onExit: (_) => setState(() => _hover = null),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _select(row, col),
          child: Center(
            child: AnimatedContainer(
              duration: SsMotion.fast,
              width: w,
              height: h,
              decoration: BoxDecoration(
                color: on
                    ? (_enabled ? c.accent : c.textDisabled)
                    : hovered
                    ? c.textSecondary
                    : c.borderStrong,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
