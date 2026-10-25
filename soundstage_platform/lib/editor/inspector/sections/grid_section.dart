import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../inspector_providers.dart';
import '../property_writer.dart';
import '../section_registry.dart';
import 'layout_child_facts.dart';

/// Grid layout of the selected frames (architecture §4.5; m3.md T3.5): the
/// column and row tracks (fixed px, flex fr, hug), gaps, padding and the
/// auto-placement flow. "+" makes free frames grids (two flex columns, a
/// 16 px gap); "−" removes the grid. Every field follows the edit scope, so
/// a grid can have three columns on desktop and one on mobile.
final InspectorSectionSpec gridSection = InspectorSectionSpec(
  id: 'grid',
  title: 'Grid',
  appliesTo: (info) => info.anyFrame,
  builder: (context, info) => const _GridBody(),
  actions: (context, info) => const [_GridAction()],
);

/// Where a child of a grid sits (§4.5): its cell (Auto or a 1-based
/// column/row), spans and alignment in the cell.
final InspectorSectionSpec gridCellSection = InspectorSectionSpec(
  id: 'grid_cell',
  title: 'Grid cell',
  appliesTo: (info) => info.inGrid > 0 && info.inGrid == info.count,
  builder: (context, info) => const _GridCellBody(),
);

class _GridAction extends ConsumerWidget {
  const _GridAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facts = ref.watch(layoutChildFactsProvider);
    final w = InspectorScope.of(context).writer;
    final grids = facts.gridFrameIds;
    final free = facts.freeFrameIds;
    if (grids.isNotEmpty && free.isEmpty) {
      return SsIconButton(
        key: const ValueKey<String>('grid:remove'),
        icon: SsIcons.minus,
        semanticLabel: 'Remove grid',
        size: 24,
        iconSize: 14,
        onPressed: () => PropertyWriter(
          w.controller,
          w.readState,
          grids,
        ).set('grid', const ir.IrValue.boolean(false)),
      );
    }
    if (free.isEmpty) return const SizedBox.shrink();
    return SsIconButton(
      key: const ValueKey<String>('grid:add'),
      icon: SsIcons.plus,
      semanticLabel: 'Add grid',
      size: 24,
      iconSize: 14,
      onPressed: () => PropertyWriter(w.controller, w.readState, free).setMany({
        'grid': const ir.IrValue.boolean(true),
        'grid.columns': const ir.IrValue.gridTracks([
          ir.GridTrack.flex(),
          ir.GridTrack.flex(),
        ]),
        'grid.columnGap': const ir.IrValue.number(16),
        'grid.rowGap': const ir.IrValue.number(16),
      }),
    );
  }
}

class _GridBody extends ConsumerWidget {
  const _GridBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ids = ref.watch(
      layoutChildFactsProvider.select((f) => IdList(f.gridFrameIds)),
    );
    final t = context.ss;
    if (ids.isEmpty) {
      return Padding(
        key: const ValueKey<String>('grid:hint'),
        padding: const EdgeInsets.only(bottom: SsSpace.s2),
        child: Text(
          'Add a grid to place children in rows and columns.',
          style: t.text.caption,
        ),
      );
    }
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TrackList(path: 'grid.columns', title: 'Columns', noun: 'column'),
        _TrackList(path: 'grid.rows', title: 'Rows', noun: 'row'),
        Grid(
          children: [
            NumberProp(
              path: 'grid.columnGap',
              label: '↔',
              semanticLabel: 'Column gap',
              min: 0,
            ),
            NumberProp(
              path: 'grid.rowGap',
              label: '↕',
              semanticLabel: 'Row gap',
              min: 0,
            ),
            NumberProp(
              path: 'grid.padding.left',
              label: 'L',
              semanticLabel: 'Grid padding left',
              min: 0,
            ),
            NumberProp(
              path: 'grid.padding.right',
              label: 'R',
              semanticLabel: 'Grid padding right',
              min: 0,
            ),
            NumberProp(
              path: 'grid.padding.top',
              label: 'T',
              semanticLabel: 'Grid padding top',
              min: 0,
            ),
            NumberProp(
              path: 'grid.padding.bottom',
              label: 'B',
              semanticLabel: 'Grid padding bottom',
              min: 0,
            ),
          ],
        ),
        LabelRow(
          label: 'Flow',
          child: EnumProp(
            path: 'grid.autoFlow',
            semanticLabel: 'Auto-placement flow',
            options: [
              EnumOption('row', 'Rows'),
              EnumOption('column', 'Columns'),
            ],
          ),
        ),
      ],
    );
  }
}

enum _TrackKind { fixed, flex, hug }

_TrackKind _kindOf(ir.GridTrack t) => switch (t) {
  ir.FixedGridTrack() => _TrackKind.fixed,
  ir.FlexGridTrack() => _TrackKind.flex,
  ir.HugGridTrack() => _TrackKind.hug,
};

/// The tracks at [path] (`grid.columns` / `grid.rows`): one row per track
/// (kind, size, remove) and an add button. Writes the whole list.
class _TrackList extends ConsumerWidget {
  const _TrackList({
    required this.path,
    required this.title,
    required this.noun,
  });

  final String path;
  final String title;
  final String noun;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final v = r.value;
    final tracks = !r.mixed && v is ir.GridTracksValue
        ? v.value
        : const <ir.GridTrack>[];
    void write(List<ir.GridTrack> next) =>
        w.set(path, ir.IrValue.gridTracks(next));

