import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'clock_fields.dart';

// Dialogs of the Clocks UI: "Add clock" and "Delete clock" (dialogs are
// allowed in editor chrome).

/// The label a clock shows in lists and menus.
String clockLabel(
  ir.Clock c, [
  Map<String, String> frameNames = const {},
]) => switch (c) {
  ir.SceneScrollClock() => 'Scene scroll',
  ir.TimelineClock(:final name) => name.isEmpty ? 'Timeline' : name,
  ir.AudioClock() => 'Audio',
  ir.PointerClock(:final frameId, :final axis) =>
    'Pointer ${axis.name.toUpperCase()} · ${frameNames[frameId] ?? frameId}',
  ir.BehaviorClock(:final name) => 'Behaviour · $name',
};

enum NewClockKind { timeline, pointer }

/// Asks which clock to add; resolves to the clocks to create (two for a
/// pointer clock on both axes) or null when cancelled. [ids] supplies the
/// new clock ids (two).
Future<List<ir.Clock>?> showAddClockDialog(
  BuildContext context, {
  required List<String> ids,
  required List<FrameChoice> frames,
  required String? selectedFrameId,
}) => showSsDialog<List<ir.Clock>>(
  context,
  builder: (ctx) => _AddClockDialog(
    ids: ids,
    frames: frames,
    selectedFrameId: selectedFrameId,
  ),
);

class _AddClockDialog extends StatefulWidget {
  const _AddClockDialog({
    required this.ids,
    required this.frames,
    required this.selectedFrameId,
  });

  final List<String> ids;
  final List<FrameChoice> frames;
  final String? selectedFrameId;

  @override
  State<_AddClockDialog> createState() => _AddClockDialogState();
}

class _AddClockDialogState extends State<_AddClockDialog> {
  NewClockKind _kind = NewClockKind.timeline;
  late ir.TimelineClock _timeline = ir.TimelineClock(
    id: widget.ids[0],
    duration: 5,
    name: 'Timeline',
  );
  late String _frame =
      widget.selectedFrameId ??
      (widget.frames.isEmpty ? '' : widget.frames.first.id);
  ir.PointerAxis _axis = ir.PointerAxis.x;
  bool _both = false;

  List<ir.Clock> _build() {
    if (_kind == NewClockKind.timeline) return [_timeline];
    ir.PointerClock pc(String id, ir.PointerAxis a) =>
        ir.PointerClock(id: id, frameId: _frame, axis: a);
    final other = _axis == ir.PointerAxis.x
        ? ir.PointerAxis.y
        : ir.PointerAxis.x;
    return [pc(widget.ids[0], _axis), if (_both) pc(widget.ids[1], other)];
  }

  @override
  Widget build(BuildContext context) {
    final pointer = _kind == NewClockKind.pointer;
    return SsDialog(
      title: 'Add clock',
      width: 340,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClockField(
            'Type',
            SsSegmented<NewClockKind>(
              semanticLabel: 'Clock type',
              expand: true,
              selected: _kind,
              onChanged: (k) => setState(() => _kind = k),
              segments: const [
                SsSegment(value: NewClockKind.timeline, label: 'Timeline'),
                SsSegment(value: NewClockKind.pointer, label: 'Pointer'),
              ],
            ),
          ),
          if (!pointer) ...[
            ClockField(
              'Name',
              SsTextField(
                semanticLabel: 'Clock name',
                initialValue: _timeline.name,
                onChanged: (v) =>
                    setState(() => _timeline = _timeline.copyWith(name: v)),
              ),
            ),
            TimelineFields(
              clock: _timeline,
              onChange: (f) => setState(() => _timeline = f(_timeline)),
            ),
          ] else ...[
            PointerFields(
              frameId: _frame,
              axis: _axis,
              frames: widget.frames,
              selectedFrameId: widget.selectedFrameId,
              onFrame: (f) => setState(() => _frame = f),
              onAxis: (a) => setState(() => _axis = a),
            ),
            FitLeft(
              child: SsCheckbox(
                value: _both,
                label: 'Also add the other axis',
                semanticLabel: 'Also add the other axis',
                onChanged: (v) => setState(() => _both = v),
              ),
            ),
          ],
        ],
      ),
      actions: [
        SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        SsButton(
          label: 'Add clock',
          variant: SsButtonVariant.primary,
          onPressed: pointer && _frame.isEmpty
              ? null
              : () => Navigator.of(context).pop(_build()),
        ),
      ],
    );
  }
}

/// Asks what to do with the [trackCount] tracks that run on [clock] before
/// it is deleted. Resolves to how to remove it, or null when cancelled.
/// [others] are the clocks the tracks can move to.
Future<ir.ClockRemoval?> showDeleteClockDialog(
  BuildContext context, {
  required String clockName,
  required int trackCount,
  required List<({String id, String name})> others,
}) => showSsDialog<ir.ClockRemoval>(
  context,
  builder: (ctx) => SsDialog(
    title: 'Delete "$clockName"?',
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          trackCount == 1
              ? '1 track uses this clock.'
              : '$trackCount tracks use this clock.',
        ),
        const SizedBox(height: SsSpace.s3),
        SsDropdown<String>(
          semanticLabel: 'Move to clock',
          hint: 'Move to clock',
          items: [
            for (final o in others) SsDropdownItem(value: o.id, label: o.name),
          ],
          onChanged: others.isEmpty
              ? null
              : (id) => Navigator.of(ctx).pop(ir.ClockRemoval.moveTracksTo(id)),
        ),
      ],
    ),
    actions: [
      SsButton(label: 'Cancel', onPressed: () => Navigator.of(ctx).pop()),
      SsButton(
        label: trackCount == 1 ? 'Delete 1 track' : 'Delete $trackCount tracks',
        variant: SsButtonVariant.danger,
        onPressed: () =>
            Navigator.of(ctx).pop(const ir.ClockRemoval.deleteTracks()),
      ),
    ],
  ),
);
