import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../icons/ss_icons.dart';
import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'icon.dart';
import 'interactive.dart';
import 'tooltip.dart';

/// A row of a layers/scenes tree: indent, disclosure, icon, label with
/// inline rename, and visibility / lock toggles.
///
/// Keyboard: Enter/Space select, Left/Right collapse/expand, F2 renames.
/// Double-clicking the label also renames. While renaming, Enter commits,
/// Escape cancels, blur commits.
class SsTreeRow extends StatefulWidget {
  const SsTreeRow({
    required this.label,
    this.depth = 0,
    this.icon,
    this.hasChildren = false,
    this.expanded = false,
    this.selected = false,
    this.visible = true,
    this.locked = false,
    this.showToggles = true,
    this.renameEnabled = true,
    this.dimmed = false,
    this.onTap,
    this.onExpandedChanged,
    this.onRename,
    this.onVisibleChanged,
    this.onLockedChanged,
    this.onSecondaryTapDown,
    this.indent = 16,
    super.key,
  });

  final String label;
  final int depth;
  final IconData? icon;
  final bool hasChildren;
  final bool expanded;
  final bool selected;
  final bool visible;
  final bool locked;

  /// Hide the visibility/lock toggles (they still show on hover).
  final bool showToggles;
  final bool renameEnabled;

  /// Draw the row faded (a hidden node).
  final bool dimmed;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onExpandedChanged;
  final ValueChanged<String>? onRename;
  final ValueChanged<bool>? onVisibleChanged;
  final ValueChanged<bool>? onLockedChanged;
  final GestureTapDownCallback? onSecondaryTapDown;
  final double indent;

  @override
  State<SsTreeRow> createState() => _SsTreeRowState();
}

class _SsTreeRowState extends State<SsTreeRow> {
  bool _renaming = false;
  bool _hovered = false;
  late final TextEditingController _text = TextEditingController();
  final FocusNode _editFocus = FocusNode(debugLabel: 'SsTreeRow.rename');
  final FocusNode _rowFocus = FocusNode(debugLabel: 'SsTreeRow');
  String _original = '';

  @override
  void initState() {
    super.initState();
    _editFocus.addListener(() {
      if (!_editFocus.hasFocus && _renaming) _commit();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _editFocus.dispose();
    _rowFocus.dispose();
    super.dispose();
  }

  void _startRename() {
    if (!widget.renameEnabled || widget.onRename == null || widget.locked) {
      return;
    }
    _original = widget.label;
    _text.text = widget.label;
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.label.length,
    );
    setState(() => _renaming = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editFocus.requestFocus();
    });
  }

  void _commit() {
    if (!_renaming) return;
    final value = _text.text.trim();
    setState(() => _renaming = false);
    if (value.isNotEmpty && value != _original) widget.onRename?.call(value);
    _rowFocus.requestFocus();
  }

