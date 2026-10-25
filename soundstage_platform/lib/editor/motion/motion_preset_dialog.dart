import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../easing/easing_editor.dart' show kPresetChoices;
import '../easing/easing_samples.dart' show presetLabel;
import '../inspector/sections/clock_fields.dart' show ClockField;
import '../timeline/timeline_math.dart';
import 'motion_presets.dart';

/// A clock the preset can play on, with its label and span.
typedef PresetClock = ({ir.Clock clock, String label, ClockRange span});

/// The clocks of [scene] a preset can run on: the scroll clock and the
/// timeline clocks.
List<PresetClock> presetClocksOf(ir.StageDocument doc, ir.Scene scene) => [
  for (final c in scene.clocks)
    if (c is ir.SceneScrollClock || c is ir.TimelineClock)
      (
        clock: c,
        label: clockLabel(doc, c),
        span: () {
          final s = clockSpan(doc, scene, c);
          return (s.min, s.max);
        }(),
      ),
];

/// Asks for a motion preset (m2.md "Motion presets"): the preset, In / Out
/// / In-out, the clock and its range, the distance or amount, and the
/// easing. Resolves to the spec to apply, or null when cancelled.
Future<MotionPresetSpec?> showMotionPresetDialog(
  BuildContext context, {
  required List<PresetClock> clocks,
  required String initialClockId,
}) => showSsDialog<MotionPresetSpec>(
  context,
  builder: (ctx) =>
      MotionPresetDialog(clocks: clocks, initialClockId: initialClockId),
);

class MotionPresetDialog extends StatefulWidget {
  const MotionPresetDialog({
    required this.clocks,
    required this.initialClockId,
    super.key,
  });

  final List<PresetClock> clocks;
  final String initialClockId;

  @override
  State<MotionPresetDialog> createState() => _MotionPresetDialogState();
}

class _MotionPresetDialogState extends State<MotionPresetDialog> {
  late MotionPresetSpec _spec = defaultPresetSpec(
    MotionPresetKind.fade,
    _clockOf(widget.initialClockId).clock,
    _clockOf(widget.initialClockId).span,
  );

  PresetClock _clockOf(String id) => widget.clocks.firstWhere(
    (c) => c.clock.id == id,
    orElse: () => widget.clocks.first,
  );

  PresetClock get _clock => _clockOf(_spec.clockId);

  /// Seconds for a timeline clock, percent for scroll.
  bool get _percent => _clock.clock is! ir.TimelineClock;
  double get _scale => _percent ? 100 : 1;

  bool _easingIsDefault() =>
      _spec.easing == defaultPresetEasing(_spec.kind, _spec.direction);

  void _setKind(MotionPresetKind kind) => setState(() {
    var clock = _clock;
    if (kind.scrollOnly && clock.clock is! ir.SceneScrollClock) {
      clock = widget.clocks.firstWhere(
        (c) => c.clock is ir.SceneScrollClock,
        orElse: () => clock,
      );
    }
    _spec = defaultPresetSpec(
      kind,
      clock.clock,
      clock.span,
      direction: _spec.direction,
    );
  });

  void _setDirection(PresetDirection d) => setState(() {
    final reset = _easingIsDefault();
    _spec = _spec.copyWith(
      direction: d,
      easing: reset ? defaultPresetEasing(_spec.kind, d) : _spec.easing,
    );
  });

  void _setClock(String id) => setState(() {
    final c = _clockOf(id);
    final (inRange, outRange) = _spec.kind.scrollOnly
        ? (c.span, c.span)
        : defaultPresetRanges(c.clock, c.span);
    _spec = _spec.copyWith(clockId: id, inRange: inRange, outRange: outRange);
  });

