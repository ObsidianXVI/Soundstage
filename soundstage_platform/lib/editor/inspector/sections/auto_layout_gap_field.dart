import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../property_writer.dart';

/// The rectangle of [context]'s render box in global coordinates (a menu
/// anchor).
Rect globalRectOf(BuildContext context) {
  final box = context.findRenderObject()! as RenderBox;
  return box.localToGlobal(Offset.zero) & box.size;
}

/// A [ir.Gap] property (`autoLayout.gap`, `autoLayout.counterAxisGap`):
/// a number field for a fixed gap (negative overlaps), or "Auto"
/// (space between). The chevron menu switches between the two.
class GapField extends ConsumerWidget {
  const GapField({
    required this.path,
    required this.label,
    required this.semanticLabel,
    super.key,
  });

  final String path;

  /// The short scrub label inside the field.
  final String label;
  final String semanticLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final gap = switch (r.value) {
      ir.GapValue(:final value) => value,
      _ => null,
    };
    final auto = !r.mixed && gap is ir.AutoGap;
    final fixed = switch (gap) {
      ir.FixedGap(:final value) => value,
      _ => null,
    };
    void setAuto(bool v) => w.set(
      path,
      ir.IrValue.gap(v ? const ir.Gap.auto() : const ir.Gap.fixed()),
    );

    final Widget field;
    if (auto) {
      field = SsDropdown<bool>(
        key: ValueKey<String>('field:$path'),
        semanticLabel: semanticLabel,
        value: true,
        enabled: r.exists,
        onChanged: setAuto,
        items: const [
          SsDropdownItem(value: true, label: 'Auto'),
          SsDropdownItem(value: false, label: 'Fixed'),
        ],
      );
    } else {
      field = Row(
        children: [
          Expanded(
            child: SsNumberField(
              key: ValueKey<String>('field:$path'),
              semanticLabel: semanticLabel,
              label: label,
              unit: 'px',
              value: fixed,
              mixed: r.mixed,
              enabled: r.exists,
              onChangeStart: w.beginGesture,
              onChangeEnd: w.endGesture,
              onChanged: (x) => w.set(path, ir.IrValue.gap(ir.Gap.fixed(x))),
            ),
          ),
          Builder(
            builder: (bc) => SsIconButton(
              key: ValueKey<String>('gap-menu:$path'),
              icon: SsIcons.chevronDown,
              semanticLabel: '$semanticLabel options',
              size: 24,
              iconSize: 12,
              onPressed: r.exists
                  ? () => showSsMenu(
                      bc,
                      anchor: globalRectOf(bc),
                      minWidth: 120,
                      entries: [
                        SsMenuItem(
                          label: 'Auto',
                          checked: false,
                          onSelected: () => setAuto(true),
                        ),
                        SsMenuItem(
                          label: 'Fixed',
                          checked: !r.mixed,
                          onSelected: () {
                            if (r.mixed) setAuto(false);
                          },
                        ),
                      ],
                    )
                  : null,
            ),
          ),
        ],
      );
    }
    return FieldFrame.single(path: path, child: field);
  }
}
