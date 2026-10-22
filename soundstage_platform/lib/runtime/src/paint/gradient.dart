import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'stage_color.dart';

/// The affine map from a gradient's unit space to the node box, in pixels
/// (architecture §5).
///
/// Handles are normalised to the node box, so the gradient scales with it:
/// `start` is the origin, `end - start` is the unit x axis and
/// `width - start` is the unit y axis. A linear gradient runs along unit x
/// from 0 to 1. Radial, angular and diamond gradients are centred on the
/// origin with unit radius, which makes them ellipses or rotated diamonds
/// when the axes differ in length.
///
/// When the `width` handle is unset (exactly the default `(0, 0)`) or lies
/// on the `start`/`end` line, the y axis is the x axis turned 90 degrees
/// clockwise in *pixel* space, so the shape is a circle (or a diamond with
/// equal diagonals) rather than stretching with the box.
class GradientBasis {
  const GradientBasis({required this.origin, required this.u, required this.v});

  final ui.Offset origin;

  /// The unit x axis in pixels (`end - start`).
  final ui.Offset u;

  /// The unit y axis in pixels.
  final ui.Offset v;

  /// The box position of unit-space point ([x], [y]).
  ui.Offset toBox(double x, double y) => ui.Offset(
    origin.dx + u.dx * x + v.dx * y,
    origin.dy + u.dy * x + v.dy * y,
  );

  /// Column-major 4x4 for `ui.Gradient`'s `matrix4`.
  Float64List get matrix => Float64List.fromList([
    u.dx, u.dy, 0, 0, //
    v.dx, v.dy, 0, 0,
    0, 0, 1, 0,
    origin.dx, origin.dy, 0, 1,
  ]);

  double get determinant => u.dx * v.dy - u.dy * v.dx;

  /// Unit-space coordinates of the box point [p], or null when the axes are
  /// degenerate.
  ui.Offset? toUnit(ui.Offset p) {
    final det = determinant;
    if (det.abs() < 1e-9) return null;
    final dx = p.dx - origin.dx, dy = p.dy - origin.dy;
    return ui.Offset(
      (dx * v.dy - dy * v.dx) / det,
      (u.dx * dy - u.dy * dx) / det,
    );
  }
}

/// The basis for [handles] on a node box of [size].
GradientBasis gradientBasis(ir.GradientHandles handles, ui.Size size) {
  ui.Offset px(ir.StagePoint p) =>
      ui.Offset(p.x * size.width, p.y * size.height);
  final s = px(handles.start);
  final e = px(handles.end);
  final u = e - s;
  final unset = handles.width.x == 0 && handles.width.y == 0;
  var v = px(handles.width) - s;
  final cross = u.dx * v.dy - u.dy * v.dx;
  if (unset || cross.abs() < 1e-9) {
    v = ui.Offset(-u.dy, u.dx);
  }
  return GradientBasis(origin: s, u: u, v: v);
}

/// Sorted, clamped stops ready for a shader (at least two).
class GradientStops {
  const GradientStops(this.colors, this.positions);
  final List<ui.Color> colors;
  final List<double> positions;
}

/// [stops] with [opacity] multiplied into every alpha, sorted by position
/// (stable) and clamped to 0–1.
GradientStops normalizedStops(List<ir.ColorStop> stops, [double opacity = 1]) {
  if (stops.isEmpty) {
    const clear = ui.Color(0x00000000);
    return const GradientStops([clear, clear], [0, 1]);
  }
  final sorted = [...stops]..sort((a, b) => a.position.compareTo(b.position));
  final colors = [for (final s in sorted) stageColor(s.color, opacity)];
  final positions = <double>[];
  var last = 0.0;
  for (final s in sorted) {
    last = math.max(last, s.position.clamp(0.0, 1.0));
    positions.add(last);
  }
  if (colors.length == 1) {
    return GradientStops([colors.first, colors.first], [0, 1]);
  }
  return GradientStops(colors, positions);
}

