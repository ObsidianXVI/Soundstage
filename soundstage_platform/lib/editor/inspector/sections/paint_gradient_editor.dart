import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart' show stageColor;

import '../../canvas/canvas_controller.dart';
import '../fields/field_frame.dart';
import '../fields/props.dart';
import '../fields/rows.dart';
import '../property_writer.dart';
import 'paint_stack.dart';

// The gradient editor of an expanded paint: the stops bar, the selected
// stop's position and colour, reverse, and the geometry (an angle for
// linear gradients; numeric handles for radial, angular and diamond until
// the on-canvas handles of T1.7b).
//
// Angle convention (linear): degrees clockwise on screen, 0° = top → bottom
// (the default handles (0.5, 0) → (0.5, 1)), 90° = right → left,
// -90° = left → right. That is the CSS `linear-gradient` angle minus 180°.
// The angle is measured in the node's pixel space when its size is known
// (so it is the visual angle), else in the normalised box. Setting it
// rewrites `handles.start` / `handles.end` through the node centre,
// keeping the line's length.

const double _barInset = 6;
const double _barHeight = 24;
const double _hitSlop = 8;

double _r4(double v) => (v * 1e4).roundToDouble() / 1e4;
double _r6(double v) => (v * 1e6).roundToDouble() / 1e6;

/// [stops] sorted by position, ties keeping their order.
List<ir.ColorStop> sortStops(List<ir.ColorStop> stops) {
  final idx = List<int>.generate(stops.length, (i) => i)
    ..sort((a, b) {
      final c = stops[a].position.compareTo(stops[b].position);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in idx) stops[i]];
}

/// The colour of the gradient at [p] (stops interpolated in sRGB, as the
/// runtime's shaders do).
ir.StageColor gradientColorAt(List<ir.ColorStop> stops, double p) {
  if (stops.isEmpty) return ir.StageColor.black;
  final s = sortStops(stops);
  if (p <= s.first.position) return s.first.color;
  if (p >= s.last.position) return s.last.color;
  for (var i = 0; i + 1 < s.length; i++) {
    final a = s[i], b = s[i + 1];
    if (p >= a.position && p <= b.position) {
      final span = b.position - a.position;
      final t = span <= 0 ? 0.0 : (p - a.position) / span;
      double l(double x, double y) => _r6(x + (y - x) * t);
      return ir.StageColor(
        r: l(a.color.r, b.color.r),
        g: l(a.color.g, b.color.g),
        b: l(a.color.b, b.color.b),
        a: l(a.color.a, b.color.a),
      );
    }
  }
  return s.last.color;
}

/// The linear angle (see the convention above) of [h] on a [w] x [h] box.
double gradientAngle(ir.GradientHandles handles, double w, double h) {
  final dx = (handles.end.x - handles.start.x) * w;
  final dy = (handles.end.y - handles.start.y) * h;
  if (dx == 0 && dy == 0) return 0;
  final deg = math.atan2(-dx, dy) * 180 / math.pi;
  return deg <= -180 ? deg + 360 : deg;
}

/// Handles for [degrees] through the box centre, keeping the length of the
/// current line (in pixels on a [w] x [h] box).
({ir.StagePoint start, ir.StagePoint end}) handlesForAngle(
  ir.GradientHandles handles,
  double degrees,
  double w,
  double h,
) {
  final dx = (handles.end.x - handles.start.x) * w;
  final dy = (handles.end.y - handles.start.y) * h;
  var len = math.sqrt(dx * dx + dy * dy);
  if (len == 0) len = h;
  final rad = degrees * math.pi / 180;
  final ndx = -math.sin(rad) * len / w;
  final ndy = math.cos(rad) * len / h;
  return (
    start: ir.StagePoint(x: _r6(0.5 - ndx / 2), y: _r6(0.5 - ndy / 2)),
    end: ir.StagePoint(x: _r6(0.5 + ndx / 2), y: _r6(0.5 + ndy / 2)),
  );
}

class PaintGradientEditor extends ConsumerStatefulWidget {
  const PaintGradientEditor({
    required this.stackPath,
    required this.paint,
    super.key,
  });

  final String stackPath;
  final ir.GradientPaint paint;

  @override
  ConsumerState<PaintGradientEditor> createState() =>
      _PaintGradientEditorState();
}

class _PaintGradientEditorState extends ConsumerState<PaintGradientEditor> {
  final FocusNode _focus = FocusNode(debugLabel: 'Gradient stops');
  int? _down;
  int? _drag;

  String get _path => '${widget.stackPath}.${widget.paint.id}';
  List<ir.ColorStop> get _stops => widget.paint.stops;

  PropertyWriter get _w => InspectorScope.of(context).writer;

