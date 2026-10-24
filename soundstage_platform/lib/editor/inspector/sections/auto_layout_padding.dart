import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';

const _top = 'autoLayout.padding.top';
const _right = 'autoLayout.padding.right';
const _bottom = 'autoLayout.padding.bottom';
const _left = 'autoLayout.padding.left';

/// How the padding is edited: one value, horizontal + vertical, or each
/// side.
enum PaddingMode { uniform, axes, sides }

/// The mode that shows [top]/[right]/[bottom]/[left] without loss: all equal
/// => uniform; left == right and top == bottom => axes; else sides. Unknown
/// (null) sides count as different.
PaddingMode paddingModeOf(
  double? top,
  double? right,
  double? bottom,
  double? left,
) {
  if (top == null || right == null || bottom == null || left == null) {
    return PaddingMode.sides;
  }
  if (top == right && right == bottom && bottom == left) {
    return PaddingMode.uniform;
  }
  if (left == right && top == bottom) return PaddingMode.axes;
  return PaddingMode.sides;
}

/// Auto-layout padding in three modes (Figma's padding fields), toggled by
/// an icon button. The initial mode follows the values; the choice is local
/// UI state, kept until the selection changes. Every mode writes the side
/// paths, so value sources and Mixed work per side; a uniform or axis edit
/// writes its sides together (one undo step).
class PaddingEditor extends ConsumerStatefulWidget {
  const PaddingEditor({super.key});

  @override
  ConsumerState<PaddingEditor> createState() => _PaddingEditorState();
}

class _PaddingEditorState extends ConsumerState<PaddingEditor> {
  PaddingMode? _chosen;
  IdList? _for;

  @override
  Widget build(BuildContext context) {
    final scope = InspectorScope.of(context);
    if (_for != scope.selection) {
      _for = scope.selection;
      _chosen = null;
    }
    final t = watchReading(context, ref, _top);
    final r = watchReading(context, ref, _right);
    final b = watchReading(context, ref, _bottom);
    final l = watchReading(context, ref, _left);
    double? v(PropertyReading x) => x.mixed ? null : x.number;
    final mode = _chosen ?? paddingModeOf(v(t), v(r), v(b), v(l));
    final next = PaddingMode.values[(mode.index + 1) % 3];
    const names = {
      PaddingMode.uniform: 'uniform padding',
      PaddingMode.axes: 'horizontal and vertical padding',
      PaddingMode.sides: 'padding per side',
    };
    final toggle = SsIconButton(
      key: const ValueKey<String>('padding-mode'),
      icon: switch (mode) {
        PaddingMode.uniform => SsIcons.square,
        PaddingMode.axes => SsIcons.arrowLeftRight,
        PaddingMode.sides => SsIcons.scan,
      },
      semanticLabel: 'Padding mode',
      tooltip: 'Switch to ${names[next]}',
      selected: mode == PaddingMode.sides,
      size: 24,
      iconSize: 12,
      onPressed: () => setState(() => _chosen = next),
    );
    final Widget fields = switch (mode) {
      PaddingMode.uniform => const SidesField(
        key: ValueKey<String>('field:autoLayout.padding'),
        paths: [_top, _right, _bottom, _left],
        label: 'P',
        semanticLabel: 'Padding',
      ),
      PaddingMode.axes => const Row(
        children: [
          Expanded(
            child: SidesField(
              key: ValueKey<String>('field:autoLayout.padding.h'),
              paths: [_left, _right],
              label: 'H',
              semanticLabel: 'Horizontal padding',
            ),
          ),
          SizedBox(width: SsSpace.s2),
          Expanded(
            child: SidesField(
              key: ValueKey<String>('field:autoLayout.padding.v'),
              paths: [_top, _bottom],
              label: 'V',
              semanticLabel: 'Vertical padding',
            ),
          ),
        ],
      ),
      PaddingMode.sides => const Grid(
        children: [
          NumberProp(
            path: _left,
            label: 'L',
            semanticLabel: 'Left padding',
            min: 0,
          ),
          NumberProp(
            path: _top,
            label: 'T',
            semanticLabel: 'Top padding',
            min: 0,
          ),
          NumberProp(
            path: _right,
            label: 'R',
            semanticLabel: 'Right padding',
            min: 0,
          ),
          NumberProp(
            path: _bottom,
            label: 'B',
            semanticLabel: 'Bottom padding',
            min: 0,
          ),
        ],
      ),
    };
    return Padding(
      padding: EdgeInsets.only(
        bottom: mode == PaddingMode.sides ? 0 : SsSpace.s2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: fields),
          const SizedBox(width: SsSpace.s1),
          toggle,
        ],
      ),
    );
  }
}

/// One number field editing several padding sides together: it shows their
/// shared value (Mixed when they differ) and writes all of them at once.
class SidesField extends ConsumerWidget {
  const SidesField({
    required this.paths,
    required this.label,
    required this.semanticLabel,
    super.key,
  });

  final List<String> paths;
  final String label;
  final String semanticLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final readings = [for (final p in paths) watchReading(context, ref, p)];
    final w = InspectorScope.of(context).writer;
    final first = readings.first.number;
    final mixed = readings.any((r) => r.mixed || r.number != first);
    return FieldFrame(
      paths: paths,
      child: SsNumberField(
        semanticLabel: semanticLabel,
        label: label,
        unit: 'px',
        value: first,
        mixed: mixed,
        min: 0,
        enabled: readings.first.exists,
        onChangeStart: w.beginGesture,
        onChangeEnd: w.endGesture,
        onChanged: (x) =>
            w.setMany({for (final p in paths) p: ir.IrValue.number(x)}),
      ),
    );
  }
}
