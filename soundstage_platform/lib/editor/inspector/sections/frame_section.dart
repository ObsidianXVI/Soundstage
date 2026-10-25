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

/// Alignment, position and size, rotation and flips, constraints, and the
/// frame's clip (Figma's "Position" and "Constraints" panels).
final InspectorSectionSpec frameSection = InspectorSectionSpec(
  id: 'frame',
  title: 'Position',
  appliesTo: (info) => !info.isEmpty,
  builder: (context, info) => _FrameBody(info: info),
);

class _FrameBody extends StatelessWidget {
  const _FrameBody({required this.info});

  final SelectionInfo info;

  @override
  Widget build(BuildContext context) {
    // Roots are sized by the breakpoint; in-flow children of auto layout are
    // placed by the layout (their stored x/y place nothing).
    final geometry = info.roots == 0;
    final inFlowOnly =
        info.count > 0 &&
        info.inAutoLayout - info.absoluteInAutoLayout == info.count;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (geometry) const _AlignRow(),
        Grid(
          children: [
            NumberProp(
              path: 'x',
              label: 'X',
              semanticLabel: 'X position',
              unit: 'px',
              enabled: geometry && !inFlowOnly,
            ),
            NumberProp(
              path: 'y',
              label: 'Y',
              semanticLabel: 'Y position',
              unit: 'px',
              enabled: geometry && !inFlowOnly,
            ),
            _SizeProp(
              path: 'width',
              sizingPath: 'layoutChild.horizontalSizing',
              label: 'W',
              semanticLabel: 'Width',
              enabled: geometry,
            ),
            _SizeProp(
              path: 'height',
              sizingPath: 'layoutChild.verticalSizing',
              label: 'H',
              semanticLabel: 'Height',
              enabled: geometry,
            ),
            NumberProp(
              path: 'rotation',
              label: '∠',
              semanticLabel: 'Rotation',
              unit: '°',
              enabled: geometry,
              fractionDigits: 2,
            ),
            const Row(
              children: [
                BoolIconProp(
                  path: 'flipX',
                  icon: SsIcons.flipHorizontal,
                  semanticLabel: 'Flip horizontal',
                ),
                SizedBox(width: SsSpace.s1),
                BoolIconProp(
                  path: 'flipY',
                  icon: SsIcons.flipVertical,
                  semanticLabel: 'Flip vertical',
                ),
              ],
            ),
          ],
        ),
        if (info.anyConstrained) const _Constraints(),
        if (info.absoluteInAutoLayout > 0 || info.inAutoLayout > 0)
          const Padding(
            padding: EdgeInsets.only(bottom: SsSpace.s2),
            child: EnumCheckProp(
              path: 'layoutChild.positioning',
              checkedValue: 'absolute',
              uncheckedValue: 'auto',
              label: 'Ignore auto layout',
            ),
          ),
        if (info.anyFrame)
          const BoolProp(path: 'clipContent', label: 'Clip content'),
      ],
    );
  }
}

/// A width or height: typing or scrubbing a size on a Hug or Fill node makes
/// it Fixed (Figma).
class _SizeProp extends ConsumerWidget {
  const _SizeProp({
    required this.path,
    required this.sizingPath,
    required this.label,
    required this.semanticLabel,
    required this.enabled,
  });

