import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'easing_samples.dart';

/// Bezier control points, (x1, y1, x2, y2).
typedef ControlPoints = (double, double, double, double);

/// The y range the pad shows: the 0–1 band plus the curve's overshoot, in
/// 0.5 steps and with a margin, so a Back curve fits and a plain curve has
/// a small margin.
(double, double) plotRange(
  Iterable<double> samples, {
  ControlPoints? controls,
}) {
  var (lo, hi) = sampleRange(samples);
  if (controls != null) {
    lo = math.min(lo, math.min(controls.$2, controls.$4));
    hi = math.max(hi, math.max(controls.$2, controls.$4));
  }
  return ((lo / 0.5).floor() * 0.5 - 0.2, (hi / 0.5).ceil() * 0.5 + 0.2);
}

/// Draws an easing curve: the 0–1 band, the overshoot areas outside it
/// (tinted), the curve through [samples], and optionally the bezier's
/// control handles. The samples are the IR's `applyEasing` at evenly spaced
/// progress (see `sampleEasing`), so what is drawn is what is evaluated.
class EasingCurvePainter extends CustomPainter {
  EasingCurvePainter({
    required this.samples,
    required this.lo,
    required this.hi,
    required this.colors,
    this.controls,
    this.activeHandle,
    this.inset = 14,
    this.thin = false,
  });

  /// The curve: sample i is at progress `i / (samples.length - 1)`.
  final List<double> samples;

  /// The y range shown (value space; the plot spans lo at the bottom to hi
  /// at the top).
  final double lo, hi;
  final SsColors colors;

  /// Control points drawn as handles (null: none).
  final ControlPoints? controls;

  /// 0 or 1 while a handle is dragged.
  final int? activeHandle;
  final double inset;

  /// A thumbnail: no grid, no handles, a thin line.
  final bool thin;

  Rect plotRect(Size size) => Rect.fromLTWH(
    inset,
    inset,
    math.max(1, size.width - 2 * inset),
    math.max(1, size.height - 2 * inset),
  );

