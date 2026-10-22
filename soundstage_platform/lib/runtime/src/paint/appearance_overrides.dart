// Typed paint overrides (T0.6b, architecture §14, §17.1): animated values
// for the numeric and colour properties of a frame's or shape's appearance,
// written by the animator without allocating and read by the paint seam
// at paint time.

import 'dart:typed_data';

import 'package:soundstage_platform/ir/ir.dart' as ir;

/// The paint stack a paint override addresses.
enum StagePaintStack { fills, strokes }

/// The appearance field a typed override writes.
enum StageAppearanceField {
  /// `<stack>.<paintId>.color` (solid paints): r, g, b, a.
  paintColor,

  /// `<stack>.<paintId>.opacity` (any paint).
  paintOpacity,

  /// `<stack>.<paintId>.stops.<i>.color` (gradients): r, g, b, a.
  stopColor,

  /// `<stack>.<paintId>.stops.<i>.position` (gradients).
  stopPosition,

  /// `strokes.weight`: top, right, bottom, left, plus a uniform flag.
  strokeWeight,

  /// `strokes.weight.top|right|bottom|left` (index 0–3).
  strokeSide,

  /// `effects.<effectId>.color` (shadows): r, g, b, a.
  effectColor,

  /// `effects.<effectId>.offset` (shadows): x, y.
  effectOffset,

  /// `effects.<effectId>.blur`: a shadow's blur or a blur effect's radius.
  effectBlur,

  /// `effects.<effectId>.spread` (shadows).
  effectSpread,

  /// `effects.<effectId>.radius` (layer and background blurs only).
  effectRadius,

  /// `cornerRadius`: tl, tr, br, bl, plus a uniform flag.
  cornerRadius,

  /// `cornerRadius.tl|tr|br|bl` (index 0–3).
  corner,

  /// `cornerSmoothing`.
  cornerSmoothing,
}

/// A property path that has a typed paint override, parsed once at load.
final class StageAppearancePath {
  const StageAppearancePath(this.field, {this.stack, this.id, this.index = -1});

  final StageAppearanceField field;

  /// The paint stack, for paint fields.
  final StagePaintStack? stack;

  /// The paint or effect id.
  final String? id;

  /// The gradient stop, stroke side or corner index.
  final int index;

  /// Components the value has (the compiled track's stride).
  int get stride => switch (field) {
    StageAppearanceField.paintColor ||
    StageAppearanceField.stopColor ||
    StageAppearanceField.effectColor ||
    StageAppearanceField.strokeWeight ||
    StageAppearanceField.cornerRadius => 4,
    StageAppearanceField.effectOffset => 2,
    _ => 1,
  };

  /// Whether a change can move the node's layout (its stroke outsets).
  bool get affectsLayout =>
      field == StageAppearanceField.strokeWeight ||
      field == StageAppearanceField.strokeSide;

  /// The typed override for [path], or null when [path] goes through the
  /// property registry instead.
  static StageAppearancePath? parse(String path) {
    final s = path.split('.');
    switch (s) {
      case ['cornerRadius']:
        return const StageAppearancePath(StageAppearanceField.cornerRadius);
      case ['cornerRadius', final c]:
        final i = const ['tl', 'tr', 'br', 'bl'].indexOf(c);
        return i < 0
            ? null
            : StageAppearancePath(StageAppearanceField.corner, index: i);
      case ['cornerSmoothing']:
        return const StageAppearancePath(StageAppearanceField.cornerSmoothing);
      case ['strokes', 'weight']:
        return const StageAppearancePath(StageAppearanceField.strokeWeight);
      case ['strokes', 'weight', final side]:
        final i = const ['top', 'right', 'bottom', 'left'].indexOf(side);
        return i < 0
            ? null
            : StageAppearancePath(StageAppearanceField.strokeSide, index: i);
      case ['effects', final id, final f] when id.isNotEmpty:
        final field = switch (f) {
          'color' => StageAppearanceField.effectColor,
          'offset' => StageAppearanceField.effectOffset,
          'blur' => StageAppearanceField.effectBlur,
          'spread' => StageAppearanceField.effectSpread,
          'radius' => StageAppearanceField.effectRadius,
          _ => null,
        };
        return field == null ? null : StageAppearancePath(field, id: id);
      case ['fills', ...final rest]:
        return _paint(StagePaintStack.fills, rest);
      case ['strokes', 'paints', ...final rest]:
        return _paint(StagePaintStack.strokes, rest);
    }
    return null;
  }