  Widget _range(String name, ClockRange r, ValueChanged<ClockRange> set) {
    final unit = _percent ? '%' : 's';
    final span = _clock.span;
    Widget f(String key, double v, ValueChanged<double> on) => Expanded(
      child: SsNumberField(
        key: ValueKey<String>(key),
        value: v * _scale,
        unit: unit,
        semanticLabel: '$name $key',
        min: span.$1 * _scale,
        max: _percent ? span.$2 * _scale : 600,
        step: _percent ? 1 : 0.1,
        fractionDigits: _percent ? 1 : 2,
        onChanged: (x) => setState(() => on(x / _scale)),
      ),
    );
    return ClockField(
      name,
      Row(
        children: [
          f('preset-${name.toLowerCase()}-start', r.$1, (x) => set((x, r.$2))),
          const SizedBox(width: SsSpace.s1),
          f('preset-${name.toLowerCase()}-end', r.$2, (x) => set((r.$1, x))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final kind = _spec.kind;
    final error = validatePresetSpec(_spec, _clock.span);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.6;
    final clocks = [
      for (final c in widget.clocks)
        if (!kind.scrollOnly || c.clock is ir.SceneScrollClock) c,
    ];
    return SsDialog(
      title: 'Add motion preset',
      width: 360,
      content: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: Column(
            key: const ValueKey<String>('motion-preset-dialog'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ClockField(
                'Preset',
                SsDropdown<MotionPresetKind>(
                  key: const ValueKey<String>('preset-kind'),
                  semanticLabel: 'Preset',
                  value: kind,
                  onChanged: _setKind,
                  items: [
                    for (final k in MotionPresetKind.values)
                      SsDropdownItem(value: k, label: k.label),
                  ],
                ),
              ),
              if (kind.hasDirection)
                ClockField(
                  'Play',
                  SsSegmented<PresetDirection>(
                    key: const ValueKey<String>('preset-direction'),
                    semanticLabel: 'Direction',
                    expand: true,
                    selected: _spec.direction,
                    onChanged: _setDirection,
                    segments: [
                      for (final d in PresetDirection.values)
                        SsSegment(value: d, label: d.label),
                    ],
                  ),
                ),
              ClockField(
                'Clock',
                SsDropdown<String>(
                  key: const ValueKey<String>('preset-clock'),
                  semanticLabel: 'Clock',
                  value: _spec.clockId,
                  onChanged: _setClock,
                  items: [
                    for (final c in clocks)
                      SsDropdownItem(value: c.clock.id, label: c.label),
                  ],
                ),
              ),
              if (!kind.hasDirection)
                _range(
                  'Range',
                  _spec.inRange,
                  (r) => _spec = _spec.copyWith(inRange: r),
                )
              else ...[
                if (_spec.direction.hasIn)
                  _range(
                    'In',
                    _spec.inRange,
                    (r) => _spec = _spec.copyWith(inRange: r),
                  ),
                if (_spec.direction.hasOut)
                  _range(
                    'Out',
                    _spec.outRange,
                    (r) => _spec = _spec.copyWith(outRange: r),
                  ),
              ],
              if (kind.amountLabel case final label?)
                ClockField(
                  label,
                  SsNumberField(
                    key: const ValueKey<String>('preset-amount'),
                    value: _spec.amount,
                    unit: kind.amountUnit,
                    semanticLabel: label,
                    min: kind.minAmount,
                    max: kind.maxAmount,
                    step: kind == MotionPresetKind.scaleIn ? 0.05 : 1,
                    onChanged: (v) =>
                        setState(() => _spec = _spec.copyWith(amount: v)),
                  ),
                ),
              ClockField(
                'Easing',
                SsDropdown<ir.Easing>(
                  key: const ValueKey<String>('preset-easing'),
                  semanticLabel: 'Easing',
                  value: _spec.easing,
                  hint: 'Custom',
                  onChanged: (e) =>
                      setState(() => _spec = _spec.copyWith(easing: e)),
                  items: [
                    for (final e in kPresetChoices)
                      SsDropdownItem(
                        value: e,
                        label: e is ir.PresetEasing
                            ? presetLabel(e.preset)
                            : 'Linear',
                      ),
                  ],
                ),
              ),
              if (error != null)
                Text(
                  error,
                  key: const ValueKey<String>('preset-error'),
                  style: t.text.caption.copyWith(color: t.colors.danger),
                ),
            ],
          ),
        ),
      ),
      actions: [
        SsButton(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
        SsButton(
          key: const ValueKey<String>('preset-apply'),
          label: 'Add preset',
          variant: SsButtonVariant.primary,
          onPressed: error == null
              ? () => Navigator.of(context).pop(_spec)
              : null,
        ),
      ],
    );
  }
}