  int _selected(PaintUiState ui) {
    final n = _stops.length;
    if (n == 0) return 0;
    return ui.selectedStop(widget.paint.id).clamp(0, n - 1);
  }

  @override
  void dispose() {
    if (_drag != null) _w.endGesture();
    _focus.dispose();
    super.dispose();
  }

  double _posOf(double x, double width) =>
      ((x - _barInset) / math.max(1, width - 2 * _barInset)).clamp(0.0, 1.0);

  double _xOf(double p, double width) =>
      _barInset + p * math.max(0, width - 2 * _barInset);

  int? _hit(double x, double width) {
    int? best;
    var bestD = _hitSlop;
    for (var i = 0; i < _stops.length; i++) {
      final d = (_xOf(_stops[i].position, width) - x).abs();
      if (d <= bestD) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  void _writePaint(List<ir.ColorStop> stops) => _w.set(
    _path,
    ir.IrValue.paint(widget.paint.copyWith(stops: sortStops(stops))),
  );

  void _add(double p) {
    final pos = _r4(p);
    final stop = ir.ColorStop(
      position: pos,
      color: gradientColorAt(_stops, pos),
    );
    final next = sortStops([..._stops, stop]);
    _writePaint(next);
    PaintUi.of(context).selectStop(widget.paint.id, next.indexOf(stop));
  }

  void _delete(int i) {
    if (_stops.length <= 2 || i < 0 || i >= _stops.length) return;
    _writePaint([..._stops]..removeAt(i));
    PaintUi.of(context).selectStop(widget.paint.id, math.max(0, i - 1));
  }

  /// Moves stop [i] to [p], kept between its neighbours so indices (and the
  /// index-based paths) stay sorted.
  void _move(int i, double p) {
    final lo = i > 0 ? _stops[i - 1].position : 0.0;
    final hi = i < _stops.length - 1 ? _stops[i + 1].position : 1.0;
    final v = _r4(p.clamp(lo, hi));
    if (v == _stops[i].position) return;
    _w.set('$_path.stops.$i.position', ir.IrValue.number(v));
  }

  void _reverse() => _writePaint([
    for (final s in _stops.reversed) s.copyWith(position: _r4(1 - s.position)),
  ]);

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final sel = _selected(PaintUi.of(context));
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete) {
      _delete(sel);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight) {
      if (sel >= _stops.length) return KeyEventResult.ignored;
      final step = HardwareKeyboard.instance.isShiftPressed ? 0.1 : 0.01;
      final dir = k == LogicalKeyboardKey.arrowLeft ? -1 : 1;
      _move(sel, _stops[sel].position + dir * step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ui = PaintUi.of(context);
    final t = context.ss;
    final c = t.colors;
    final sel = _selected(ui);
    final p = widget.paint;
    final sorted = sortStops(_stops);

    final bar = LayoutBuilder(
      builder: (context, box) {
        final width = box.maxWidth;
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Semantics(
            label: 'Gradient stops',
            hint: 'Click to add a stop; drag a stop to move it',
            child: GestureDetector(
              key: ValueKey<String>('gradient-bar:${p.id}'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                _focus.requestFocus();
                final hit = _hit(d.localPosition.dx, width);
                if (hit != null) {
                  ui.selectStop(p.id, hit);
                } else {
                  _add(_posOf(d.localPosition.dx, width));
                }
              },
              onHorizontalDragDown: (d) =>
                  _down = _hit(d.localPosition.dx, width),
              onHorizontalDragStart: (d) {
                final i = _down;
                if (i == null) return;
                _focus.requestFocus();
                ui.selectStop(p.id, i);
                _drag = i;
                _w.beginGesture();
              },
              onHorizontalDragUpdate: (d) {
                final i = _drag;
                if (i == null) return;
                _move(i, _posOf(d.localPosition.dx, width));
              },
              onHorizontalDragEnd: (_) {
                if (_drag == null) return;
                _drag = null;
                _w.endGesture();
              },
              onHorizontalDragCancel: () {
                if (_drag == null) return;
                _drag = null;
                _w.endGesture();
              },
              child: SizedBox(
                height: _barHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: _barInset,
                      right: _barInset,
                      top: 4,
                      bottom: 4,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: SsRadius.brSm,
                          border: Border.all(color: c.border),
                        ),
                        child: SsCheckerboard(
                          cell: 4,
                          borderRadius: SsRadius.brSm,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  for (final s in sorted) stageColor(s.color),
                                  if (sorted.length == 1)
                                    stageColor(sorted.first.color),
                                ],
                                stops: [
                                  for (final s in sorted)
                                    s.position.clamp(0.0, 1.0),
                                  if (sorted.length == 1) 1.0,
                                ],
                              ),
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                    ),
                    for (var i = 0; i < _stops.length; i++)
                      Positioned(
                        left: _xOf(_stops[i].position, width) - 5,
                        top: 2,
                        child: _StopMarker(
                          key: ValueKey<String>('gradient-stop:$i'),
                          color: stageColor(_stops[i].color),
                          selected: i == sel,
                          label:
                              'Stop ${i + 1}, '
                              '${(_stops[i].position * 100).round()}%',
                          onTap: () => ui.selectStop(p.id, i),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(child: Text('Stops', style: t.text.caption)),
            GradientCanvasToggle(stackPath: widget.stackPath, paintId: p.id),
            SsIconButton(
              key: ValueKey<String>('gradient-swap:${p.id}'),
              icon: SsIcons.arrowLeftRight,
              semanticLabel: 'Reverse stops',
              tooltip: 'Reverse stops',
              size: 24,
              iconSize: 14,
              onPressed: _reverse,
            ),
          ],
        ),
        bar,
        const SizedBox(height: SsSpace.s2),
        if (sel < _stops.length) ...[
          Row(
            children: [
              Expanded(child: Text('Stop ${sel + 1}', style: t.text.caption)),
              SizedBox(
                width: 72,
                child: _StopPositionField(
                  path: '$_path.stops.$sel.position',
                  index: sel,
                  stops: _stops,
                  onMove: (v) => _move(sel, v),
                  onReorder: (v) {
                    final moved = _stops[sel].copyWith(position: _r4(v));
                    final next = [..._stops]..[sel] = moved;
                    final sortedNext = sortStops(next);
                    _writePaint(sortedNext);
                    ui.selectStop(p.id, sortedNext.indexOf(moved));
                  },
                ),
              ),
              SsIconButton(
                key: const ValueKey<String>('gradient-stop-delete'),
                icon: SsIcons.minus,
                semanticLabel: 'Delete stop',
                tooltip: 'Delete stop',
                size: 24,
                iconSize: 14,
                onPressed: _stops.length > 2 ? () => _delete(sel) : null,
              ),
            ],
          ),
          const SizedBox(height: SsSpace.s1),
          ColorProp(
            key: ValueKey<String>('stop-colour:$sel'),
            path: '$_path.stops.$sel.color',
            semanticLabel: 'Stop colour',
          ),
          const SizedBox(height: SsSpace.s2),
        ],
        if (p.kind == ir.GradientKind.linear)
          _AngleField(path: _path, paint: p)
        else ...[
          _HandleRow(label: 'Centre', path: '$_path.handles.start'),
          _HandleRow(label: 'Edge', path: '$_path.handles.end'),
          _HandleRow(label: 'Width', path: '$_path.handles.width'),
        ],
      ],
    );
  }
}

/// The single selected layer's id (authored or instance-inner), or null for
/// none or several: on-canvas gradient editing works on one layer.
String? gradientEditNodeId(BuildContext context) {
  final ids = InspectorScope.of(context).ids;
  return ids.length == 1 ? ids.single : null;
}

/// Toggles editing paint [paintId] of [stackPath] with handles on the
/// canvas (T1.7b). Enabled for a single selected layer.
class GradientCanvasToggle extends ConsumerWidget {
  const GradientCanvasToggle({
    required this.stackPath,
    required this.paintId,
    super.key,
  });

  final String stackPath;
  final String paintId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canvas = ref.watch(canvasControllerProvider);
    final node = gradientEditNodeId(context);
    final target = node == null
        ? null
        : GradientEditTarget(node, stackPath, paintId);
    return ValueListenableBuilder<GradientEditTarget?>(
      valueListenable: canvas.gradientEdit,
      builder: (context, editing, _) => SsIconButton(
        key: ValueKey<String>('gradient-edit:$paintId'),
        icon: SsIcons.move,
        semanticLabel: 'Edit gradient on canvas',
        tooltip: 'Edit gradient on canvas (Esc to finish)',
        selected: target != null && editing == target,
        size: 24,
        iconSize: 14,
        onPressed: target == null
            ? null
            : () => canvas.toggleGradientEdit(target),
      ),
    );
  }
}

class _StopMarker extends StatelessWidget {
  const _StopMarker({
    required this.color,
    required this.selected,
    required this.label,
    required this.onTap,
    super.key,
  });

