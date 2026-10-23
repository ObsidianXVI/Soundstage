import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

/// Width of the label column of a labelled row.
const double kInspectorLabelWidth = 72;

/// A labelled row: a muted label, then the control filling the rest.
class LabelRow extends StatelessWidget {
  const LabelRow({
    required this.label,
    required this.child,
    this.trailing,
    super.key,
  });

  final String label;
  final Widget child;

  /// Small icon buttons after the control (reset, add).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Row(
        children: [
          SizedBox(
            width: kInspectorLabelWidth,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.text.small.copyWith(color: t.colors.textSecondary),
            ),
          ),
          Expanded(child: child),
          ?trailing,
        ],
      ),
    );
  }
}

/// Controls laid out in equal columns with the standard 8 px gutter: the
/// X/Y, W/H grid of Figma's panels.
class Grid extends StatelessWidget {
  const Grid({required this.children, this.columns = 2, super.key});

  final List<Widget?> children;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i += columns) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: SsSpace.s2),
          child: Row(
            children: [
              for (var j = 0; j < columns; j++) ...[
                if (j > 0) const SizedBox(width: SsSpace.s2),
                Expanded(
                  child: i + j < children.length
                      ? (children[i + j] ?? const SizedBox.shrink())
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

/// A small muted caption above a group of controls.
class GroupLabel extends StatelessWidget {
  const GroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s1),
      child: Text(text, style: t.text.caption),
    );
  }
}
