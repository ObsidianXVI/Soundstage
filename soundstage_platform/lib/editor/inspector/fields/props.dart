import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart' show stageColor;

import '../inspector_providers.dart';
import '../property_writer.dart';
import 'field_frame.dart';

// The registry-driven controls. Each is one property path plus a control
// kind: it reads the path through [propertyReadingProvider] (so it rebuilds
// only when its own value changes), writes through the scope's
// [PropertyWriter], and wraps itself in the value-source chrome.

/// Reads [path] of the scope's selection. Widgets using this rebuild only
/// when this property's reading changes.
PropertyReading watchReading(BuildContext context, WidgetRef ref, String path) {
  final scope = InspectorScope.of(context);
  return ref.watch(propertyReadingProvider(ReadKey(scope.ids, path)));
}

double _round(double v) => (v * 1e6).roundToDouble() / 1e6;

/// A number field (scrub, arithmetic, "Mixed").
///
/// - [scale]: display = stored x scale (opacity 0..1 is shown as 0..100 %).
/// - [label]: the short label drawn inside the field (`X`, `W`).
class NumberProp extends ConsumerWidget {
  const NumberProp({
    required this.path,
    required this.semanticLabel,
    this.label,
    this.unit,
    this.scale = 1,
    this.min,
    this.max,
    this.step = 1,
    this.fractionDigits = 2,
    this.enabled = true,
    this.shared = false,
    super.key,
  });

  final String path;
  final String semanticLabel;
  final String? label;
  final String? unit;
  final double scale;
  final double? min;
  final double? max;
  final double step;
  final int fractionDigits;
  final bool enabled;

  /// Write to the shared base regardless of the edit scope.
  final bool shared;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final v = r.number;
    return FieldFrame.single(
      path: path,
      child: SsNumberField(
        key: ValueKey<String>('field:$path'),
        semanticLabel: semanticLabel,
        label: label,
        unit: unit,
        value: v == null ? null : _round(v * scale),
        mixed: r.mixed,
        min: min,
        max: max,
        step: step,
        fractionDigits: fractionDigits,
        enabled: enabled && r.exists,
        onChangeStart: w.beginGesture,
        onChangeEnd: w.endGesture,
        onChanged: (x) =>
            w.set(path, ir.IrValue.number(_round(x / scale)), shared: shared),
      ),
    );
  }
}

/// A choice of an enum property.
class EnumOption {
  const EnumOption(this.value, this.label, {this.icon, this.tooltip});

  /// The serialised enum name.
  final String value;
  final String label;
  final IconData? icon;
  final String? tooltip;
}

/// An enum property as a segmented control, or a dropdown for long lists.
class EnumProp extends ConsumerWidget {
  const EnumProp({
    required this.path,
    required this.options,
    required this.semanticLabel,
    this.dropdown = false,
    this.iconOnly = false,
    this.shared = false,
    super.key,
  });

  final String path;
  final List<EnumOption> options;
  final String semanticLabel;
  final bool dropdown;

  /// Segments show their icon only (the label is the tooltip).
  final bool iconOnly;
  final bool shared;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final selected = r.mixed ? null : r.enumName;
    void write(String v) =>
        w.set(path, ir.IrValue.enumValue(v), shared: shared);
    return FieldFrame.single(
      path: path,
      child: dropdown
          ? SsDropdown<String>(
              key: ValueKey<String>('field:$path'),
              semanticLabel: semanticLabel,
              value: selected,
              mixed: r.mixed,
              enabled: r.exists,
              onChanged: write,
              items: [
                for (final o in options)
                  SsDropdownItem(value: o.value, label: o.label, icon: o.icon),
              ],
            )
          : SsSegmented<String>(
              key: ValueKey<String>('field:$path'),
              semanticLabel: semanticLabel,
              expand: true,
              selected: selected,
              onChanged: r.exists ? write : null,
              segments: [
                for (final o in options)
                  SsSegment(
                    value: o.value,
                    label: iconOnly && o.icon != null ? null : o.label,
                    icon: o.icon,
                    semanticLabel: o.tooltip ?? o.label,
                  ),
              ],
            ),
    );
  }
}

