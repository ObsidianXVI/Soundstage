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
import 'auto_layout_gap_field.dart';
import 'auto_layout_padding.dart';
import 'layout_child_facts.dart';

/// Auto layout of the selected frames (architecture §4.4; Figma's "Auto
/// layout" panel): direction and wrap, alignment and gap, padding, baseline
/// alignment, and the stroke / stacking options. The header adds or removes
/// auto layout.
final InspectorSectionSpec autoLayoutSection = InspectorSectionSpec(
  id: 'auto_layout',
  title: 'Auto layout',
  appliesTo: (info) => info.anyFrame,
  builder: (context, info) => const _AutoLayoutBody(),
  actions: (context, info) => const [_AutoLayoutAction()],
);

const _direction = 'autoLayout.direction';
const _wrap = 'autoLayout.wrap';
const _gap = 'autoLayout.gap';
const _counterGap = 'autoLayout.counterAxisGap';
const _primary = 'autoLayout.primaryAlign';
const _counter = 'autoLayout.counterAlign';
const _rowAlign = 'autoLayout.rowAlign';

/// "+" adds auto layout to the selected frames that lack it; "−" (when every
/// selected frame has it) removes it.
///
/// A single selected frame without a grid, edited on the shared base, uses
/// [AddAutoLayout] (Figma's Shift+A: direction, gap, padding and alignment
/// inferred from the children, which are reordered to the flow). Removal on
/// the shared base uses [RemoveAutoLayout], which keeps the children where
/// they are (their laid-out boxes become stored geometry). Otherwise (several
/// frames, a grid frame, or a "This breakpoint" edit) the `autoLayout`
/// presence property is written: the commands act on the base document
/// only, and AddAutoLayout would wrap several frames in a new one.
class _AutoLayoutAction extends ConsumerWidget {
  const _AutoLayoutAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facts = ref.watch(layoutChildFactsProvider);
    final scope = InspectorScope.of(context);
    final w = scope.writer;
    final missing = facts.freeFrameIds;
    final having = facts.autoLayoutFrameIds;
    if (missing.isEmpty && having.isEmpty) return const SizedBox.shrink();
    if (missing.isNotEmpty) {
      return SsIconButton(
        key: const ValueKey<String>('auto-layout:add'),
        icon: SsIcons.plus,
        semanticLabel: 'Add auto layout',
        shortcut: '⇧A',
        size: 24,
        iconSize: 14,
        onPressed: () {
          final single = facts.nodes.length == 1 ? facts.nodes.single : null;
          if (single != null &&
              !single.hasGrid &&
              !single.isInner &&
              editsShareBase(w)) {
            w.run(AddAutoLayout([single.id]));
          } else {
            PropertyWriter(
              w.controller,
              w.readState,
              missing,
            ).set('autoLayout', const ir.IrValue.boolean(true));
          }
        },
      );
    }
    return SsIconButton(
      key: const ValueKey<String>('auto-layout:remove'),
      icon: SsIcons.minus,
      semanticLabel: 'Remove auto layout',
      size: 24,
      iconSize: 14,
      onPressed: () {
        final inner = facts.nodes.any((n) => n.isInner);
        if (!inner && editsShareBase(w)) {
          w.run(RemoveAutoLayout(having));
        } else {
          PropertyWriter(
            w.controller,
            w.readState,
            having,
          ).set('autoLayout', const ir.IrValue.boolean(false));
        }
      },
    );
  }
}

class _AutoLayoutBody extends ConsumerWidget {
  const _AutoLayoutBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(
      layoutChildFactsProvider.select((f) => IdList(f.autoLayoutFrameIds)),
    );
    if (ids.isEmpty) {
      final t = context.ss;
      return Padding(
        key: const ValueKey<String>('auto-layout:hint'),
        padding: const EdgeInsets.only(bottom: SsSpace.s2),
        child: Text(
          'Add auto layout to stack children in a row or column.',
          style: t.text.small.copyWith(color: t.colors.textSecondary),
        ),
      );
    }
    return SubsetScope(ids: ids.ids, child: const _AutoLayoutControls());
  }
}

