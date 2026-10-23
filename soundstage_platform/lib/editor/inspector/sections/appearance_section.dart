import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../../core/core.dart';
import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';
import '../section_registry.dart';
import 'appearance_blend.dart';

/// Opacity, blend mode, corner radius and smoothing (Figma's "Appearance").
final InspectorSectionSpec appearanceSection = InspectorSectionSpec(
  id: 'appearance',
  title: 'Appearance',
  appliesTo: (info) => !info.isEmpty,
  builder: (context, info) => _AppearanceBody(info: info),
);

class _AppearanceBody extends ConsumerWidget {
  const _AppearanceBody({required this.info});

  final SelectionInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = InspectorScope.of(context).ids;
    final radius =
        info.hasAppearance &&
        ref.watch(_radiusApplicableProvider(ReadKey(ids, 'cornerRadius')));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Grid(
          children: [
            const NumberProp(
              path: 'opacity',
              semanticLabel: 'Opacity',
              unit: '%',
              scale: 100,
              min: 0,
              max: 100,
            ),
            _BlendControl(info: info),
          ],
        ),
        if (radius) const _CornerRadiusControl(),
        if (info.hasAppearance)
          const LabelRow(
            label: 'Smoothing',
            child: NumberProp(
              path: 'cornerSmoothing',
              semanticLabel: 'Corner smoothing',
              unit: '%',
              scale: 100,
              min: 0,
              max: 100,
            ),
          ),
      ],
    );
  }
}

/// Whether a corner radius does anything to a selected node: frames, videos
/// and rectangles (not ellipses, lines, polygons or stars).
final _radiusApplicableProvider = Provider.autoDispose.family<bool, ReadKey>((
  ref,
  key,
) {
  final doc = ref
      .watch(editorControllerProvider.select((s) => Identity(s.document)))
      .value;
  final index = ir.DocumentIndex.of(doc);
  for (final id in key.ids) {
    final n = index.node(id.split('/').first);
    if (n is ir.FrameNode || n is ir.VideoNode) return true;
    if (n is ir.ShapeNode && n.geometry is ir.RectangleGeometry) {
      return true;
    }
  }
  return false;
}, dependencies: [editorControllerProvider]);

/// The blend mode dropdown. An unset mode reads as the kind's default
/// (Pass through for frames, Normal otherwise); choosing the default clears
/// the override.
class _BlendControl extends ConsumerWidget {
  const _BlendControl({required this.info});

  final SelectionInfo info;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, 'blendMode');
    final w = InspectorScope.of(context).writer;
    final allFrames = info.count > 0 && info.frames == info.count;
    final fallback = allFrames
        ? ir.BlendMode.passThrough
        : (info.frames == 0 ? ir.BlendMode.normal : null);
    var mixed = r.mixed;
    String? selected;
    if (!mixed) {
      if (r.value is ir.NoneValue) {
        selected = fallback?.name;
        mixed = fallback == null;
      } else {
        selected = r.enumName;
      }
    }
    final options = blendModeOptions(
      passThrough: allFrames || selected == ir.BlendMode.passThrough.name,
    );
    return FieldFrame.single(
      path: 'blendMode',
      child: SsDropdown<String>(
        key: const ValueKey<String>('field:blendMode'),
        semanticLabel: 'Blend mode',
        value: selected,
        mixed: mixed,
        enabled: r.exists,
        onChanged: (v) => w.set(
          'blendMode',
          v == fallback?.name
              ? const ir.IrValue.none()
              : ir.IrValue.enumValue(v),
        ),
        items: [
          for (final o in options)
            SsDropdownItem<String>(value: o.value, label: o.label),
        ],
      ),
    );
  }
}

const _cornerPaths = [
  'cornerRadius.tl',
  'cornerRadius.tr',
  'cornerRadius.bl',
  'cornerRadius.br',
];
const _cornerLabels = ['TL', 'TR', 'BL', 'BR'];
const _cornerNames = ['Top left', 'Top right', 'Bottom left', 'Bottom right'];

/// A uniform radius field with a toggle to four per-corner fields. The mode
/// follows the stored value; toggling rewrites the whole value in one step.
class _CornerRadiusControl extends ConsumerWidget {
  const _CornerRadiusControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, 'cornerRadius');
    final w = InspectorScope.of(context).writer;
    final value = r.value is ir.CornerRadiusValue
        ? (r.value! as ir.CornerRadiusValue).value
        : null;
    final perCorner = value is ir.CornerRadii;
    final uniform = switch (value) {
      ir.UniformCornerRadius(:final radius) => radius,
      ir.CornerRadii(:final tl) => tl,
      _ => null,
    };

    final toggle = SsIconButton(
      key: const ValueKey<String>('corner-mode'),
      icon: SsIcons.squareRoundCorner,
      semanticLabel: perCorner ? 'Uniform radius' : 'Per-corner radius',
      selected: perCorner,
      size: 24,
      iconSize: 14,
      onPressed: r.exists && uniform != null
          ? () => w.set(
              'cornerRadius',
              ir.IrValue.cornerRadius(
                perCorner
                    ? ir.CornerRadius.uniform(uniform)
                    : ir.CornerRadius.perCorner(
                        tl: uniform,
                        tr: uniform,
                        br: uniform,
                        bl: uniform,
                      ),
              ),
            )
          : null,
    );

    if (!perCorner) {
      return LabelRow(
        label: 'Radius',
        trailing: toggle,
        child: Padding(
          padding: const EdgeInsets.only(right: SsSpace.s1),
          child: FieldFrame.single(
            path: 'cornerRadius',
            child: SsNumberField(
              key: const ValueKey<String>('field:cornerRadius'),
              semanticLabel: 'Corner radius',
              label: 'R',
              unit: 'px',
              value: uniform == null
                  ? null
                  : (uniform * 100).roundToDouble() / 100,
              mixed: r.mixed,
              min: 0,
              enabled: r.exists,
              onChangeStart: w.beginGesture,
              onChangeEnd: w.endGesture,
              onChanged: (x) => w.set(
                'cornerRadius',
                ir.IrValue.cornerRadius(ir.CornerRadius.uniform(x)),
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LabelRow(
          label: 'Radius',
          trailing: toggle,
          child: Text(
            r.mixed ? 'Mixed' : 'Per corner',
            style: context.ss.text.small,
          ),
        ),
        Grid(
          children: [
            for (var i = 0; i < 4; i++)
              NumberProp(
                path: _cornerPaths[i],
                label: _cornerLabels[i],
                semanticLabel: '${_cornerNames[i]} radius',
                min: 0,
              ),
          ],
        ),
      ],
    );
  }
}