  static StageAppearancePath? _paint(StagePaintStack stack, List<String> s) {
    switch (s) {
      case [final id, 'color'] when id.isNotEmpty:
        return StageAppearancePath(
          StageAppearanceField.paintColor,
          stack: stack,
          id: id,
        );
      case [final id, 'opacity'] when id.isNotEmpty:
        return StageAppearancePath(
          StageAppearanceField.paintOpacity,
          stack: stack,
          id: id,
        );
      case [final id, 'stops', final i, final f] when id.isNotEmpty:
        final index = _index(i);
        if (index == null) return null;
        final field = switch (f) {
          'color' => StageAppearanceField.stopColor,
          'position' => StageAppearanceField.stopPosition,
          _ => null,
        };
        return field == null
            ? null
            : StageAppearancePath(field, stack: stack, id: id, index: index);
    }
    return null;
  }

  // The registry's `<…Index>` params accept digits only.
  static int? _index(String s) =>
      RegExp(r'^\d+$').hasMatch(s) ? int.tryParse(s) : null;

  @override
  String toString() =>
      'StageAppearancePath(${field.name}, ${stack?.name}, $id, $index)';
}

/// One typed override: the value of one track, written in place.
final class StageAppearanceChannel {
  StageAppearanceChannel(this.path);

  final StageAppearancePath path;

  /// The value's components (see [StageAppearanceField]).
  final Float64List values = Float64List(4);

  /// For `cornerRadius` / `strokes.weight`: whether the value is uniform
  /// (both keyframes of the segment were uniform), like the oracle.
  bool uniform = true;

  /// Whether a value has been written.
  bool hasValue = false;

  /// Writes [stride] components from [source] (allocation-free).
  void write(Float64List source, {bool uniform = true}) {
    final n = path.stride;
    for (var i = 0; i < n; i++) {
      values[i] = source[i];
    }
    this.uniform = uniform;
    hasValue = true;
  }

  ir.StageColor get _color =>
      ir.StageColor(r: values[0], g: values[1], b: values[2], a: values[3]);
}

/// The typed paint overrides of one render object (frames and shapes).
///
/// The animator adds one [StageAppearanceChannel] per typed track when the
/// track binds, and writes it per frame without allocating. The paint seam
/// reads the overrides at paint time through [paint], [effect],
/// [strokeWeight], [cornerRadius] and [cornerSmoothing], which return the
/// base value when nothing overrides it (and allocate only the overridden
/// element, at paint time).
///
/// Overrides apply after the node's registry overrides
/// (`RenderStageBox.nodeAnimator`), in track order. Paints and effects are
/// addressed by id, so they follow the resolved node when it changes.
///
/// The structural queries ([mayHidePaint], [overridesBlurRadius],
/// [overridesPaint]) depend only on which channels exist, not on their
/// values, so animated values never change a node's compositing.
final class StageAppearanceOverrides {
  final List<StageAppearanceChannel> _channels = [];

  bool get isEmpty => _channels.isEmpty;

  /// The channels, in binding order.
  List<StageAppearanceChannel> get channels => _channels;

  /// Adds a channel for [path].
  StageAppearanceChannel add(StageAppearancePath path) {
    final c = StageAppearanceChannel(path);
    _channels.add(c);
    return c;
  }

  void clear() => _channels.clear();

  // ---- Structural queries (allocation-free) --------------------------------

