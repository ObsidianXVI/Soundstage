import 'package:flutter/material.dart' hide Easing;
import 'package:flutter/services.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../inspector/sections/clock_fields.dart' show ClockField;
import 'easing_curve.dart';
import 'easing_preview.dart';
import 'easing_samples.dart';

/// The easing editor (m2.md "Easing editor"; architecture §10.2).
///
/// It edits the easing of one or many segments: [easings] is the current
/// easing of each (more than one distinct value is the Mixed state, where
/// nothing is drawn until a choice is made), and every change calls
/// [onChanged] with the new easing for all of them. A handle drag or number
/// scrub is bracketed by [onGestureStart] / [onGestureEnd] so the host can
/// coalesce it into one undo step; every other change is its own step.
///
/// Modes: presets (linear, the CSS family, Back), cubic bezier (draggable
/// handles, y may overshoot; x1/y1/x2/y2 fields; copy and paste as
/// `cubic-bezier(...)`), spring (mass, stiffness, damping, settle time),
/// steps (count, jumpStart/jumpEnd) and hold. Curves are drawn from
/// `applyEasing`, so they are the curves the runtime evaluates.
class EasingEditor extends StatefulWidget {
  const EasingEditor({
    required this.easings,
    required this.onChanged,
    this.onGestureStart,
    this.onGestureEnd,
    this.onClose,
    super.key,
  });

  final List<ir.Easing> easings;
  final ValueChanged<ir.Easing> onChanged;
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;
  final VoidCallback? onClose;

  @override
  State<EasingEditor> createState() => _EasingEditorState();
}

/// The presets of the grid, in order.
const List<ir.Easing> kPresetChoices = [
  ir.Easing.linear(),
  ir.Easing.preset(ir.EasingPreset.ease),
  ir.Easing.preset(ir.EasingPreset.easeIn),
  ir.Easing.preset(ir.EasingPreset.easeOut),
  ir.Easing.preset(ir.EasingPreset.easeInOut),
  ir.Easing.preset(ir.EasingPreset.easeInBack),
  ir.Easing.preset(ir.EasingPreset.easeOutBack),
  ir.Easing.preset(ir.EasingPreset.easeInOutBack),
];

String _presetKey(ir.Easing e) => switch (e) {
  ir.PresetEasing(:final preset) => preset.name,
  _ => 'linear',
};

String _presetName(ir.Easing e) => switch (e) {
  ir.PresetEasing(:final preset) => presetLabel(preset),
  _ => 'Linear',
};

class _EasingEditorState extends State<EasingEditor> {
  String? _notice;

  bool get _mixed => widget.easings.toSet().length > 1;
  ir.Easing get _current => widget.easings.first;
  EasingMode? get _mode => _mixed ? null : modeOf(_current);

  void _set(ir.Easing e) {
    if (_notice != null) setState(() => _notice = null);
    widget.onChanged(e);
  }