    return FieldFrame.single(
      path: path,
      keyframes: false,
      child: Padding(
        padding: const EdgeInsets.only(bottom: SsSpace.s2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    r.mixed
                        ? '$title: Mixed'
                        : tracks.isEmpty && path == 'grid.columns'
                        ? '$title: one flexible'
                        : tracks.isEmpty
                        ? '$title: as needed'
                        : '$title (${tracks.length})',
                    style: t.text.small.copyWith(color: t.colors.textSecondary),
                  ),
                ),
                SsIconButton(
                  key: ValueKey<String>('$path:add'),
                  icon: SsIcons.plus,
                  semanticLabel: 'Add $noun',
                  size: 24,
                  iconSize: 12,
                  onPressed: () =>
                      write([...tracks, const ir.GridTrack.flex()]),
                ),
              ],
            ),
            for (var i = 0; i < tracks.length; i++)
              Padding(
                padding: const EdgeInsets.only(top: SsSpace.s1),
                child: Row(
                  key: ValueKey<String>('$path:$i'),
                  children: [
                    SizedBox(
                      width: 84,
                      child: SsDropdown<_TrackKind>(
                        semanticLabel: '$noun ${i + 1} kind',
                        value: _kindOf(tracks[i]),
                        onChanged: (k) {
                          if (k == _kindOf(tracks[i])) return;
                          write([
                            for (var j = 0; j < tracks.length; j++)
                              j != i
                                  ? tracks[j]
                                  : switch (k) {
                                      _TrackKind.fixed =>
                                        const ir.GridTrack.fixed(120),
                                      _TrackKind.flex =>
                                        const ir.GridTrack.flex(),
                                      _TrackKind.hug =>
                                        const ir.GridTrack.hug(),
                                    },
                          ]);
                        },
                        items: const [
                          SsDropdownItem(
                            value: _TrackKind.fixed,
                            label: 'Fixed',
                          ),
                          SsDropdownItem(value: _TrackKind.flex, label: 'Flex'),
                          SsDropdownItem(value: _TrackKind.hug, label: 'Hug'),
                        ],
                      ),
                    ),
                    const SizedBox(width: SsSpace.s1),
                    Expanded(
                      child: switch (tracks[i]) {
                        ir.FixedGridTrack(:final px) => SsNumberField(
                          semanticLabel: '$noun ${i + 1} size',
                          value: px,
                          unit: 'px',
                          min: 0,
                          onChangeStart: w.beginGesture,
                          onChangeEnd: w.endGesture,
                          onChanged: (x) => write([
                            for (var j = 0; j < tracks.length; j++)
                              j == i ? ir.GridTrack.fixed(x) : tracks[j],
                          ]),
                        ),
                        ir.FlexGridTrack(:final fr) => SsNumberField(
                          semanticLabel: '$noun ${i + 1} share',
                          value: fr,
                          unit: 'fr',
                          min: 0,
                          step: 0.5,
                          onChangeStart: w.beginGesture,
                          onChangeEnd: w.endGesture,
                          onChanged: (x) => write([
                            for (var j = 0; j < tracks.length; j++)
                              j == i ? ir.GridTrack.flex(x) : tracks[j],
                          ]),
                        ),
                        ir.HugGridTrack() => Text(
                          'Fits content',
                          style: t.text.caption,
                        ),
                      },
                    ),
                    SsIconButton(
                      icon: SsIcons.minus,
                      semanticLabel: 'Remove $noun ${i + 1}',
                      size: 24,
                      iconSize: 12,
                      onPressed: () => write([
                        for (var j = 0; j < tracks.length; j++)
                          if (j != i) tracks[j],
                      ]),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _GridCellBody extends StatelessWidget {
  const _GridCellBody();

  static const _align = [
    EnumOption('start', 'Start'),
    EnumOption('center', 'Center'),
    EnumOption('end', 'End'),
    EnumOption('stretch', 'Fill'),
  ];

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Grid(
        children: [
          _CellIndexField(path: 'layoutChild.grid.column', label: 'C'),
          _CellIndexField(path: 'layoutChild.grid.row', label: 'R'),
          NumberProp(
            path: 'layoutChild.grid.columnSpan',
            label: '↔',
            semanticLabel: 'Column span',
            min: 1,
            fractionDigits: 0,
          ),
          NumberProp(
            path: 'layoutChild.grid.rowSpan',
            label: '↕',
            semanticLabel: 'Row span',
            min: 1,
            fractionDigits: 0,
          ),
        ],
      ),
      LabelRow(
        label: 'Align X',
        child: EnumProp(
          path: 'layoutChild.grid.alignX',
          semanticLabel: 'Horizontal alignment in the cell',
          dropdown: true,
          options: _align,
        ),
      ),
      LabelRow(
        label: 'Align Y',
        child: EnumProp(
          path: 'layoutChild.grid.alignY',
          semanticLabel: 'Vertical alignment in the cell',
          dropdown: true,
          options: _align,
        ),
      ),
    ],
  );
}

/// A 1-based column or row index; empty is Auto (auto-placed).
class _CellIndexField extends ConsumerWidget {
  const _CellIndexField({required this.path, required this.label});

  final String path;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final v = r.value;
    final index = !r.mixed && v is ir.NumberValue ? v.value + 1 : null;
    return FieldFrame.single(
      path: path,
      keyframes: false,
      child: SsTextField(
        // Rebuilt with the value: the field keeps its text otherwise.
        key: ValueKey<String>('field:$path:$index'),
        semanticLabel: label == 'C' ? 'Column' : 'Row',
        dense: true,
        placeholder: r.mixed ? 'Mixed' : 'Auto',
        prefix: Text(label, style: context.ss.text.caption),
        initialValue: index == null ? '' : index.toInt().toString(),
        releaseFocusOnSubmit: true,
        onSubmitted: (s) {
          final n = int.tryParse(s.trim());
          w.set(
            path,
            n == null || n < 1
                ? const ir.IrValue.none()
                : ir.IrValue.number((n - 1).toDouble()),
          );
        },
      ),
    );
  }
}