  Offset toPx(Size size, double x, double y) {
    final r = plotRect(size);
    return Offset(
      r.left + x * r.width,
      r.bottom - (y - lo) / (hi - lo) * r.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = plotRect(size);
    final yTop = toPx(size, 0, 1).dy, yBottom = toPx(size, 0, 0).dy;
    final band = Paint()..color = colors.surface2;
    canvas.drawRect(
      Rect.fromLTRB(r.left, math.min(yTop, yBottom), r.right, yBottom),
      band,
    );
    // Overshoot areas: above 1 and below 0.
    final over = Paint()..color = colors.warning.withValues(alpha: 0.12);
    if (hi > 1) {
      canvas.drawRect(Rect.fromLTRB(r.left, r.top, r.right, yTop), over);
    }
    if (lo < 0) {
      canvas.drawRect(Rect.fromLTRB(r.left, yBottom, r.right, r.bottom), over);
    }
    if (!thin) {
      final grid = Paint()
        ..color = colors.borderSubtle
        ..strokeWidth = 1;
      for (var i = 1; i < 4; i++) {
        final x = r.left + r.width * i / 4;
        canvas.drawLine(Offset(x, r.top), Offset(x, r.bottom), grid);
      }
      final edge = Paint()
        ..color = colors.borderStrong
        ..strokeWidth = 1;
      canvas.drawLine(Offset(r.left, yTop), Offset(r.right, yTop), edge);
      canvas.drawLine(Offset(r.left, yBottom), Offset(r.right, yBottom), edge);
    }
    final path = Path();
    final n = samples.length;
    for (var i = 0; i < n; i++) {
      final p = toPx(size, i / (n - 1), samples[i]);
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    if (!thin && controls != null) {
      final (x1, y1, x2, y2) = controls!;
      final stem = Paint()
        ..color = colors.textSecondary
        ..strokeWidth = 1;
      final p1 = toPx(size, x1, y1), p2 = toPx(size, x2, y2);
      canvas.drawLine(toPx(size, 0, 0), p1, stem);
      canvas.drawLine(toPx(size, 1, 1), p2, stem);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = colors.accentText
        ..style = PaintingStyle.stroke
        ..strokeWidth = thin ? 1.5 : 2
        ..strokeJoin = StrokeJoin.round,
    );
    if (!thin && controls != null) {
      final (x1, y1, x2, y2) = controls!;
      for (final (i, p) in [(0, toPx(size, x1, y1)), (1, toPx(size, x2, y2))]) {
        final active = activeHandle == i;
        canvas.drawCircle(
          p,
          active ? 7 : 6,
          Paint()..color = active ? colors.accentHover : colors.accent,
        );
        canvas.drawCircle(
          p,
          active ? 7 : 6,
          Paint()
            ..color = colors.textOnAccent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(EasingCurvePainter old) =>
      !identical(old.samples, samples) ||
      old.lo != lo ||
      old.hi != hi ||
      old.controls != controls ||
      old.activeHandle != activeHandle ||
      old.colors != colors;
}

/// The curve pad: the curve of [easing] with, when [onControls] is set,
/// two draggable handles (the nearest to the pointer follows it). Handle x
/// stays in 0–1; y may overshoot (the plot grows to show it, and never
/// shrinks while a handle is held).
class EasingCurvePad extends StatefulWidget {
  const EasingCurvePad({
    required this.easing,
    this.onControls,
    this.onDragStart,
    this.onDragEnd,
    this.height = 184,
    super.key,
  });

  final ir.Easing easing;

  /// Called with the new control points on every drag step; null: no
  /// handles.
  final ValueChanged<ControlPoints>? onControls;
  final VoidCallback? onDragStart;
  final VoidCallback? onDragEnd;
  final double height;

  @override
  State<EasingCurvePad> createState() => _EasingCurvePadState();
}

/// Lowest and highest y a handle may take.
const double kMinHandleY = -2, kMaxHandleY = 3;

class _EasingCurvePadState extends State<EasingCurvePad> {
  late List<double> _samples = sampleEasing(widget.easing);
  late (double, double) _range = _computeRange();
  int? _dragging;

  ControlPoints? get _controls =>
      widget.onControls == null ? null : controlPointsOf(widget.easing);

  (double, double) _computeRange() => plotRange(_samples, controls: _controls);

  @override
  void didUpdateWidget(EasingCurvePad old) {
    super.didUpdateWidget(old);
    if (old.easing != widget.easing) {
      _samples = sampleEasing(widget.easing);
      final next = _computeRange();
      _range = _dragging == null
          ? next
          : (math.min(_range.$1, next.$1), math.max(_range.$2, next.$2));
    }
  }

  EasingCurvePainter _painter(SsColors colors) => EasingCurvePainter(
    samples: _samples,
    lo: _range.$1,
    hi: _range.$2,
    colors: colors,
    controls: _controls,
    activeHandle: _dragging,
  );

  void _start(DragStartDetails d, Size size, SsColors colors) {
    final c = _controls;
    if (c == null) return;
    final p = _painter(colors);
    final d1 = (p.toPx(size, c.$1, c.$2) - d.localPosition).distance;
    final d2 = (p.toPx(size, c.$3, c.$4) - d.localPosition).distance;
    setState(() => _dragging = d1 <= d2 ? 0 : 1);
    widget.onDragStart?.call();
    _move(d.localPosition, size, colors);
  }

  void _move(Offset local, Size size, SsColors colors) {
    final c = _controls, i = _dragging;
    if (c == null || i == null) return;
    final p = _painter(colors);
    final r = p.plotRect(size);
    final x = ((local.dx - r.left) / r.width).clamp(0.0, 1.0);
    final y =
        (_range.$1 + (r.bottom - local.dy) / r.height * (_range.$2 - _range.$1))
            .clamp(kMinHandleY, kMaxHandleY);
    double q(double v) => (v * 100).round() / 100;
    widget.onControls!(
      i == 0 ? (q(x), q(y), c.$3, c.$4) : (c.$1, c.$2, q(x), q(y)),
    );
  }

  void _end() {
    if (_dragging == null) return;
    setState(() => _dragging = null);
    widget.onDragEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.ss.colors;
    return Semantics(
      label: 'Easing curve',
      child: LayoutBuilder(
        builder: (context, box) {
          final size = Size(box.maxWidth, widget.height);
          return MouseRegion(
            cursor: widget.onControls == null
                ? MouseCursor.defer
                : SystemMouseCursors.precise,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (d) => _start(d, size, colors),
              onPanUpdate: (d) => _move(d.localPosition, size, colors),
              onPanEnd: (_) => _end(),
              onPanCancel: _end,
              child: CustomPaint(
                key: const ValueKey<String>('easing-curve'),
                size: size,
                painter: _painter(colors),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A tiny curve for the preset grid.
class EasingThumb extends StatelessWidget {
  const EasingThumb({required this.easing, super.key});

  final ir.Easing easing;

  @override
  Widget build(BuildContext context) {
    final samples = sampleEasing(easing, 32);
    final (lo, hi) = plotRange(samples);
    return CustomPaint(
      size: const Size(34, 26),
      painter: EasingCurvePainter(
        samples: samples,
        lo: lo,
        hi: hi,
        colors: context.ss.colors,
        inset: 3,
        thin: true,
      ),
    );
  }
}