class _AutoLayoutControls extends ConsumerWidget {
  const _AutoLayoutControls();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = watchReading(context, ref, _direction);
    final wrap = watchReading(context, ref, _wrap);
    final horizontal =
        !dir.mixed && dir.enumName == ir.LayoutDirection.horizontal.name;
    final wrapped = horizontal && (wrap.mixed || wrap.boolean == true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DirectionRow(),
        Padding(
          padding: const EdgeInsets.only(bottom: SsSpace.s2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _Matrix(),
              const SizedBox(width: SsSpace.s2),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const GapField(
                      path: _gap,
                      label: 'Gap',
                      semanticLabel: 'Gap',
                    ),
                    if (wrapped) ...[
                      const SizedBox(height: SsSpace.s2),
                      const GapField(
                        path: _counterGap,
                        label: 'Row',
                        semanticLabel: 'Row gap',
                      ),
                    ],
                    const SizedBox(height: SsSpace.s2),
                    const _SpaceBetween(),
                  ],
                ),
              ),
            ],
          ),
        ),
        const PaddingEditor(),
        const _BaselineCheck(),
        if (wrapped)
          const LabelRow(
            label: 'Rows',
            child: EnumProp(
              path: _rowAlign,
              semanticLabel: 'Row alignment',
              iconOnly: true,
              options: [
                EnumOption(
                  'start',
                  'Rows at start',
                  icon: SsIcons.alignStartHorizontal,
                ),
                EnumOption(
                  'center',
                  'Rows centred',
                  icon: SsIcons.alignCenterHorizontal,
                ),
                EnumOption(
                  'end',
                  'Rows at end',
                  icon: SsIcons.alignEndHorizontal,
                ),
              ],
            ),
          ),
        const FitStart(
          child: BoolProp(
            path: 'autoLayout.strokesIncludedInLayout',
            label: 'Include strokes in layout',
          ),
        ),
        const SizedBox(height: SsSpace.s1),
        const FitStart(
          child: BoolProp(
            path: 'autoLayout.reverseZIndex',
            label: 'Reverse z-index',
          ),
        ),
        const SizedBox(height: SsSpace.s2),
      ],
    );
  }
}