  final Color color;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ss.colors;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      child: IgnorePointer(
        child: Container(
          width: 10,
          height: _barHeight - 4,
          decoration: BoxDecoration(
            borderRadius: SsRadius.brSm,
            border: Border.all(
              color: selected ? c.focusRing : c.surface0,
              width: selected ? 2 : 1,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(2)),
              border: Border.all(color: c.textPrimary),
            ),
            child: SsCheckerboard(
              cell: 3,
              child: ColoredBox(color: color, child: const SizedBox.expand()),
            ),
          ),
        ),
      ),
    );
  }
}

/// The selected stop's position in %: scrubbing and in-range typing move
/// it between its neighbours; typing past a neighbour re-sorts the stops.
class _StopPositionField extends ConsumerWidget {
  const _StopPositionField({
    required this.path,
    required this.index,
    required this.stops,
    required this.onMove,
    required this.onReorder,
  });

  final String path;
  final int index;
  final List<ir.ColorStop> stops;
  final ValueChanged<double> onMove;
  final ValueChanged<double> onReorder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final v = r.number;
    return FieldFrame.single(
      path: path,
      child: SsNumberField(
        key: ValueKey<String>('field:$path'),
        semanticLabel: 'Stop position',
        unit: '%',
        value: v == null ? null : _r4(v * 100),
        mixed: r.mixed,
        min: 0,
        max: 100,
        fractionDigits: 1,
        enabled: r.exists,
        onChangeStart: w.beginGesture,
        onChangeEnd: w.endGesture,
        onChanged: (x) {
          final p = x / 100;
          final lo = index > 0 ? stops[index - 1].position : 0.0;
          final hi = index < stops.length - 1 ? stops[index + 1].position : 1.0;
          if (w.inGesture || (p >= lo && p <= hi)) {
            onMove(p);
          } else {
            onReorder(p);
          }
        },
      ),
    );
  }
}

