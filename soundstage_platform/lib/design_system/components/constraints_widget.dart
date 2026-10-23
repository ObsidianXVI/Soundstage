import 'package:flutter/material.dart';

import '../tokens/motion.dart';
import '../tokens/spacing.dart';
import '../tokens/theme.dart';
import 'interactive.dart';
import 'segmented.dart';

/// Horizontal constraint of a node in its parent.
enum SsHConstraint { left, right, leftRight, center, scale }

/// Vertical constraint of a node in its parent.
enum SsVConstraint { top, bottom, topBottom, center, scale }

/// The result of clicking the left edge line.
SsHConstraint hConstraintAfterLeft(SsHConstraint? current) => switch (current) {
  SsHConstraint.right => SsHConstraint.leftRight,
  SsHConstraint.leftRight => SsHConstraint.right,
  _ => SsHConstraint.left,
};

/// The result of clicking the right edge line.
SsHConstraint hConstraintAfterRight(SsHConstraint? current) =>
    switch (current) {
      SsHConstraint.left => SsHConstraint.leftRight,
      SsHConstraint.leftRight => SsHConstraint.left,
      _ => SsHConstraint.right,
    };

/// The result of clicking the top edge line.
SsVConstraint vConstraintAfterTop(SsVConstraint? current) => switch (current) {
  SsVConstraint.bottom => SsVConstraint.topBottom,
  SsVConstraint.topBottom => SsVConstraint.bottom,
  _ => SsVConstraint.top,
};

/// The result of clicking the bottom edge line.
SsVConstraint vConstraintAfterBottom(SsVConstraint? current) =>
    switch (current) {
      SsVConstraint.top => SsVConstraint.topBottom,
      SsVConstraint.topBottom => SsVConstraint.top,
      _ => SsVConstraint.bottom,
    };

/// Figma's constraints widget: a square with the four edge lines to click,
/// a centre box (sets both axes to centre), and an always-visible segmented
/// choice per axis (the only way to pick Scale). A null value is "mixed"
/// (nothing selected).
///
/// With at least [wideBreakpoint] px of width the choices sit beside the
/// square; narrower, below it.
class SsConstraintsWidget extends StatelessWidget {
  const SsConstraintsWidget({
    required this.horizontal,
    required this.vertical,
    required this.onChanged,
    super.key,
  });

  static const double wideBreakpoint = 340;

  final SsHConstraint? horizontal;
  final SsVConstraint? vertical;
  final void Function(SsHConstraint horizontal, SsVConstraint vertical)?
  onChanged;

  void _h(SsHConstraint h) => onChanged?.call(h, vertical ?? SsVConstraint.top);
  void _v(SsVConstraint v) =>
      onChanged?.call(horizontal ?? SsHConstraint.left, v);

  @override
  Widget build(BuildContext context) {
    final h = horizontal;
    final v = vertical;
    final hScale = h == SsHConstraint.scale;
    final vScale = v == SsVConstraint.scale;
    final diagram = SizedBox(
      width: 64,
      height: 64,
      child: _Diagram(
        left: h == SsHConstraint.left || h == SsHConstraint.leftRight || hScale,
        right:
            h == SsHConstraint.right || h == SsHConstraint.leftRight || hScale,
        top: v == SsVConstraint.top || v == SsVConstraint.topBottom || vScale,
        bottom:
            v == SsVConstraint.bottom || v == SsVConstraint.topBottom || vScale,
        centerH: h == SsHConstraint.center,
        centerV: v == SsVConstraint.center,
        dashed: hScale || vScale,
        enabled: onChanged != null,
        onLeft: () => _h(hConstraintAfterLeft(h)),
        onRight: () => _h(hConstraintAfterRight(h)),
        onTop: () => _v(vConstraintAfterTop(v)),
        onBottom: () => _v(vConstraintAfterBottom(v)),
        onCenter: () =>
            onChanged?.call(SsHConstraint.center, SsVConstraint.center),
      ),
    );
    final enabled = onChanged != null;
    final choices = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SsSegmented<SsHConstraint>(
          semanticLabel: 'Horizontal constraint',
          expand: true,
          selected: h,
          onChanged: enabled ? _h : null,
          segments: const [
            SsSegment(value: SsHConstraint.left, label: 'Left'),
            SsSegment(value: SsHConstraint.right, label: 'Right'),
            SsSegment(
              value: SsHConstraint.leftRight,
              label: 'Both',
              semanticLabel: 'Left and right',
            ),
            SsSegment(value: SsHConstraint.center, label: 'Center'),
            SsSegment(value: SsHConstraint.scale, label: 'Scale'),
          ],
        ),
        const SizedBox(height: SsSpace.s2),
        SsSegmented<SsVConstraint>(
          semanticLabel: 'Vertical constraint',
          expand: true,
          selected: v,
          onChanged: enabled ? _v : null,
          segments: const [
            SsSegment(value: SsVConstraint.top, label: 'Top'),
            SsSegment(value: SsVConstraint.bottom, label: 'Bottom'),
            SsSegment(
              value: SsVConstraint.topBottom,
              label: 'Both',
              semanticLabel: 'Top and bottom',
            ),
            SsSegment(value: SsVConstraint.center, label: 'Center'),
            SsSegment(value: SsVConstraint.scale, label: 'Scale'),
          ],
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= wideBreakpoint) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              diagram,
              const SizedBox(width: SsSpace.s3),
              Expanded(child: choices),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(alignment: Alignment.centerLeft, child: diagram),
            const SizedBox(height: SsSpace.s3),
            choices,
          ],
        );
      },
    );
  }
}