  /// Whether paint [id] of [stack] has any override (its colour, opacity or
  /// stops).
  bool overridesPaint(StagePaintStack stack, String id) {
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      final p = cs[i].path;
      if (p.stack == stack && p.id == id) return true;
    }
    return false;
  }

  /// Whether paint [id] of [stack] has an opacity override, so it may be
  /// visible even when its base opacity is 0 (count it as a painted part).
  bool mayHidePaint(StagePaintStack stack, String id) {
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      final p = cs[i].path;
      if (p.field == StageAppearanceField.paintOpacity &&
          p.stack == stack &&
          p.id == id) {
        return true;
      }
    }
    return false;
  }

  /// Whether blur effect [id] has an animated radius, so it may need its
  /// layer even when its base radius is 0.
  bool overridesBlurRadius(String id) {
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      final p = cs[i].path;
      if ((p.field == StageAppearanceField.effectBlur ||
              p.field == StageAppearanceField.effectRadius) &&
          p.id == id) {
        return true;
      }
    }
    return false;
  }

  /// Whether the stroke weight is overridden.
  bool get overridesStrokeWeight {
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      if (cs[i].path.affectsLayout) return true;
    }
    return false;
  }

  // ---- Paint-time reads -------------------------------------------------------

  /// [p] of [stack] with its overrides applied ([p] itself when none).
  ir.Paint paint(StagePaintStack stack, ir.Paint p) {
    final id = p.id;
    var out = p;
    List<ir.ColorStop>? stops;
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i];
      final path = c.path;
      if (!c.hasValue || path.stack != stack || path.id != id) continue;
      switch (path.field) {
        case StageAppearanceField.paintColor:
          if (out is ir.SolidPaint) out = out.copyWith(color: c._color);
        case StageAppearanceField.paintOpacity:
          out = switch (out) {
            ir.SolidPaint() => out.copyWith(opacity: c.values[0]),
            ir.GradientPaint() => out.copyWith(opacity: c.values[0]),
            ir.ImagePaint() => out.copyWith(opacity: c.values[0]),
          };
        case StageAppearanceField.stopColor ||
            StageAppearanceField.stopPosition:
          if (out is! ir.GradientPaint) continue;
          final s = stops ??= [...out.stops];
          final k = path.index;
          if (k >= s.length) continue;
          s[k] = path.field == StageAppearanceField.stopColor
              ? s[k].copyWith(color: c._color)
              : s[k].copyWith(position: c.values[0]);
        default:
          break;
      }
    }
    if (stops != null && out is ir.GradientPaint) {
      out = out.copyWith(stops: stops);
    }
    return out;
  }

  /// [e] with its overrides applied ([e] itself when none).
  ir.Effect effect(ir.Effect e) {
    final id = e.id;
    var out = e;
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i];
      final path = c.path;
      if (!c.hasValue || path.stack != null || path.id != id) continue;
      final v = c.values;
      out = switch ((path.field, out)) {
        (StageAppearanceField.effectColor, final ir.DropShadow s) => s.copyWith(
          color: c._color,
        ),
        (StageAppearanceField.effectColor, final ir.InnerShadow s) =>
          s.copyWith(color: c._color),
        (StageAppearanceField.effectOffset, final ir.DropShadow s) =>
          s.copyWith(
            offset: ir.StagePoint(x: v[0], y: v[1]),
          ),
        (StageAppearanceField.effectOffset, final ir.InnerShadow s) =>
          s.copyWith(
            offset: ir.StagePoint(x: v[0], y: v[1]),
          ),
        (StageAppearanceField.effectSpread, final ir.DropShadow s) =>
          s.copyWith(spread: v[0]),
        (StageAppearanceField.effectSpread, final ir.InnerShadow s) =>
          s.copyWith(spread: v[0]),
        (StageAppearanceField.effectBlur, final ir.DropShadow s) => s.copyWith(
          blur: v[0],
        ),
        (StageAppearanceField.effectBlur, final ir.InnerShadow s) => s.copyWith(
          blur: v[0],
        ),
        (
          StageAppearanceField.effectBlur || StageAppearanceField.effectRadius,
          final ir.LayerBlur b,
        ) =>
          b.copyWith(radius: v[0]),
        (
          StageAppearanceField.effectBlur || StageAppearanceField.effectRadius,
          final ir.BackgroundBlur b,
        ) =>
          b.copyWith(radius: v[0]),
        _ => out,
      };
    }
    return out;
  }

  /// The effective stroke weight over [base].
  ir.StrokeWeight strokeWeight(ir.StrokeWeight base) {
    var out = base;
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i];
      if (!c.hasValue) continue;
      final v = c.values;
      switch (c.path.field) {
        case StageAppearanceField.strokeWeight:
          out = c.uniform
              ? ir.StrokeWeight.uniform(v[0])
              : ir.StrokeWeight.perSide(
                  top: v[0],
                  right: v[1],
                  bottom: v[2],
                  left: v[3],
                );
        case StageAppearanceField.strokeSide:
          final s = switch (out) {
            ir.PerSideStrokeWeight() => out,
            ir.UniformStrokeWeight(:final weight) => ir.PerSideStrokeWeight(
              top: weight,
              right: weight,
              bottom: weight,
              left: weight,
            ),
          };
          out = switch (c.path.index) {
            0 => s.copyWith(top: v[0]),
            1 => s.copyWith(right: v[0]),
            2 => s.copyWith(bottom: v[0]),
            _ => s.copyWith(left: v[0]),
          };
        default:
          break;
      }
    }
    return out;
  }

  /// [base] with an overridden stroke weight ([base] itself when none).
  ir.Stroke stroke(ir.Stroke base) {
    if (!overridesStrokeWeight) return base;
    final w = strokeWeight(base.weight);
    return identical(w, base.weight) ? base : base.copyWith(weight: w);
  }

  /// The effective corner radius over [base].
  ir.CornerRadius cornerRadius(ir.CornerRadius base) {
    var out = base;
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i];
      if (!c.hasValue) continue;
      final v = c.values;
      switch (c.path.field) {
        case StageAppearanceField.cornerRadius:
          out = c.uniform
              ? ir.CornerRadius.uniform(v[0])
              : ir.CornerRadius.perCorner(
                  tl: v[0],
                  tr: v[1],
                  br: v[2],
                  bl: v[3],
                );
        case StageAppearanceField.corner:
          final r = switch (out) {
            ir.CornerRadii() => out,
            ir.UniformCornerRadius(:final radius) => ir.CornerRadii(
              tl: radius,
              tr: radius,
              br: radius,
              bl: radius,
            ),
          };
          out = switch (c.path.index) {
            0 => r.copyWith(tl: v[0]),
            1 => r.copyWith(tr: v[0]),
            2 => r.copyWith(br: v[0]),
            _ => r.copyWith(bl: v[0]),
          };
        default:
          break;
      }
    }
    return out;
  }

  /// The effective corner smoothing over [base].
  double cornerSmoothing(double base) {
    var out = base;
    final cs = _channels;
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i];
      if (c.hasValue && c.path.field == StageAppearanceField.cornerSmoothing) {
        out = c.values[0];
      }
    }
    return out;
  }

  /// [a] as painted: every override applied. The paint seam reads the
  /// overrides element by element instead; this is for tests and
  /// diagnostics (it allocates).
  ir.Appearance apply(ir.Appearance a) => a.copyWith(
    fills: [for (final p in a.fills) paint(StagePaintStack.fills, p)],
    strokes: stroke(a.strokes).copyWith(
      paints: [
        for (final p in a.strokes.paints) paint(StagePaintStack.strokes, p),
      ],
    ),
    effects: [for (final e in a.effects) effect(e)],
    cornerRadius: cornerRadius(a.cornerRadius),
    cornerSmoothing: cornerSmoothing(a.cornerSmoothing),
  );
}
