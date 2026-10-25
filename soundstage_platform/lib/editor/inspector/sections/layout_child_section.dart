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
import 'auto_layout_gap_field.dart' show globalRectOf;
import 'layout_child_facts.dart';

/// How a node sizes itself in a layout (Figma's "Fixed / Hug / Fill"), and
/// its min / max sizes. Shown for in-flow children of auto layout and for
/// auto-layout frames themselves (their hug applies in a free parent too);
/// for scene roots only the height of a flow scene's auto-layout root
/// (Fixed or Hug: it hugs its content, padding included); the breakpoint
/// sizes every other root.
final InspectorSectionSpec layoutChildSection = InspectorSectionSpec(
  id: 'layout_child',
  title: 'Layout',
  appliesTo: (info) =>
      (info.roots == 0 && (info.anyLayoutChild || info.anyAutoLayout)) ||
      (info.count > 0 && info.flowAutoLayoutRoots == info.count),
  builder: (context, info) => _LayoutChildBody(
    rootsOnly: info.count > 0 && info.roots == info.count,
  ),
);

/// The sizings valid for one node on [axis] (Figma's rules):
///
/// - Fixed: always (none at all for a scene root: the breakpoint sizes it;
///   a flow scene's auto-layout root may be Fixed or Hug in height).
/// - Hug: a frame with auto layout (it hugs its flow), or text (auto
///   resize). Not shapes, video, embeds, free frames or instances.
/// - Fill: an in-flow child of an auto-layout parent (on the parent's
///   counter axis this is "stretch"); any kind.
///
/// The rules are currently the same on both axes; [axis] is part of the
/// contract so per-axis rules (text auto-height) can land without callers
/// changing.
Set<ir.Sizing> validSizings({
  required ir.NodeKind kind,
  required bool hasAutoLayout,
  required bool parentHasAutoLayout,
  required bool inFlow,
  required bool isRoot,
  required Axis axis,
  bool isFlowRoot = false,
}) {
  if (isRoot) {
    return isFlowRoot && hasAutoLayout && axis == Axis.vertical
        ? const {ir.Sizing.fixed, ir.Sizing.hug}
        : const {};
  }
  return {
    ir.Sizing.fixed,
    if ((kind == ir.NodeKind.frame && hasAutoLayout) ||
        kind == ir.NodeKind.text)
      ir.Sizing.hug,
    if (parentHasAutoLayout && inFlow) ir.Sizing.fill,
  };
}

Set<ir.Sizing> _validFor(NodeLayoutFacts n, Axis axis) => validSizings(
  kind: n.kind,
  hasAutoLayout: n.hasAutoLayout,
  parentHasAutoLayout: n.parentHasAutoLayout,
  inFlow: n.inFlow,
  isRoot: n.isRoot,
  axis: axis,
  isFlowRoot: n.isFlowRoot,
);

/// Why [s] is unavailable for [n] (the disabled segment's tooltip).
String _whyNot(ir.Sizing s, NodeLayoutFacts n) => switch (s) {
  _ when n.isRoot => 'Scene roots are sized by the breakpoint',
  ir.Sizing.fixed => 'Scene roots are sized by the breakpoint',
  ir.Sizing.hug =>
    n.kind == ir.NodeKind.frame
        ? 'Hug needs auto layout on this frame'
        : 'Only auto-layout frames and text can hug',
  ir.Sizing.fill =>
    !n.parentHasAutoLayout
        ? 'Fill needs an auto-layout parent'
        : 'Fill is unavailable while ignoring auto layout',
};

/// The options of one axis over the selection: an option is enabled only
/// when valid for every node; otherwise it carries the first failing node's
/// reason.
Map<ir.Sizing, String?> sizingOptionsOf(LayoutChildFacts facts, Axis axis) {
  final out = <ir.Sizing, String?>{for (final s in ir.Sizing.values) s: null};
  for (final n in facts.nodes) {
    final valid = _validFor(n, axis);
    for (final s in ir.Sizing.values) {
      if (!valid.contains(s) && out[s] == null) out[s] = _whyNot(s, n);
    }
  }
  return out;
}

const _names = {
  ir.Sizing.fixed: 'Fixed',
  ir.Sizing.hug: 'Hug',
  ir.Sizing.fill: 'Fill',
};

class _LayoutChildBody extends StatelessWidget {
  const _LayoutChildBody({this.rootsOnly = false});

  /// Flow-scene roots: only their height.
  final bool rootsOnly;