/// The angle of a linear gradient (see the convention at the top).
class _AngleField extends ConsumerWidget {
  const _AngleField({required this.path, required this.paint});

  final String path;
  final ir.GradientPaint paint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wr = watchReading(context, ref, 'width');
    final hr = watchReading(context, ref, 'height');
    final sized =
        !wr.mixed && !hr.mixed && (wr.number ?? 0) > 0 && (hr.number ?? 0) > 0;
    final bw = sized ? wr.number! : 1.0;
    final bh = sized ? hr.number! : 1.0;
    final w = InspectorScope.of(context).writer;
    final angle = gradientAngle(paint.handles, bw, bh);
    return LabelRow(
      label: 'Angle',
      child: FieldFrame(
        paths: ['$path.handles.start', '$path.handles.end'],
        child: SsNumberField(
          key: ValueKey<String>('gradient-angle:${paint.id}'),
          semanticLabel: 'Gradient angle',
          label: '∠',
          unit: '°',
          value: (angle * 10).roundToDouble() / 10,
          fractionDigits: 1,
          onChangeStart: w.beginGesture,
          onChangeEnd: w.endGesture,
          onChanged: (deg) {
            final h = handlesForAngle(paint.handles, deg, bw, bh);
            w.setMany({
              '$path.handles.start': ir.IrValue.point(h.start),
              '$path.handles.end': ir.IrValue.point(h.end),
            });
          },
        ),
      ),
    );
  }
}

/// A gradient handle as X / Y in % of the node box.
class _HandleRow extends StatelessWidget {
  const _HandleRow({required this.label, required this.path});

  final String label;
  final String path;

  @override
  Widget build(BuildContext context) => LabelRow(
    label: label,
    child: Row(
      children: [
        Expanded(
          child: PointAxisField(path: path, axis: Axis.horizontal, label: 'X'),
        ),
        const SizedBox(width: SsSpace.s2),
        Expanded(
          child: PointAxisField(path: path, axis: Axis.vertical, label: 'Y'),
        ),
      ],
    ),
  );
}

/// One coordinate of a point property, shown in % (normalised 0–1 stored).
class PointAxisField extends ConsumerWidget {
  const PointAxisField({
    required this.path,
    required this.axis,
    required this.label,
    this.min,
    this.max,
    this.semanticLabel,
    super.key,
  });

  final String path;
  final Axis axis;
  final String label;
  final String? semanticLabel;
  final double? min;
  final double? max;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = watchReading(context, ref, path);
    final w = InspectorScope.of(context).writer;
    final v = r.value;
    final p = v is ir.PointValue ? v.value : null;
    final horizontal = axis == Axis.horizontal;
    final n = p == null ? null : (horizontal ? p.x : p.y);
    return FieldFrame.single(
      path: path,
      child: SsNumberField(
        key: ValueKey<String>('field:$path.${horizontal ? 'x' : 'y'}'),
        semanticLabel: semanticLabel ?? label,
        label: label,
        unit: '%',
        value: n == null ? null : _r4(n * 100),
        mixed: r.mixed,
        min: min,
        max: max,
        fractionDigits: 1,
        enabled: r.exists && p != null,
        onChangeStart: w.beginGesture,
        onChangeEnd: w.endGesture,
        onChanged: (x) {
          // The other coordinate does not move while this one is edited.
          if (p == null) return;
          final s = _r6(x / 100);
          w.set(
            path,
            ir.IrValue.point(horizontal ? p.copyWith(x: s) : p.copyWith(y: s)),
          );
        },
      ),
    );
  }
}
