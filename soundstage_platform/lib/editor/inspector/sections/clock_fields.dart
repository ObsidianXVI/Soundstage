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

/// The frame choices for a pointer clock.
typedef FrameChoice = ({String id, String name});

/// Pointer clock fields: the frame (from the scene's frames or the current
/// selection) and the axis.
class PointerFields extends StatelessWidget {
  const PointerFields({
    required this.frameId,
    required this.axis,
    required this.frames,
    required this.selectedFrameId,
    required this.onFrame,
    required this.onAxis,
    super.key,
  });

  final String frameId;
  final ir.PointerAxis axis;
  final List<FrameChoice> frames;

  /// The single selected frame of the scene, if any ("use selection").
  final String? selectedFrameId;
  final ValueChanged<String> onFrame;
  final ValueChanged<ir.PointerAxis> onAxis;

  @override
  Widget build(BuildContext context) {
    final known = frames.any((f) => f.id == frameId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClockField(
          'Frame',
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SsDropdown<String>(
                semanticLabel: 'Frame',
                value: known ? frameId : null,
                hint: frameId,
                items: [
                  for (final f in frames)
                    SsDropdownItem(value: f.id, label: f.name),
                ],
                onChanged: onFrame,
              ),
              FitLeft(
                child: SsButton(
                  label: 'Use selection',
                  variant: SsButtonVariant.ghost,
                  onPressed: selectedFrameId == null
                      ? null
                      : () => onFrame(selectedFrameId!),
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
            selected: axis,
            onChanged: onAxis,
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