  @override
  Widget build(BuildContext context) {
    if (rootsOnly) {
      return const _SizingRow(
        axis: Axis.vertical,
        path: 'layoutChild.verticalSizing',
        label: 'Height',
      );
    }
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SizingRow(
          axis: Axis.horizontal,
          path: 'layoutChild.horizontalSizing',
          label: 'Width',
        ),
        _SizingRow(
          axis: Axis.vertical,
          path: 'layoutChild.verticalSizing',
          label: 'Height',
        ),
        _MinMax(),
      ],
    );
  }
}

class _SizingRow extends ConsumerWidget {
  const _SizingRow({
    required this.axis,
    required this.path,
    required this.label,
  });

  final Axis axis;
  final String path;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(
      layoutChildFactsProvider.select(
        (f) => _Options(sizingOptionsOf(f, axis)),
      ),
    );
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    return LabelRow(
      label: label,
      child: FieldFrame.single(
        path: path,
        child: SsSegmented<String>(
          key: ValueKey<String>('field:$path'),
          semanticLabel: '$label sizing',
          expand: true,
          selected: r.mixed ? null : r.enumName,
          onChanged: r.exists
              ? (v) => w.set(path, ir.IrValue.enumValue(v))
              : null,
          segments: [
            for (final s in ir.Sizing.values)
              SsSegment(
                value: s.name,
                label: _names[s],
                enabled: options.reasons[s] == null,
                semanticLabel: options.reasons[s] == null
                    ? '${_names[s]} $label'.trim()
                    : '${_names[s]}: ${options.reasons[s]}',
              ),
          ],
        ),
      ),
    );
  }
}

/// Value-compared wrapper for the per-option reasons.
class _Options {
  const _Options(this.reasons);

  final Map<ir.Sizing, String?> reasons;

  @override
  bool operator ==(Object other) =>
      other is _Options &&
      ir.Sizing.values.every((s) => other.reasons[s] == reasons[s]);

  @override
  int get hashCode =>
      Object.hashAll([for (final s in ir.Sizing.values) reasons[s]]);
}

/// Min / max width and height, added on demand from a "+" menu (initialised
/// to each node's current size) and shown as a grid of the set ones.
class _MinMax extends ConsumerWidget {
  const _MinMax();

  static const _entries = [
    ('layoutChild.minWidth', 'Min width', 'Min W', 'width'),
    ('layoutChild.maxWidth', 'Max width', 'Max W', 'width'),
    ('layoutChild.minHeight', 'Min height', 'Min H', 'height'),
    ('layoutChild.maxHeight', 'Max height', 'Max H', 'height'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = InspectorScope.of(context);
    final w = scope.writer;
    final set = <(String, String, String, String)>[];
    final unset = <(String, String, String, String)>[];
    for (final e in _entries) {
      final r = watchReading(context, ref, e.$1);
      if (!r.exists) continue;
      (r.mixed || r.value is! ir.NoneValue ? set : unset).add(e);
    }

    void add(String path, String sizePath) {
      // Each node starts from its own current size.
      final values = <String, Map<String, ir.IrValue>>{};
      for (final id in scope.ids) {
        final size = ref
            .read(propertyReadingProvider(ReadKey([id], sizePath)))
            .number;
        values[id] = {path: ir.IrValue.number(size ?? 0)};
      }
      w.run(SetProperty.values(values));
    }

    final t = context.ss;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text('Min / max', style: t.text.caption)),
            Builder(
              builder: (bc) => SsIconButton(
                key: const ValueKey<String>('min-max:add'),
                icon: SsIcons.plus,
                semanticLabel: 'Add min/max',
                size: 24,
                iconSize: 12,
                onPressed: unset.isEmpty
                    ? null
                    : () => showSsMenu(
                        bc,
                        anchor: globalRectOf(bc),
                        placement: SsPlacement.belowEnd,
                        minWidth: 140,
                        entries: [
                          for (final e in unset)
                            SsMenuItem(
                              label: e.$2,
                              onSelected: () => add(e.$1, e.$4),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
        if (set.isNotEmpty) ...[
          const SizedBox(height: SsSpace.s1),
          Grid(
            children: [
              for (final e in set)
                OptionalNumberProp(
                  key: ValueKey<String>('min-max:${e.$1}'),
                  path: e.$1,
                  label: e.$3,
                  semanticLabel: e.$2,
                  min: 0,
                ),
            ],
          ),
        ] else
          const SizedBox(height: SsSpace.s2),
      ],
    );
  }
}
