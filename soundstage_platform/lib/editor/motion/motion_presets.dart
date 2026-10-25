import 'package:flutter/foundation.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/command.dart';
import '../core/commands/motion_commands.dart';
import '../core/commands/property_commands.dart';
import '../core/editor_state.dart';

// Motion presets (m2.md "Motion presets"; architecture §10.2): editor macros
// that write ordinary tracks and keyframes. The preset is not stored; once
// applied, the result is just tracks.
//
// Keyframe values are relative to the node's static values: a rise at
// `translateY = 0` with distance 40 runs from 40 to 0 (the node ends where
// it rests). *Out* is the same motion played the other way, from the rest
// value to the offset one; *In-out* is both on one track.

/// A motion preset.
enum MotionPresetKind {
  fade('Fade'),
  rise('Rise'),
  fall('Fall'),
  slideLeft('Slide left'),
  slideRight('Slide right'),
  scaleIn('Scale'),
  blurIn('Blur'),
  parallax('Parallax');

  const MotionPresetKind(this.label);

  final String label;

  /// Whether the preset has In / Out / In-out; parallax is one continuous
  /// move over a range of the scroll clock.
  bool get hasDirection => this != parallax;

  /// Whether the preset only makes sense on a scroll clock.
  bool get scrollOnly => this == parallax;

  /// The label of the amount field, null when there is none. For parallax
  /// the amount is the shift each way (a positive shift lags the scroll).
  String? get amountLabel => switch (this) {
    fade => null,
    rise || fall || slideLeft || slideRight => 'Distance',
    scaleIn => 'Scale from',
    blurIn => 'Blur',
    parallax => 'Shift',
  };

  /// The unit shown after the amount.
  String get amountUnit => switch (this) {
    scaleIn => '×',
    _ => 'px',
  };

  double get defaultAmount => switch (this) {
    fade => 0,
    rise || fall => 40,
    slideLeft || slideRight => 80,
    scaleIn => 0.8,
    blurIn => 12,
    parallax => 80,
  };

  double get minAmount => switch (this) {
    scaleIn => 0,
    blurIn => 0,
    parallax => -2000,
    _ => -2000,
  };

  double get maxAmount => switch (this) {
    scaleIn => 4,
    blurIn => 200,
    _ => 2000,
  };
}

/// Which way the preset plays.
enum PresetDirection {
  inward('In'),
  outward('Out'),
  inOut('In-out');

  const PresetDirection(this.label);

  final String label;
  bool get hasIn => this != outward;
  bool get hasOut => this != inward;
}

/// A range of clock values.
typedef ClockRange = (double, double);

/// What the preset dialog asks for, and what [ApplyMotionPreset] writes.
@immutable
class MotionPresetSpec {
  const MotionPresetSpec({
    required this.kind,
    required this.direction,
    required this.clockId,
    required this.inRange,
    required this.outRange,
    required this.amount,
    required this.easing,
  });

  final MotionPresetKind kind;
  final PresetDirection direction;
  final String clockId;

  /// Where *in* plays (and, for parallax, the whole move).
  final ClockRange inRange;

  /// Where *out* plays.
  final ClockRange outRange;

  /// The distance, scale, blur or shift (see [MotionPresetKind.amountLabel]).
  final double amount;
  final ir.Easing easing;

  MotionPresetSpec copyWith({
    MotionPresetKind? kind,
    PresetDirection? direction,
    String? clockId,
    ClockRange? inRange,
    ClockRange? outRange,
    double? amount,
    ir.Easing? easing,
  }) => MotionPresetSpec(
    kind: kind ?? this.kind,
    direction: direction ?? this.direction,
    clockId: clockId ?? this.clockId,
    inRange: inRange ?? this.inRange,
    outRange: outRange ?? this.outRange,
    amount: amount ?? this.amount,
    easing: easing ?? this.easing,
  );

  @override
  bool operator ==(Object other) =>
      other is MotionPresetSpec &&
      other.kind == kind &&
      other.direction == direction &&
      other.clockId == clockId &&
      other.inRange == inRange &&
      other.outRange == outRange &&
      other.amount == amount &&
      other.easing == easing;

  @override
  int get hashCode =>
      Object.hash(kind, direction, clockId, inRange, outRange, amount, easing);
}

