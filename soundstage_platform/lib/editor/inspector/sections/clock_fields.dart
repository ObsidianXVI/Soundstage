import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

// The editable fields of a clock (m2.md "Clocks UI"). They are shared by the
// rows of the Clocks list (each change is an `UpdateClock`) and the "Add
// clock" dialog (each change edits a draft), so both take an `onChange`
// callback that receives the edit as a function of the current clock.

/// A labelled control; [stacked] puts the label above a full-width control.
class ClockField extends StatelessWidget {
  const ClockField(this.label, this.child, {this.stacked = false, super.key});

  final String label;
  final Widget child;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final text = Text(
      label,
      style: t.text.small.copyWith(color: t.colors.textSecondary),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: SsSpace.s2),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                text,
                const SizedBox(height: SsSpace.s1),
                child,
              ],
            )
          : Row(
              children: [
                SizedBox(width: 64, child: text),
                Expanded(child: child),
              ],
            ),
    );
  }
}

/// Shrinks [child] to fit a narrow inspector instead of overflowing.
class FitLeft extends StatelessWidget {
  const FitLeft({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerLeft,
    child: child,
  );
}

/// Smoothing in seconds (scrubbable) for any clock.
class SmoothingField extends StatelessWidget {
  const SmoothingField({
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    super.key,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  @override
  Widget build(BuildContext context) => ClockField(
    'Smoothing',
    SsNumberField(
      semanticLabel: 'Smoothing',
      label: 'S',
      value: value,
      unit: 's',
      min: 0,
      max: 5,
      step: 0.05,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
      onChanged: onChanged,
    ),
  );
}

/// Timeline clock fields: duration, loop, rate and trigger.
class TimelineFields extends StatelessWidget {
  const TimelineFields({
    required this.clock,
    required this.onChange,
    this.onChangeStart,
    this.onChangeEnd,
    super.key,
  });

  final ir.TimelineClock clock;
  final void Function(ir.TimelineClock Function(ir.TimelineClock c) change)
  onChange;
  final VoidCallback? onChangeStart;
  final VoidCallback? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClockField(
          'Duration',
          SsNumberField(
            semanticLabel: 'Duration',
            label: 'D',
            value: clock.duration,
            unit: 's',
            min: 0.1,
            max: 600,
            step: 0.1,
            onChangeStart: onChangeStart,
            onChangeEnd: onChangeEnd,
            onChanged: (v) => onChange((c) => c.copyWith(duration: v)),
          ),
        ),
        ClockField(
          'Loop',
          FitLeft(
            child: SsSegmented<ir.TimelineLoop>(
              semanticLabel: 'Loop',
              selected: clock.loop,
              onChanged: (v) => onChange((c) => c.copyWith(loop: v)),
              segments: const [
                SsSegment(value: ir.TimelineLoop.none, label: 'None'),
                SsSegment(value: ir.TimelineLoop.loop, label: 'Loop'),
                SsSegment(value: ir.TimelineLoop.pingPong, label: 'Ping-pong'),
              ],
            ),
          ),
          stacked: true,
        ),
        ClockField(
          'Rate',
          SsNumberField(
            semanticLabel: 'Rate',
            label: 'R',
            value: clock.rate,
            unit: '×',
            min: 0.1,
            max: 10,
            step: 0.1,
            onChangeStart: onChangeStart,
            onChangeEnd: onChangeEnd,
            onChanged: (v) => onChange((c) => c.copyWith(rate: v)),
          ),
        ),
        ClockField(
          'Trigger',
          FitLeft(
            child: SsSegmented<ir.TimelineTrigger>(
              semanticLabel: 'Trigger',
              selected: clock.trigger,
              onChanged: (v) => onChange((c) => c.copyWith(trigger: v)),
              segments: const [
                SsSegment(
                  value: ir.TimelineTrigger.sceneEnter,
                  label: 'Scene enter',
                ),
                SsSegment(
                  value: ir.TimelineTrigger.autoplay,
                  label: 'Autoplay',
                ),
                SsSegment(
                  value: ir.TimelineTrigger.interaction,
                  label: 'M3',
                  semanticLabel: 'Interaction (available in M3)',
                  enabled: false,
                ),
              ],
            ),
          ),
          stacked: true,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: SsSpace.s2),
          child: Text(
            'Interaction triggers arrive in M3.',
            style: t.text.caption.copyWith(color: t.colors.textDisabled),
          ),
        ),
      ],
    );
  }
}

/// A frame a pointer clock can be bound to; [depth] indents it in the list.
typedef FrameChoice = ({String id, String name, int depth});

/// Pointer clock fields: the frame (searchable list of the scene's frames in
/// layer order) and the axis.
class PointerFields extends StatefulWidget {
  const PointerFields({
    required this.frameId,
    required this.axis,
    required this.frames,
    required this.onFrame,
    required this.onAxis,
    super.key,
  });

  final String frameId;
  final ir.PointerAxis axis;
  final List<FrameChoice> frames;
  final ValueChanged<String> onFrame;
  final ValueChanged<ir.PointerAxis> onAxis;

  @override
  State<PointerFields> createState() => _PointerFieldsState();
}

class _PointerFieldsState extends State<PointerFields> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final f in widget.frames)
        if (q.isEmpty || f.name.toLowerCase().contains(q)) f,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClockField(
          'Frame',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SsTextField(
                semanticLabel: 'Search frames',
                placeholder: 'Search frames',
                dense: true,
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: SsSpace.s1),
              Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  border: Border.all(color: c.borderSubtle),
                  borderRadius: SsRadius.brSm,
                ),
                child: shown.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(SsSpace.s2),
                        child: Text(
                          'No frames match.',
                          style: t.text.caption.copyWith(color: c.textDisabled),
                        ),
                      )
                    : ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: [
                          for (final f in shown)
                            SsInteractive(
                              key: ValueKey('frame-${f.id}'),
                              semanticLabel: f.name,
                              selected: f.id == widget.frameId,
                              onTap: () => widget.onFrame(f.id),
                              builder: (context, s) => Container(
                                height: 24,
                                alignment: Alignment.centerLeft,
                                padding: EdgeInsets.only(
                                  left:
                                      SsSpace.s2 +
                                      (q.isEmpty ? f.depth * SsSpace.s3 : 0),
                                  right: SsSpace.s2,
                                ),
                                color: f.id == widget.frameId
                                    ? c.selection
                                    : s.contains(WidgetState.hovered)
                                    ? c.hoverLayer
                                    : null,
                                child: Text(
                                  f.name,
                                  style: t.text.small,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
          stacked: true,
        ),
        ClockField(
          'Axis',
          SsSegmented<ir.PointerAxis>(
            semanticLabel: 'Axis',
            expand: true,
            selected: widget.axis,
            onChanged: widget.onAxis,
            segments: const [
              SsSegment(value: ir.PointerAxis.x, label: 'X'),
              SsSegment(value: ir.PointerAxis.y, label: 'Y'),
            ],
          ),
        ),
      ],
    );
  }
}
