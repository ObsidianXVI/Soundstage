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
import 'appearance_style_banner.dart';
import 'paint_stack.dart';
import 'style_picker.dart';

const String _paintsPath = 'strokes.paints';
const String _weightPath = 'strokes.weight';
const String _dashPath = 'strokes.dash';

/// The stroke paints and geometry: weight, position, caps and joins, dashes.
final InspectorSectionSpec strokeSection = InspectorSectionSpec(
  id: 'stroke',
  title: 'Stroke',
  appliesTo: (info) => info.hasStroke,
  builder: (context, info) => const _StrokeBody(),
  actions: (context, info) => const [
    StylePickerButton(
      kind: ir.StyleKind.paint,
      stylePath: 'strokeStyleId',
      valuePath: _paintsPath,
    ),
    AddPaintButton(stackPath: _paintsPath),
  ],
);

/// The name of the paint style the whole selection shares, or null.
final _strokeStyleProvider = Provider.autoDispose.family<String?, ReadKey>((
  ref,
  key,
) {
  final doc = ref
      .watch(editorControllerProvider.select((s) => Identity(s.document)))
      .value;
  final index = ir.DocumentIndex.of(doc);
  String? common;
  var first = true;
  for (final id in key.ids) {
    final n = index.node(id.split('/').first);
    final style = switch (n) {
      ir.FrameNode(:final appearance) ||
      ir.ShapeNode(:final appearance) ||
      ir.VideoNode(:final appearance) => appearance.strokeStyleId,
      ir.TextNode(:final appearance) => appearance.strokeStyleId,
      _ => null,
    };
    if (first) {
      common = style;
      first = false;
    } else if (style != common) {
      return null;
    }
  }
  if (common == null) return null;
  return doc.tokens.paintStyles[common]?.name ?? common;
}, dependencies: [editorControllerProvider]);

/// Whether per-side weights are available: frames and rectangles (Figma).
final _perSideProvider = Provider.autoDispose.family<bool, ReadKey>((ref, key) {
  final doc = ref
      .watch(editorControllerProvider.select((s) => Identity(s.document)))
      .value;
  final index = ir.DocumentIndex.of(doc);
  for (final id in key.ids) {
    final n = index.node(id.split('/').first);
    final ok =
        n is ir.FrameNode ||
        (n is ir.ShapeNode && n.geometry is ir.RectangleGeometry);
    if (!ok) return false;
  }
  return key.ids.isNotEmpty;
}, dependencies: [editorControllerProvider]);

class _StrokeBody extends ConsumerWidget {
  const _StrokeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final w = scope.writer;
    final paints = watchReading(context, ref, _paintsPath);
    final style = ref.watch(
      _strokeStyleProvider(ReadKey(scope.ids, 'strokeStyleId')),
    );
    final value = paints.value;
    final hasPaints =
        paints.mixed || (value is ir.PaintsValue && value.value.isNotEmpty);
    final join = watchReading(context, ref, 'strokes.join');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (style != null)
          StyleBanner(
            bannerKey: const ValueKey<String>('stroke-style'),
            name: style,
            onDetach: () => w.setMany({
              _paintsPath: value ?? const ir.IrValue.paints([]),
              'strokeStyleId': const ir.IrValue.none(),
            }),
          ),
        const PaintStackEditor(stackPath: _paintsPath, allowImage: false),
        if (hasPaints) ...[
          const _WeightControl(),
          const _Labeled(
            label: 'Position',
            child: EnumProp(
              path: 'strokes.align',
              semanticLabel: 'Stroke position',
              options: [
                EnumOption('inside', 'Inside'),
                EnumOption('center', 'Center'),
                EnumOption('outside', 'Outside'),
              ],
            ),
          ),
          const Grid(
            children: [
              _Labeled(
                label: 'Cap',
                child: EnumProp(
                  path: 'strokes.cap',
                  dropdown: true,
                  semanticLabel: 'Stroke cap',
                  options: [
                    EnumOption('none', 'None'),
                    EnumOption('round', 'Round'),
                    EnumOption('square', 'Square'),
                  ],
                ),
              ),
              _Labeled(
                label: 'Join',
                child: EnumProp(
                  path: 'strokes.join',
                  dropdown: true,
                  semanticLabel: 'Stroke join',
                  options: [
                    EnumOption('miter', 'Miter'),
                    EnumOption('bevel', 'Bevel'),
                    EnumOption('round', 'Round'),
                  ],
                ),
              ),
            ],
          ),
          if (!join.mixed && join.enumName == ir.StrokeJoin.miter.name)
            const LabelRow(
              label: 'Miter limit',
              child: NumberProp(
                path: 'strokes.miterLimit',
                semanticLabel: 'Miter limit',
                min: 1,
              ),
            ),
          const _DashEditor(),
        ],
      ],
    );
  }
}

/// A caption above a control.
class _Labeled extends StatelessWidget {
  const _Labeled({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: SsSpace.s2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [GroupLabel(label), child],
    ),
  );
}