/// The shader for [p] on a node box of [size], or null for diamond
/// gradients, which are drawn as a mesh ([diamondMesh]).
ui.Shader? gradientShader(
  ir.GradientPaint p,
  ui.Size size, [
  double opacity = 1,
]) {
  if (p.kind == ir.GradientKind.diamond) return null;
  final basis = gradientBasis(p.handles, size);
  if (basis.determinant.abs() < 1e-9 && p.kind != ir.GradientKind.linear) {
    return null;
  }
  final stops = normalizedStops(p.stops, opacity);
  final m = basis.matrix;
  switch (p.kind) {
    case ir.GradientKind.linear:
      return ui.Gradient.linear(
        basis.origin,
        basis.origin + basis.u,
        stops.colors,
        stops.positions,
        ui.TileMode.clamp,
      );
    case ir.GradientKind.radial:
      return ui.Gradient.radial(
        ui.Offset.zero,
        1,
        stops.colors,
        stops.positions,
        ui.TileMode.clamp,
        m,
      );
    case ir.GradientKind.angular:
      // Sweeps clockwise from the direction of `end`, like Figma.
      return ui.Gradient.sweep(
        ui.Offset.zero,
        stops.colors,
        stops.positions,
        ui.TileMode.clamp,
        0,
        2 * math.pi,
        m,
      );
    case ir.GradientKind.diamond:
      return null;
  }
}

/// A triangle mesh with per-vertex colours.
class DiamondMesh {
  const DiamondMesh(this.positions, this.colors, this.indices, this.rings);

  /// x, y pairs in box pixels.
  final Float32List positions;

  /// ARGB32 per vertex.
  final Int32List colors;
  final Uint16List indices;

  /// Unit-space L1 radius of each ring (0 = the centre).
  final List<double> rings;

  int get vertexCount => positions.length ~/ 2;

  ui.Vertices toVertices() => ui.Vertices.raw(
    ui.VertexMode.triangles,
    positions,
    colors: colors,
    indices: indices,
  );
}

/// A diamond gradient as exact geometry.
///
/// Flutter has no diamond shader, and `FragmentProgram` would add a bundled
/// shader that must load on CanvasKit and wasm. A diamond gradient is the
/// colour ramp over the L1 norm `|x| + |y|` of the unit space, which is
/// *linear* inside each of the four quadrants. So concentric diamond rings
/// at every stop position, coloured with the stop colours and joined by
/// triangles, reproduce the gradient exactly (a ring-to-ring strip
/// interpolates linearly in the norm). The outermost ring is extended to
/// cover [box]; pixels past the last stop keep its colour, as with a
/// clamped gradient. Returns null when the basis is degenerate.
DiamondMesh? diamondMesh(
  ir.GradientPaint p,
  ui.Size box, [
  double opacity = 1,
]) {
  final basis = gradientBasis(p.handles, box);
  if (basis.determinant.abs() < 1e-9) return null;
  final stops = normalizedStops(p.stops, opacity);

  // The farthest unit-space L1 radius any box corner needs.
  var reach = 0.0;
  for (final c in [
    ui.Offset.zero,
    ui.Offset(box.width, 0),
    ui.Offset(0, box.height),
    ui.Offset(box.width, box.height),
  ]) {
    final q = basis.toUnit(c)!;
    reach = math.max(reach, q.dx.abs() + q.dy.abs());
  }

  final ringT = <double>[];
  final ringColor = <ui.Color>[];
  void ring(double t, ui.Color c) {
    ringT.add(t);
    ringColor.add(c);
  }

  if (stops.positions.first > 0) ring(0, stops.colors.first);
  for (var i = 0; i < stops.colors.length; i++) {
    ring(stops.positions[i], stops.colors[i]);
  }
  final outer = math.max(reach, stops.positions.last) + 1e-3;
  if (outer > stops.positions.last) ring(outer, stops.colors.last);

  final positions = Float32List(ringT.length * 8);
  final colors = Int32List(ringT.length * 4);
  for (var i = 0; i < ringT.length; i++) {
    final t = ringT[i];
    final pts = [
      basis.toBox(t, 0),
      basis.toBox(0, t),
      basis.toBox(-t, 0),
      basis.toBox(0, -t),
    ];
    for (var j = 0; j < 4; j++) {
      positions[i * 8 + j * 2] = pts[j].dx;
      positions[i * 8 + j * 2 + 1] = pts[j].dy;
      colors[i * 4 + j] = ringColor[i].toARGB32();
    }
  }
  final indices = <int>[];
  for (var i = 0; i + 1 < ringT.length; i++) {
    for (var j = 0; j < 4; j++) {
      final a = i * 4 + j, b = i * 4 + (j + 1) % 4;
      final c = (i + 1) * 4 + (j + 1) % 4, d = (i + 1) * 4 + j;
      indices.addAll([a, b, c, a, c, d]);
    }
  }
  return DiamondMesh(positions, colors, Uint16List.fromList(indices), ringT);
}