/// Direction (horizontal / vertical) and the wrap toggle (horizontal only).
/// Switching to vertical also turns wrap and baseline alignment off (both
/// are horizontal-only), in the same undo step.
class _DirectionRow extends ConsumerWidget {
  const _DirectionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = watchReading(context, ref, _direction);
    final wrap = watchReading(context, ref, _wrap);
    final counter = watchReading(context, ref, _counter);
    final w = InspectorScope.of(context).writer;
    final horizontal =
        !dir.mixed && dir.enumName == ir.LayoutDirection.horizontal.name;
    final wrapOn = !wrap.mixed && wrap.boolean == true;
    void setDirection(String d) {
      if (d == ir.LayoutDirection.vertical.name) {
        w.setMany({
          _direction: ir.IrValue.enumValue(d),
          if (wrap.mixed || wrap.boolean == true)
            _wrap: const ir.IrValue.boolean(false),
          if (counter.mixed ||
              counter.enumName == ir.CounterAlign.baseline.name)
            _counter: ir.IrValue.enumValue(ir.CounterAlign.start.name),
        });
      } else {
        w.set(_direction, ir.IrValue.enumValue(d));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: Row(
        children: [
          Expanded(
            child: FieldFrame.single(
              path: _direction,
              child: SsSegmented<String>(
                key: const ValueKey<String>('field:$_direction'),
                semanticLabel: 'Direction',
                expand: true,
                selected: dir.mixed ? null : dir.enumName,
                onChanged: dir.exists ? setDirection : null,
                segments: [
                  SsSegment(
                    value: ir.LayoutDirection.horizontal.name,
                    icon: SsIcons.arrowRight,
                    semanticLabel: 'Horizontal layout',
                  ),
                  SsSegment(
                    value: ir.LayoutDirection.vertical.name,
                    icon: SsIcons.arrowDown,
                    semanticLabel: 'Vertical layout',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: SsSpace.s1),
          FieldFrame.single(
            path: _wrap,
            child: SsIconButton(
              key: const ValueKey<String>('field:$_wrap'),
              icon: SsIcons.wrapText,
              semanticLabel: 'Wrap',
              tooltip: horizontal ? 'Wrap' : 'Wrap (horizontal layouts only)',
              selected: horizontal && wrapOn,
              onPressed: horizontal && wrap.exists
                  ? () => w.set(_wrap, ir.IrValue.boolean(!wrapOn))
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

SsAlign3? _align3(PropertyReading r) {
  if (r.mixed) return null;
  for (final a in SsAlign3.values) {
    if (a.name == r.enumName) return a;
  }
  return null;
}

/// The matrix's horizontal / vertical cell for a primary / counter
/// alignment: the primary axis follows the direction.
({SsAlign3? horizontal, SsAlign3? vertical}) matrixCellOf({
  required bool horizontalLayout,
  required SsAlign3? primary,
  required SsAlign3? counter,
}) => horizontalLayout
    ? (horizontal: primary, vertical: counter)
    : (horizontal: counter, vertical: primary);

/// The 3x3 alignment matrix over `primaryAlign` x `counterAlign`; an auto
/// gap shows as space between. Baseline alignment shows no counter cell.
class _Matrix extends ConsumerWidget {
  const _Matrix();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = watchReading(context, ref, _direction);
    final primary = watchReading(context, ref, _primary);
    final counter = watchReading(context, ref, _counter);
    final gap = watchReading(context, ref, _gap);
    final w = InspectorScope.of(context).writer;
    final known = !dir.mixed && dir.exists;
    final horizontal = dir.enumName == ir.LayoutDirection.horizontal.name;
    final cell = matrixCellOf(
      horizontalLayout: horizontal,
      primary: _align3(primary),
      counter: _align3(counter),
    );
    final spaceBetween =
        !gap.mixed && gap.value == const ir.IrValue.gap(ir.Gap.auto());
    return FieldFrame(
      paths: const [_primary, _counter, _gap],
      child: SsAlignmentMatrix(
        key: const ValueKey<String>('field:autoLayout.align'),
        direction: horizontal ? Axis.horizontal : Axis.vertical,
        horizontal: cell.horizontal,
        vertical: cell.vertical,
        spaceBetween: spaceBetween,
        onChanged: known
            ? (h, v) {
                final p = horizontal ? h : v;
                final c = horizontal ? v : h;
                w.setMany({
                  _primary: ir.IrValue.enumValue(p.name),
                  _counter: ir.IrValue.enumValue(c.name),
                });
              }
            : null,
      ),
    );
  }
}

/// "Space between": an auto gap (the matrix shows its main axis as a line).
/// Off restores a zero fixed gap. A separate row rather than the matrix's
/// built-in toggle, which would widen the matrix column past the gap field.
class _SpaceBetween extends ConsumerWidget {
  const _SpaceBetween();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = watchReading(context, ref, _direction);
    final gap = watchReading(context, ref, _gap);
    final w = InspectorScope.of(context).writer;
    final on = !gap.mixed && gap.value == const ir.IrValue.gap(ir.Gap.auto());
    return FitStart(
      child: FieldFrame.single(
        path: _gap,
        child: SsToggle(
          key: const ValueKey<String>('field:spaceBetween'),
          label: 'Space between',
          value: on,
          onChanged: !dir.mixed && gap.exists
              ? (v) => w.set(
                  _gap,
                  ir.IrValue.gap(
                    v ? const ir.Gap.auto() : const ir.Gap.fixed(),
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

/// Left-aligns a one-line control and scales it down rather than
/// overflowing when a label is wider than the panel.
class FitStart extends StatelessWidget {
  const FitStart({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: child,
    ),
  );
}

/// "Align text baselines": `counterAlign = baseline`, horizontal layouts
/// only (disabled for vertical ones).
class _BaselineCheck extends ConsumerWidget {
  const _BaselineCheck();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dir = watchReading(context, ref, _direction);
    final counter = watchReading(context, ref, _counter);
    final w = InspectorScope.of(context).writer;
    final horizontal =
        !dir.mixed && dir.enumName == ir.LayoutDirection.horizontal.name;
    final on = counter.enumName == ir.CounterAlign.baseline.name;
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s1),
      child: FitStart(
        child: FieldFrame.single(
          path: _counter,
          child: SsCheckbox(
            key: const ValueKey<String>('field:baseline'),
            label: 'Align text baselines',
            value: !horizontal ? false : (counter.mixed ? null : on),
            onChanged: horizontal && counter.exists
                ? (v) => w.set(
                    _counter,
                    ir.IrValue.enumValue(
                      v
                          ? ir.CounterAlign.baseline.name
                          : ir.CounterAlign.start.name,
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