  final String path;
  final String sizingPath;
  final String label;
  final String semanticLabel;
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final sizing = watchReading(context, ref, sizingPath);
    final w = InspectorScope.of(context).writer;
    final v = r.number;
    final notFixed = sizing.mixed || sizing.enumName != ir.Sizing.fixed.name;
    final auto = !sizing.mixed && sizing.enumName == ir.Sizing.hug.name
        ? 'Hug'
        : (!sizing.mixed && sizing.enumName == ir.Sizing.fill.name
              ? 'Fill'
              : null);
    return FieldFrame(
      paths: [path, sizingPath],
      bindPath: path,
      child: SsNumberField(
        key: ValueKey<String>('field:$path'),
        semanticLabel: semanticLabel,
        label: label,
        unit: auto == null ? 'px' : null,
        value: v == null ? null : (v * 100).roundToDouble() / 100,
        mixed: r.mixed,
        min: 0,
        enabled: enabled && r.exists,
        onChangeStart: w.beginGesture,
        onChangeEnd: w.endGesture,
        onChanged: (x) {
          if (notFixed && sizing.exists) {
            w.setMany({
              path: ir.IrValue.number(x),
              sizingPath: ir.IrValue.enumValue(ir.Sizing.fixed.name),
            });
          } else {
            w.set(path, ir.IrValue.number(x));
          }
        },
      ),
    );
  }
}

class _AlignRow extends ConsumerWidget {
  const _AlignRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final w = scope.writer;
    final n = scope.ids.length;
    Widget a(IconData icon, String label, AlignEdge edge) => SsIconButton(
      key: ValueKey<String>('align:${edge.name}'),
      icon: icon,
      semanticLabel: label,
      size: 24,
      onPressed: () => w.run(AlignNodes(scope.ids, edge)),
    );
    Widget d(IconData icon, String label, bool horizontal) => SsIconButton(
      key: ValueKey<String>('distribute:${horizontal ? 'h' : 'v'}'),
      icon: icon,
      semanticLabel: label,
      size: 24,
      onPressed: n >= 3
          ? () => w.run(DistributeNodes(scope.ids, horizontal: horizontal))
          : null,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          a(SsIcons.alignStartVertical, 'Align left', AlignEdge.left),
          a(
            SsIcons.alignCenterVertical,
            'Align horizontal centres',
            AlignEdge.horizontalCenter,
          ),
          a(SsIcons.alignEndVertical, 'Align right', AlignEdge.right),
          a(SsIcons.alignStartHorizontal, 'Align top', AlignEdge.top),
          a(
            SsIcons.alignCenterHorizontal,
            'Align vertical centres',
            AlignEdge.verticalCenter,
          ),
          a(SsIcons.alignEndHorizontal, 'Align bottom', AlignEdge.bottom),
          d(
            SsIcons.alignHorizontalSpaceBetween,
            'Distribute horizontal spacing',
            true,
          ),
          d(
            SsIcons.alignVerticalSpaceBetween,
            'Distribute vertical spacing',
            false,
          ),
        ],
      ),
    );
  }
}

const _hPath = 'layoutChild.constraints.horizontal';
const _vPath = 'layoutChild.constraints.vertical';

SsHConstraint? _h(PropertyReading r) {
  if (r.mixed) return null;
  for (final v in SsHConstraint.values) {
    if (v.name == r.enumName) return v;
  }
  return null;
}

SsVConstraint? _v(PropertyReading r) {
  if (r.mixed) return null;
  for (final v in SsVConstraint.values) {
    if (v.name == r.enumName) return v;
  }
  return null;
}

/// The constraints widget for nodes placed by constraints (children of a
/// free frame, or "ignore auto layout" children).
class _Constraints extends ConsumerWidget {
  const _Constraints();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hr = watchReading(context, ref, _hPath);
    final vr = watchReading(context, ref, _vPath);
    final w = InspectorScope.of(context).writer;
    final h = _h(hr), v = _v(vr);
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const GroupLabel('Constraints'),
          FieldFrame(
            paths: const [_hPath, _vPath],
            child: SsConstraintsWidget(
              key: const ValueKey<String>('constraints'),
              horizontal: h,
              vertical: v,
              onChanged: (nh, nv) {
                final writes = {
                  if (nh != h) _hPath: ir.IrValue.enumValue(nh.name),
                  if (nv != v) _vPath: ir.IrValue.enumValue(nv.name),
                };
                if (writes.isNotEmpty) w.setMany(writes);
              },
            ),
          ),
        ],
      ),
    );
  }
}