  void _cancel() {
    if (!_renaming) return;
    setState(() => _renaming = false);
    _rowFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final w = widget;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: SsInteractive(
        focusNode: _rowFocus,
        selected: w.selected,
        semanticLabel: w.label,
        semanticValue: w.hasChildren
            ? (w.expanded ? 'Expanded' : 'Collapsed')
            : null,
        enabled: !_renaming,
        onTap: w.onTap,
        onDoubleTap: _startRename,
        onSecondaryTapDown: w.onSecondaryTapDown,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final k = event.logicalKey;
          if (k == LogicalKeyboardKey.arrowRight &&
              w.hasChildren &&
              !w.expanded) {
            w.onExpandedChanged?.call(true);
          } else if (k == LogicalKeyboardKey.arrowLeft &&
              w.hasChildren &&
              w.expanded) {
            w.onExpandedChanged?.call(false);
          } else if (k == LogicalKeyboardKey.f2) {
            _startRename();
          } else {
            return KeyEventResult.ignored;
          }
          return KeyEventResult.handled;
        },
        builder: (context, s) {
          final hover = s.contains(WidgetState.hovered) || _hovered;
          final bg = w.selected
              ? c.selection
              : s.contains(WidgetState.pressed)
              ? c.pressedLayer
              : hover
              ? c.hoverLayer
              : const Color(0x00000000);
          final fg = w.dimmed || !w.visible ? c.textDisabled : c.textPrimary;
          final showToggles =
              (w.onVisibleChanged != null || w.onLockedChanged != null) &&
              (w.showToggles || hover || !w.visible || w.locked);
          return SsFocusRing(
            visible: s.contains(WidgetState.focused),
            color: c.focusRing,
            borderRadius: SsRadius.brSm,
            child: AnimatedContainer(
              duration: SsMotion.instant,
              height: SsSpace.controlHeight,
              padding: EdgeInsets.only(
                left: SsSpace.s1 + w.depth * w.indent,
                right: SsSpace.s1,
              ),
              decoration: BoxDecoration(color: bg, borderRadius: SsRadius.brSm),
              child: Row(
                children: [
                  SizedBox(
                    width: 18,
                    child: w.hasChildren
                        ? _Disclosure(
                            expanded: w.expanded,
                            onTap: () => w.onExpandedChanged?.call(!w.expanded),
                          )
                        : null,
                  ),
                  if (w.icon != null) ...[
                    SsIcon(
                      w.icon!,
                      size: 14,
                      color: w.selected
                          ? c.accentText
                          : (fg == c.textPrimary ? c.textSecondary : fg),
                    ),
                    const SizedBox(width: SsSpace.s2),
                  ],
                  Expanded(
                    child: _renaming
                        ? _RenameField(
                            controller: _text,
                            focusNode: _editFocus,
                            onSubmit: _commit,
                            onCancel: _cancel,
                          )
                        : Text(
                            w.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.text.body.copyWith(color: fg),
                          ),
                  ),
                  if (showToggles) ...[
                    _RowToggle(
                      active: w.locked,
                      icon: w.locked ? SsIcons.lock : SsIcons.lockOpen,
                      label: w.locked ? 'Unlock ${w.label}' : 'Lock ${w.label}',
                      shown: w.locked || hover,
                      onTap: w.onLockedChanged == null
                          ? null
                          : () => w.onLockedChanged!(!w.locked),
                    ),
                    _RowToggle(
                      active: !w.visible,
                      icon: w.visible ? SsIcons.eye : SsIcons.eyeOff,
                      label: w.visible ? 'Hide ${w.label}' : 'Show ${w.label}',
                      shown: !w.visible || hover,
                      onTap: w.onVisibleChanged == null
                          ? null
                          : () => w.onVisibleChanged!(!w.visible),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Disclosure extends StatelessWidget {
  const _Disclosure({required this.expanded, required this.onTap});

  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: AnimatedRotation(
          turns: expanded ? 0.25 : 0,
          duration: SsMotion.fast,
          child: const SsIcon(SsIcons.chevronRight, size: 14),
        ),
      ),
    );
  }
}

class _RowToggle extends StatelessWidget {
  const _RowToggle({
    required this.active,
    required this.icon,
    required this.label,
    required this.shown,
    required this.onTap,
  });

  final bool active;
  final IconData icon;
  final String label;

  /// Fully visible (hovered row or active); otherwise just hold the space.
  final bool shown;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return SsTooltip(
      message: label,
      child: SsInteractive(
        onTap: onTap,
        enabled: onTap != null,
        semanticLabel: label,
        excludeSemantics: true,
        builder: (context, s) {
          return SsFocusRing(
            visible: s.contains(WidgetState.focused),
            color: c.focusRing,
            borderRadius: SsRadius.brSm,
            child: SizedBox(
              width: 24,
              height: 24,
              child: Center(
                child: Opacity(
                  opacity: shown ? 1 : 0,
                  child: SsIcon(
                    icon,
                    size: 14,
                    color: active
                        ? c.textPrimary
                        : s.contains(WidgetState.hovered)
                        ? c.textPrimary
                        : c.textSecondary,
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

class _RenameField extends StatelessWidget {
  const _RenameField({
    required this.controller,
    required this.focusNode,
    required this.onSubmit,
    required this.onCancel,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmit;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          onCancel();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: SsSpace.s1),
        decoration: BoxDecoration(
          color: c.surface0,
          borderRadius: SsRadius.brSm,
          border: Border.all(color: c.focusRing),
        ),
        alignment: Alignment.centerLeft,
        child: Semantics(
          label: 'Rename',
          textField: true,
          child: EditableText(
            controller: controller,
            focusNode: focusNode,
            style: t.text.body,
            cursorColor: c.accentText,
            backgroundCursorColor: c.surface3,
            selectionColor: c.selection,
            onSubmitted: (_) => onSubmit(),
            maxLines: 1,
          ),
        ),
      ),
    );
  }
}