  void _switchMode(EasingMode mode) {
    if (_mode == mode) return;
    final base = _mixed ? null : _current;
    _set(switch (mode) {
      EasingMode.preset => const ir.Easing.preset(ir.EasingPreset.ease),
      EasingMode.bezier => () {
        final (x1, y1, x2, y2) =
            (base == null ? null : controlPointsOf(base)) ??
            (0.25, 0.1, 0.25, 1.0);
        return ir.Easing.cubicBezier(x1, y1, x2, y2);
      }(),
      EasingMode.spring => const ir.Easing.spring(),
      EasingMode.steps => const ir.Easing.steps(4),
      EasingMode.hold => const ir.Easing.hold(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final mode = _mode;
    final n = widget.easings.length;
    return Column(
      key: const ValueKey<String>('easing-editor'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                n == 1 ? 'Easing' : 'Easing · $n segments',
                style: t.text.bodyStrong,
              ),
            ),
            if (widget.onClose != null)
              SsIconButton(
                icon: SsIcons.x,
                semanticLabel: 'Close easing editor',
                size: 24,
                iconSize: 14,
                onPressed: widget.onClose,
              ),
          ],
        ),
        const SizedBox(height: SsSpace.s2),
        SsSegmented<EasingMode>(
          semanticLabel: 'Easing type',
          expand: true,
          selected: mode,
          onChanged: _switchMode,
          segments: const [
            SsSegment(value: EasingMode.preset, label: 'Preset'),
            SsSegment(value: EasingMode.bezier, label: 'Bezier'),
            SsSegment(value: EasingMode.spring, label: 'Spring'),
            SsSegment(value: EasingMode.steps, label: 'Steps'),
            SsSegment(value: EasingMode.hold, label: 'Hold'),
          ],
        ),
        const SizedBox(height: SsSpace.s2),
        if (_mixed)
          _MixedNotice(count: n)
        else ...[
          EasingCurvePad(
            easing: _current,
            onControls: mode == EasingMode.bezier
                ? (c) => _set(ir.Easing.cubicBezier(c.$1, c.$2, c.$3, c.$4))
                : null,
            onDragStart: widget.onGestureStart,
            onDragEnd: widget.onGestureEnd,
          ),
          const SizedBox(height: SsSpace.s2),
          EasingPreview(easing: _current),
        ],
        const SizedBox(height: SsSpace.s2),
        if (mode == null || mode == EasingMode.preset)
          _PresetGrid(selected: mode == null ? null : _current, onPick: _set),
        if (mode == EasingMode.bezier) _bezierControls(),
        if (mode == EasingMode.spring) _springControls(),
        if (mode == EasingMode.steps) _stepsControls(),
        if (mode == EasingMode.hold)
          Text(
            'Holds the start value until the next keyframe, then jumps.',
            style: t.text.caption,
          ),
        if (mode == EasingMode.preset)
          Padding(
            padding: const EdgeInsets.only(top: SsSpace.s1),
            child: Text(_presetName(_current), style: t.text.caption),
          ),
      ],
    );
  }

  // ---- Bezier -------------------------------------------------------------------

  Widget _bezierControls() {
    final b = _current as ir.CubicBezierEasing;
    final css = cubicBezierCss(b.x1, b.y1, b.x2, b.y2);

    Widget field(
      String name,
      double value,
      bool isX,
      ir.Easing Function(double) make,
    ) {
      return Expanded(
        child: SsNumberField(
          key: ValueKey<String>('easing-field:$name'),
          value: value,
          label: name,
          semanticLabel: name,
          min: isX ? 0 : kMinHandleY,
          max: isX ? 1 : kMaxHandleY,
          step: 0.05,
          fractionDigits: 2,
          onChangeStart: widget.onGestureStart,
          onChangeEnd: widget.onGestureEnd,
          onChanged: (v) => _set(make(v)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            field(
              'x1',
              b.x1,
              true,
              (v) => ir.Easing.cubicBezier(v, b.y1, b.x2, b.y2),
            ),
            const SizedBox(width: SsSpace.s1),
            field(
              'y1',
              b.y1,
              false,
              (v) => ir.Easing.cubicBezier(b.x1, v, b.x2, b.y2),
            ),
          ],
        ),
        const SizedBox(height: SsSpace.s1),
        Row(
          children: [
            field(
              'x2',
              b.x2,
              true,
              (v) => ir.Easing.cubicBezier(b.x1, b.y1, v, b.y2),
            ),
            const SizedBox(width: SsSpace.s1),
            field(
              'y2',
              b.y2,
              false,
              (v) => ir.Easing.cubicBezier(b.x1, b.y1, b.x2, v),
            ),
          ],
        ),
        const SizedBox(height: SsSpace.s2),
        Row(
          children: [
            Expanded(
              child: SsTextField(
                key: ValueKey<String>('easing-css:$css'),
                initialValue: css,
                semanticLabel: 'cubic-bezier value',
                dense: true,
                selectAllOnFocus: true,
                revertOnEscape: true,
                onSubmitted: _pasteText,
              ),
            ),
            SsIconButton(
              key: const ValueKey<String>('easing-copy'),
              icon: SsIcons.copy,
              semanticLabel: 'Copy cubic-bezier',
              size: 26,
              iconSize: 14,
              onPressed: () => Clipboard.setData(ClipboardData(text: css)),
            ),
            SsButton(
              key: const ValueKey<String>('easing-paste'),
              label: 'Paste',
              onPressed: _paste,
            ),
          ],
        ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.only(top: SsSpace.s1),
            child: Text(
              _notice!,
              key: const ValueKey<String>('easing-notice'),
              style: context.ss.text.caption.copyWith(
                color: context.ss.colors.danger,
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    _pasteText(data?.text ?? '');
  }

  void _pasteText(String text) {
    final parsed = parseCubicBezier(text);
    if (parsed == null) {
      setState(() => _notice = 'Not a cubic-bezier(x1, y1, x2, y2) value.');
      return;
    }
    _set(parsed);
  }

  // ---- Spring -------------------------------------------------------------------

  Widget _springControls() {
    final s = _current as ir.SpringEasing;
    final t = context.ss;
    final settle = ir.springSettleTime(s.mass, s.stiffness, s.damping);

    Widget field(
      String name,
      String key,
      double v,
      double min,
      double max,
      double step,
      ir.Easing Function(double) make,
    ) {
      return ClockField(
        name,
        SsNumberField(
          key: ValueKey<String>(key),
          value: v,
          semanticLabel: name,
          min: min,
          max: max,
          step: step,
          fractionDigits: 2,
          onChangeStart: widget.onGestureStart,
          onChangeEnd: widget.onGestureEnd,
          onChanged: (x) => _set(make(x)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field(
          'Mass',
          'spring-mass',
          s.mass,
          0.1,
          20,
          0.1,
          (v) => ir.Easing.spring(
            mass: v,
            stiffness: s.stiffness,
            damping: s.damping,
          ),
        ),
        field(
          'Stiffness',
          'spring-stiffness',
          s.stiffness,
          1,
          1000,
          5,
          (v) =>
              ir.Easing.spring(mass: s.mass, stiffness: v, damping: s.damping),
        ),
        field(
          'Damping',
          'spring-damping',
          s.damping,
          0,
          200,
          1,
          (v) => ir.Easing.spring(
            mass: s.mass,
            stiffness: s.stiffness,
            damping: v,
          ),
        ),
        Text(
          'Settle time ${settle.toStringAsFixed(2)} s',
          key: const ValueKey<String>('spring-settle'),
          style: t.text.small,
        ),
        Text(
          "A segment's length is played over the settle time.",
          style: t.text.caption,
        ),
      ],
    );
  }

  // ---- Steps --------------------------------------------------------------------

  Widget _stepsControls() {
    final s = _current as ir.StepsEasing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClockField(
          'Steps',
          SsNumberField(
            key: const ValueKey<String>('steps-count'),
            value: s.count.toDouble(),
            semanticLabel: 'Number of steps',
            min: 1,
            max: 64,
            fractionDigits: 0,
            onChangeStart: widget.onGestureStart,
            onChangeEnd: widget.onGestureEnd,
            onChanged: (v) =>
                _set(ir.Easing.steps(v.round(), position: s.position)),
          ),
        ),
        ClockField(
          'Jump',
          SsSegmented<ir.StepPosition>(
            key: const ValueKey<String>('steps-position'),
            semanticLabel: 'Jump position',
            expand: true,
            selected: s.position,
            onChanged: (p) => _set(ir.Easing.steps(s.count, position: p)),
            segments: const [
              SsSegment(value: ir.StepPosition.jumpStart, label: 'Start'),
              SsSegment(value: ir.StepPosition.jumpEnd, label: 'End'),
            ],
          ),
        ),
      ],
    );
  }
}

class _MixedNotice extends StatelessWidget {
  const _MixedNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Container(
      key: const ValueKey<String>('easing-mixed'),
      height: 72,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: SsSpace.s3),
      decoration: BoxDecoration(
        color: t.colors.surface2,
        borderRadius: SsRadius.brMd,
      ),
      child: Text(
        'Mixed: the $count segments have different easings. Pick one to '
        'set them all.',
        textAlign: TextAlign.center,
        style: t.text.caption,
      ),
    );
  }
}

class _PresetGrid extends StatelessWidget {
  const _PresetGrid({required this.selected, required this.onPick});

  final ir.Easing? selected;
  final ValueChanged<ir.Easing> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final c = t.colors;
    return Wrap(
      spacing: SsSpace.s1,
      runSpacing: SsSpace.s1,
      children: [
        for (final e in kPresetChoices)
          SizedBox(
            width: 62,
            child: SsInteractive(
              key: ValueKey<String>('easing-preset:${_presetKey(e)}'),
              onTap: () => onPick(e),
              semanticLabel: _presetName(e),
              selected: selected == e,
              excludeSemantics: true,
              builder: (context, s) {
                final on = selected == e;
                return Container(
                  padding: const EdgeInsets.symmetric(vertical: SsSpace.s1),
                  decoration: BoxDecoration(
                    color: on
                        ? c.selection
                        : s.contains(WidgetState.hovered)
                        ? c.surface3
                        : c.surface2,
                    borderRadius: SsRadius.brMd,
                    border: Border.all(
                      color: on
                          ? c.accent
                          : s.contains(WidgetState.focused)
                          ? c.focusRing
                          : c.borderSubtle,
                    ),
                  ),
                  child: Column(
                    children: [
                      EasingThumb(easing: e),
                      Text(
                        _presetName(e),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.text.caption.copyWith(
                          color: on ? c.accentText : c.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