/// The default *in* and *out* ranges on [clock] (m2.md): the first and last
/// 30 % of a scene-scroll clock, the first and last 0.6 s of a timeline
/// clock (each at most half the duration of a short timeline). Other clocks
/// use 30 % of their span.
(ClockRange, ClockRange) defaultPresetRanges(ir.Clock clock, ClockRange span) {
  final (lo, hi) = span;
  final len = switch (clock) {
    ir.TimelineClock() => (hi - lo) / 2 < 0.6 ? (hi - lo) / 2 : 0.6,
    _ => (hi - lo) * 0.3,
  };
  return ((lo, lo + len), (hi - len, hi));
}

/// The easing a preset starts with: ease out for *in*, ease in for *out*,
/// ease in-out for *in-out*, linear for parallax (it follows the scroll).
ir.Easing defaultPresetEasing(
  MotionPresetKind kind,
  PresetDirection direction,
) {
  if (kind.scrollOnly) return const ir.Easing.linear();
  return ir.Easing.preset(switch (direction) {
    PresetDirection.inward => ir.EasingPreset.easeOut,
    PresetDirection.outward => ir.EasingPreset.easeIn,
    PresetDirection.inOut => ir.EasingPreset.easeInOut,
  });
}

/// The default spec of [kind] on [clock].
MotionPresetSpec defaultPresetSpec(
  MotionPresetKind kind,
  ir.Clock clock,
  ClockRange span, {
  PresetDirection direction = PresetDirection.inward,
}) {
  final (inRange, outRange) = kind.scrollOnly
      ? (span, span)
      : defaultPresetRanges(clock, span);
  return MotionPresetSpec(
    kind: kind,
    direction: direction,
    clockId: clock.id,
    inRange: inRange,
    outRange: outRange,
    amount: kind.defaultAmount,
    easing: defaultPresetEasing(kind, direction),
  );
}

/// A message when [spec]'s ranges are unusable, else null.
String? validatePresetSpec(MotionPresetSpec spec, ClockRange span) {
  bool bad(ClockRange r) =>
      !(r.$1.isFinite && r.$2.isFinite) || r.$2 <= r.$1 || r.$1 < span.$1;
  if (spec.kind.scrollOnly || spec.direction.hasIn) {
    if (bad(spec.inRange)) {
      return spec.kind.scrollOnly
          ? 'The range must end after it starts.'
          : 'The In range must end after it starts.';
    }
  }
  if (!spec.kind.scrollOnly && spec.direction.hasOut && bad(spec.outRange)) {
    return 'The Out range must end after it starts.';
  }
  if (!spec.kind.scrollOnly &&
      spec.direction == PresetDirection.inOut &&
      spec.outRange.$1 < spec.inRange.$2) {
    return 'Out must start after In ends.';
  }
  return null;
}

/// One property a preset animates on one node: where the node rests and
/// the value it plays from / to.
typedef _Channel = ({String property, ir.IrValue rest, ir.IrValue away});

/// The new keyframes of one channel as (time, value, easing), in time
/// order, plus the clock ranges they replace.
({List<(double, ir.IrValue, ir.Easing)> keys, List<ClockRange> replaced})
_keysOf(_Channel c, MotionPresetSpec spec) {
  final keys = <(double, ir.IrValue, ir.Easing)>[];
  final replaced = <ClockRange>[];
  const linear = ir.Easing.linear();
  if (spec.kind.scrollOnly) {
    keys
      ..add((spec.inRange.$1, c.away, spec.easing))
      ..add((spec.inRange.$2, c.rest, linear));
    replaced.add(spec.inRange);
    return (keys: keys, replaced: replaced);
  }
  if (spec.direction.hasIn) {
    keys
      ..add((spec.inRange.$1, c.away, spec.easing))
      ..add((spec.inRange.$2, c.rest, linear));
    replaced.add(spec.inRange);
  }
  if (spec.direction.hasOut) {
    keys
      ..add((spec.outRange.$1, c.rest, spec.easing))
      ..add((spec.outRange.$2, c.away, linear));
    replaced.add(spec.outRange);
  }
  return (keys: keys, replaced: replaced);
}

ir.IrValue _num(double v) => ir.IrValue.number(v);

double? _numberOf(ir.IrValue? v) => v is ir.NumberValue ? v.value : null;