/// A boolean property as a checkbox with a label ("Clip content").
class BoolProp extends ConsumerWidget {
  const BoolProp({
    required this.path,
    required this.label,
    this.shared = false,
    super.key,
  });

  final String path;
  final String label;
  final bool shared;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    return FieldFrame.single(
      path: path,
      child: SsCheckbox(
        key: ValueKey<String>('field:$path'),
        label: label,
        value: r.mixed ? null : r.boolean,
        onChanged: r.exists
            ? (v) => w.set(path, ir.IrValue.boolean(v), shared: shared)
            : null,
      ),
    );
  }
}

/// A colour property.
class ColorProp extends ConsumerWidget {
  const ColorProp({
    required this.path,
    this.semanticLabel = 'Colour',
    super.key,
  });

  final String path;
  final String semanticLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final value = r.value;
    final c = value is ir.ColorValue ? value.value : ir.StageColor.black;
    return FieldFrame.single(
      path: path,
      child: SsColorField(
        key: ValueKey<String>('field:$path'),
        semanticLabel: semanticLabel,
        color: stageColor(c),
        mixed: r.mixed,
        onChangeStart: w.beginGesture,
        onChangeEnd: w.endGesture,
        onChanged: (color) =>
            w.set(path, ir.IrValue.color(stageColorOf(color))),
      ),
    );
  }
}

/// A Flutter colour as an IR colour.
ir.StageColor stageColorOf(Color c) =>
    ir.StageColor(r: c.r, g: c.g, b: c.b, a: c.a);

/// A nullable number property (min/max sizes): the field is shown only when
/// set. [OptionalNumberProp.menuEntry] offers it in a "+" menu when unset.
class OptionalNumberProp extends ConsumerWidget {
  const OptionalNumberProp({
    required this.path,
    required this.label,
    required this.semanticLabel,
    this.min,
    super.key,
  });

  final String path;
  final String label;
  final String semanticLabel;
  final double? min;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    if (!r.exists || (r.value is ir.NoneValue && !r.mixed)) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        Expanded(
          child: NumberProp(
            path: path,
            label: label,
            semanticLabel: semanticLabel,
            min: min,
          ),
        ),
        SsIconButton(
          icon: SsIcons.minus,
          semanticLabel: 'Remove $semanticLabel',
          size: 24,
          iconSize: 12,
          onPressed: () => w.set(path, const ir.IrValue.none()),
        ),
      ],
    );
  }
}

/// A boolean property as a toggle icon button (flip X, flip Y).
class BoolIconProp extends ConsumerWidget {
  const BoolIconProp({
    required this.path,
    required this.icon,
    required this.semanticLabel,
    this.shared = false,
    super.key,
  });

  final String path;
  final IconData icon;
  final String semanticLabel;
  final bool shared;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final on = !r.mixed && r.boolean == true;
    return FieldFrame.single(
      path: path,
      child: SsIconButton(
        key: ValueKey<String>('field:$path'),
        icon: icon,
        semanticLabel: semanticLabel,
        selected: on,
        onPressed: r.exists
            ? () => w.set(path, ir.IrValue.boolean(!on), shared: shared)
            : null,
      ),
    );
  }
}

/// A two-valued enum property shown as a checkbox ("Ignore auto layout" is
/// `layoutChild.positioning == absolute`).
class EnumCheckProp extends ConsumerWidget {
  const EnumCheckProp({
    required this.path,
    required this.checkedValue,
    required this.uncheckedValue,
    required this.label,
    super.key,
  });

  final String path;
  final String checkedValue;
  final String uncheckedValue;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final checked = r.enumName == checkedValue;
    return FieldFrame.single(
      path: path,
      child: SsCheckbox(
        key: ValueKey<String>('field:$path'),
        label: label,
        value: r.mixed ? null : checked,
        onChanged: r.exists
            ? (v) => w.set(
                path,
                ir.IrValue.enumValue(v ? checkedValue : uncheckedValue),
              )
            : null,
      ),
    );
  }
}