class _Diagram extends StatelessWidget {
  const _Diagram({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.centerH,
    required this.centerV,
    required this.dashed,
    required this.enabled,
    required this.onLeft,
    required this.onRight,
    required this.onTop,
    required this.onBottom,
    required this.onCenter,
  });

  final bool left;
  final bool right;
  final bool top;
  final bool bottom;
  final bool centerH;
  final bool centerV;
  final bool dashed;
  final bool enabled;
  final VoidCallback onLeft;
  final VoidCallback onRight;
  final VoidCallback onTop;
  final VoidCallback onBottom;
  final VoidCallback onCenter;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    const inner = 22.0;
    Widget line({
      required String label,
      required bool on,
      required VoidCallback tap,
      required Alignment at,
      required bool vertical,
    }) {
      return Align(
        alignment: at,
        child: SsInteractive(
          enabled: enabled,
          selected: on,
          semanticLabel: label,
          excludeSemantics: true,
          onTap: tap,
          builder: (context, s) {
            final hover = s.contains(WidgetState.hovered);
            final color = on
                ? (dashed ? c.accentText : c.accent)
                : hover
                ? c.textSecondary
                : c.borderStrong;
            return SizedBox(
              // The hit area is wider than the 2 px line.
              width: vertical ? 14 : 20,
              height: vertical ? 20 : 14,
              child: Center(
                child: AnimatedContainer(
                  duration: SsMotion.fast,
                  width: vertical ? 2 : 14,
                  height: vertical ? 14 : 2,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: SsRadius.brMd,
        border: Border.all(color: c.border),
      ),
      child: Stack(
        children: [
          Center(
            child: SsInteractive(
              enabled: enabled,
              selected: centerH && centerV,
              semanticLabel: 'Center on both axes',
              excludeSemantics: true,
              onTap: onCenter,
              builder: (context, s) => Container(
                width: inner,
                height: inner,
                decoration: BoxDecoration(
                  color: (centerH || centerV)
                      ? c.selection
                      : s.contains(WidgetState.hovered)
                      ? c.hoverLayer
                      : const Color(0x00000000),
                  borderRadius: SsRadius.brSm,
                  border: Border.all(
                    color: (centerH || centerV) ? c.accent : c.borderStrong,
                  ),
                ),
              ),
            ),
          ),
          line(
            label: 'Pin to left',
            on: left,
            tap: onLeft,
            at: Alignment.centerLeft,
            vertical: false,
          ),
          line(
            label: 'Pin to right',
            on: right,
            tap: onRight,
            at: Alignment.centerRight,
            vertical: false,
          ),
          line(
            label: 'Pin to top',
            on: top,
            tap: onTop,
            at: Alignment.topCenter,
            vertical: true,
          ),
          line(
            label: 'Pin to bottom',
            on: bottom,
            tap: onBottom,
            at: Alignment.bottomCenter,
            vertical: true,
          ),
        ],
      ),
    );
  }
}