/// A uniform weight field with a toggle to per-side weights (frames and
/// rectangles). Toggling rewrites the whole value in one undo step.
class _WeightControl extends ConsumerWidget {
  const _WeightControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final w = scope.writer;
    final r = watchReading(context, ref, _weightPath);
    final allowed = ref.watch(
      _perSideProvider(ReadKey(scope.ids, _weightPath)),
    );
    final value = r.value is ir.StrokeWeightValue
        ? (r.value! as ir.StrokeWeightValue).value
        : null;
    final perSide = value is ir.PerSideStrokeWeight;
    final uniform = switch (value) {
      ir.UniformStrokeWeight(:final weight) => weight,
      ir.PerSideStrokeWeight(:final top) => top,
      _ => null,
    };
    final toggle = allowed || perSide
        ? SsIconButton(
            key: const ValueKey<String>('weight-mode'),
            icon: SsIcons.square,
            semanticLabel: perSide ? 'Uniform weight' : 'Per-side weight',
            selected: perSide,
            size: 24,
            iconSize: 14,
            onPressed: r.exists && uniform != null
                ? () => w.set(
                    _weightPath,
                    ir.IrValue.strokeWeight(
                      perSide
                          ? ir.StrokeWeight.uniform(uniform)
                          : ir.StrokeWeight.perSide(
                              top: uniform,
                              right: uniform,
                              bottom: uniform,
                              left: uniform,
                            ),
                    ),
                  )
                : null,
          )
        : null;
    if (!perSide) {
      return LabelRow(
        label: 'Weight',
        trailing: toggle,
        child: Padding(
          padding: EdgeInsets.only(right: toggle == null ? 0 : SsSpace.s1),
          child: FieldFrame.single(
            path: _weightPath,
            child: SsNumberField(
              key: const ValueKey<String>('field:$_weightPath'),
              semanticLabel: 'Stroke weight',
              label: 'W',
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
                _weightPath,
                ir.IrValue.strokeWeight(ir.StrokeWeight.uniform(x)),
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
          label: 'Weight',
          trailing: toggle,
          child: Text(
            r.mixed ? 'Mixed' : 'Per side',
            style: context.ss.text.small,
          ),
        ),
        const Grid(
          children: [
            NumberProp(
              path: 'strokes.weight.top',
              label: 'T',
              semanticLabel: 'Top weight',
              min: 0,
            ),
            NumberProp(
              path: 'strokes.weight.right',
              label: 'R',
              semanticLabel: 'Right weight',
              min: 0,
            ),
            NumberProp(
              path: 'strokes.weight.bottom',
              label: 'B',
              semanticLabel: 'Bottom weight',
              min: 0,
            ),
            NumberProp(
              path: 'strokes.weight.left',
              label: 'L',
              semanticLabel: 'Left weight',
              min: 0,
            ),
          ],
        ),
      ],
    );
  }
}

const List<double> _defaultDash = [8, 4];

/// Solid / Dashed, and the dash and gap lengths of a dashed stroke. The
/// pattern is `[dash, gap]`; an empty pattern is solid.
class _DashEditor extends ConsumerWidget {
  const _DashEditor();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, _dashPath);
    final w = InspectorScope.of(context).writer;
    final list = r.value is ir.NumbersValue
        ? (r.value! as ir.NumbersValue).value
        : const <double>[];
    final dashed = list.isNotEmpty;
    final dash = dashed ? list[0] : 0.0;
    final gap = list.length > 1 ? list[1] : dash;

    void write(double d, double g) => w.set(
      _dashPath,
      d == 0 && g == 0
          ? const ir.IrValue.numbers([])
          : ir.IrValue.numbers([d, g]),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Labeled(
          label: 'Dashes',
          child: FieldFrame.single(
            path: _dashPath,
            child: SsSegmented<String>(
              key: const ValueKey<String>('field:$_dashPath'),
              semanticLabel: 'Dash style',
              expand: true,
              selected: r.mixed ? null : (dashed ? 'dashed' : 'solid'),
              onChanged: r.exists
                  ? (v) => w.set(
                      _dashPath,
                      ir.IrValue.numbers(
                        v == 'dashed' ? _defaultDash : const [],
                      ),
                    )
                  : null,
              segments: const [
                SsSegment(value: 'solid', label: 'Solid'),
                SsSegment(value: 'dashed', label: 'Dashed'),
              ],
            ),
          ),
        ),
        if (dashed && !r.mixed)
          Grid(
            children: [
              FieldFrame.single(
                path: _dashPath,
                child: SsNumberField(
                  key: const ValueKey<String>('field:$_dashPath.dash'),
                  semanticLabel: 'Dash length',
                  label: 'Dash',
                  value: dash,
                  min: 0,
                  onChangeStart: w.beginGesture,
                  onChangeEnd: w.endGesture,
                  onChanged: (x) => write(x, gap),
                ),
              ),
              FieldFrame.single(
                path: _dashPath,
                child: SsNumberField(
                  key: const ValueKey<String>('field:$_dashPath.gap'),
                  semanticLabel: 'Gap length',
                  label: 'Gap',
                  value: gap,
                  min: 0,
                  onChangeStart: w.beginGesture,
                  onChangeEnd: w.endGesture,
                  onChanged: (x) => write(dash, x),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