/// The command that writes [spec] onto [nodeIds] of scene [sceneId]: one
/// undo step.
///
/// Per node and per animated property (opacity; `motion.translateX/Y`;
/// `motion.scaleX` and `scaleY`; the first layer blur's radius, added at 0
/// when the node has none):
///
/// - the rest value is the node's static value at the edit scope (the base
///   for *Both*, the edited breakpoint for *This breakpoint*), and the
///   offset value is derived from it (rest + distance, rest × scale, …);
/// - with *This breakpoint* the track is breakpoint-specific, otherwise it
///   applies to all breakpoints;
/// - a track that already animates the property on that clock (same
///   breakpoints) is merged: its keyframes inside the preset's range are
///   replaced, the others stay. Otherwise a new track is added.
///
/// A node a property does not apply to is skipped with a warning while
/// others succeed.
class ApplyMotionPreset extends EditCommand {
  const ApplyMotionPreset(this.sceneId, this.nodeIds, this.spec, {this.ids});

  final String sceneId;
  final List<String> nodeIds;
  final MotionPresetSpec spec;

  /// Makes track, keyframe and effect ids (tests).
  final ir.IdGenerator? ids;

  @override
  String get label => 'Add ${spec.kind.label.toLowerCase()} preset';

  @override
  CommandResult apply(EditorState state) {
    final doc = state.document;
    final scene = doc.scenes.where((s) => s.id == sceneId).firstOrNull;
    if (scene == null) {
      return failedCommand(state, label, [
        commandError('Scene "$sceneId" does not exist.'),
      ]);
    }
    if (!scene.clocks.any((c) => c.id == spec.clockId)) {
      return failedCommand(state, label, [
        commandError('Clock "${spec.clockId}" does not exist.'),
      ]);
    }
    final thisBreakpoint = state.effectiveScope == EditScope.thisBreakpoint;
    final bp = state.breakpointId;
    if (thisBreakpoint && bp == null) {
      return failedCommand(state, label, [
        commandError('There is no edited breakpoint.'),
      ]);
    }
    final result = perNode(
      doc,
      nodeIds,
      (d, id) => _applyToNode(d, id, thisBreakpoint ? bp : null),
    );
    return resultOf(state, result, label: label);
  }

  ir.EditResult _applyToNode(
    ir.StageDocument doc,
    String nodeId,
    String? breakpoint,
  ) {
    final reg = ir.PropertyRegistry.standard;
    var current = doc;
    String? blurId;
    if (spec.kind == MotionPresetKind.blurIn) {
      final blur = _ensureBlur(current, nodeId, reg);
      if (blur == null) return _notApplicable(doc, nodeId);
      (current, blurId) = blur;
    }
    final channels = _channels(current, nodeId, breakpoint, reg, blurId);
    if (channels.isEmpty) return _notApplicable(doc, nodeId);
    var changed = !identical(current, doc);
    for (final channel in channels) {
      final r = _writeChannel(current, nodeId, channel, breakpoint, reg);
      if (!r.ok) {
        return ir.EditResult(
          document: doc,
          changed: false,
          diagnostics: r.diagnostics,
        );
      }
      current = r.document;
      changed |= r.changed;
    }
    return ir.EditResult(document: current, changed: changed);
  }

  ir.EditResult _notApplicable(ir.StageDocument doc, String nodeId) =>
      ir.EditResult(
        document: doc,
        changed: false,
        diagnostics: [
          commandError(
            'The ${spec.kind.label.toLowerCase()} preset does not apply to '
            '"$nodeId".',
            nodeId: nodeId,
          ),
        ],
      );

  // ---- Channels ------------------------------------------------------------

  List<_Channel> _channels(
    ir.StageDocument doc,
    String nodeId,
    String? breakpoint,
    ir.PropertyRegistry reg,
    String? blurId,
  ) {
    double? rest(String path) =>
        _numberOf(staticValueAt(doc, nodeId, path, breakpoint, registry: reg));
    _Channel? shift(String path, double sign) {
      final r = rest(path);
      if (r == null) return null;
      return (
        property: path,
        rest: _num(r),
        away: _num(r + sign * spec.amount),
      );
    }

    return switch (spec.kind) {
      MotionPresetKind.fade => [
        if (rest('opacity') case final r?)
          (property: 'opacity', rest: _num(r), away: _num(0)),
      ],
      MotionPresetKind.rise => [?shift('motion.translateY', 1)],
      MotionPresetKind.fall => [?shift('motion.translateY', -1)],
      MotionPresetKind.slideLeft => [?shift('motion.translateX', 1)],
      MotionPresetKind.slideRight => [?shift('motion.translateX', -1)],
      // Symmetric about the middle of the range: it starts `amount` above
      // its rest position and ends `amount` below, so it drifts against the
      // scroll by twice the shift.
      MotionPresetKind.parallax => [
        if (rest('motion.translateY') case final r?)
          (
            property: 'motion.translateY',
            rest: _num(r + spec.amount),
            away: _num(r - spec.amount),
          ),
      ],
      MotionPresetKind.scaleIn => [
        for (final p in const ['motion.scaleX', 'motion.scaleY'])
          if (rest(p) case final r?)
            (property: p, rest: _num(r), away: _num(r * spec.amount)),
      ],
      MotionPresetKind.blurIn => [
        (
          property: 'effects.$blurId.blur',
          rest: _num(rest('effects.$blurId.blur') ?? 0),
          away: _num(spec.amount),
        ),
      ],
    };
  }

  /// The node's first layer blur, adding one at radius 0 when it has none:
  /// the document with it and its id, or null where the node has no effects
  /// (instance inner nodes, for one).
  (ir.StageDocument, String)? _ensureBlur(
    ir.StageDocument doc,
    String nodeId,
    ir.PropertyRegistry reg,
  ) {
    if (nodeId.contains('/')) return null;
    final node = ir.DocumentIndex.of(doc).node(nodeId);
    if (node == null) return null;
    final effects = reg.get(node, 'effects');
    if (effects is! ir.EffectsValue) return null;
    final existing = effects.value.whereType<ir.LayerBlur>().firstOrNull;
    if (existing != null) return (doc, existing.id);
    final id = freshMotionId({for (final e in effects.value) e.id}, ids);
    final r = ir.updateNode(
      doc,
      nodeId,
      (n) =>
          reg.trySet(
            n,
            'effects',
            ir.IrValue.effects([
              ...effects.value,
              ir.Effect.layerBlur(id: id, radius: 0),
            ]),
          ) ??
          n,
    );
    return r.ok && r.changed ? (r.document, id) : null;
  }

  // ---- Writing -------------------------------------------------------------

  ir.EditResult _writeChannel(
    ir.StageDocument doc,
    String nodeId,
    _Channel channel,
    String? breakpoint,
    ir.PropertyRegistry reg,
  ) {
    final scene = doc.scenes.firstWhere((s) => s.id == sceneId);
    final planned = _keysOf(channel, spec);
    bool inReplaced(double t) => planned.replaced.any(
      (r) =>
          t >= r.$1 - ir.kKeyframeTimeEpsilon &&
          t <= r.$2 + ir.kKeyframeTimeEpsilon,
    );
    final breakpoints = breakpoint == null ? null : [breakpoint];
    final existing = scene.tracks.where(
      (t) =>
          t.target == nodeId &&
          t.property == channel.property &&
          t.clockId == spec.clockId &&
          listEquals(t.breakpoints, breakpoints),
    );
    if (existing.isNotEmpty) {
      final track = existing.first;
      final used = {for (final k in track.keyframes) k.id};
      String next() {
        final id = freshMotionId(used, ids);
        used.add(id);
        return id;
      }

      final kept = [
        for (final k in track.keyframes)
          if (!inReplaced(k.t)) k,
      ];
      return ir.updateTrack(
        doc,
        sceneId,
        track.id,
        (t) => t.copyWith(
          keyframes: [
            ...kept,
            for (final (time, value, easing) in planned.keys)
              ir.Keyframe(id: next(), t: time, value: value, easing: easing),
          ],
        ),
        registry: reg,
      );
    }
    final used = <String>{};
    String next() {
      final id = freshMotionId(used, ids);
      used.add(id);
      return id;
    }

    return ir.addTrack(
      doc,
      sceneId,
      ir.Track(
        id: freshMotionId(trackIdsOf(doc, sceneId), ids),
        target: nodeId,
        property: channel.property,
        clockId: spec.clockId,
        breakpoints: breakpoints,
        keyframes: [
          for (final (time, value, easing) in planned.keys)
            ir.Keyframe(id: next(), t: time, value: value, easing: easing),
        ],
      ),
      registry: reg,
    );
  }
}
