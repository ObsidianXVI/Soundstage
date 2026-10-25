import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:soundstage_platform/editor/core/editor_state.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

// The nodes the insert tools create (T1.9): their defaults and roles. Pure
// functions, so the sizes, fills and semantics are testable without a canvas.

/// The size a click (without a drag) gives a new node.
const Size kDefaultInsertSize = Size(100, 100);

/// The default length of a line made by a click.
const double kDefaultLineLength = 100;

/// The largest share of the artboard an inserted image may take.
const double kImageFitShare = 0.8;

/// Whether [tool] inserts a node (the others select, pan or pick a file).
bool isInsertTool(EditorTool tool) => switch (tool) {
  EditorTool.frame ||
  EditorTool.text ||
  EditorTool.rectangle ||
  EditorTool.ellipse ||
  EditorTool.polygon ||
  EditorTool.star ||
  EditorTool.line => true,
  _ => false,
};

const _frameFill = ir.Paint.solid(id: 'fill', color: ir.StageColor.white);
const _shapeFill = ir.Paint.solid(
  id: 'fill',
  color: ir.StageColor(r: 0.851, g: 0.851, b: 0.851),
);
const _lineStroke = ir.Stroke(
  paints: [ir.Paint.solid(id: 'stroke', color: ir.StageColor.black)],
);

/// The node [tool] creates, at [box] (parent space), named for its kind.
///
/// - frame: white; rectangle, ellipse, polygon (a triangle) and star (five
///   points): light grey, no stroke; line: a
///   1 px black stroke, the box's height is its slope.
/// - text: an empty paragraph, role `paragraph`, hugging its text (a drawn
///   width ([drawn]) wraps it instead); the author types straight away
///   (T1.8). [inFlow]: the parent has auto layout, so the text hugs.
///
/// Returns null for tools that create nothing.
ir.Node? buildInsertNode(
  EditorTool tool,
  String id,
  Rect box, {
  bool inFlow = false,
  bool drawn = false,
}) {
  final common = ir.NodeCommon(
    id: id,
    x: box.left,
    y: box.top,
    width: box.width,
    height: box.height,
  );
  switch (tool) {
    case EditorTool.frame:
      return ir.FrameNode(
        common: common.copyWith(name: 'Frame'),
        appearance: const ir.Appearance(fills: [_frameFill]),
      );
    case EditorTool.rectangle:
      return ir.ShapeNode(
        common: common.copyWith(name: 'Rectangle'),
        appearance: const ir.Appearance(fills: [_shapeFill]),
      );
    case EditorTool.ellipse:
      return ir.ShapeNode(
        common: common.copyWith(name: 'Ellipse'),
        geometry: const ir.ShapeGeometry.ellipse(),
        appearance: const ir.Appearance(fills: [_shapeFill]),
      );
    case EditorTool.polygon:
      return ir.ShapeNode(
        common: common.copyWith(name: 'Polygon'),
        geometry: const ir.ShapeGeometry.polygon(),
        appearance: const ir.Appearance(fills: [_shapeFill]),
      );
    case EditorTool.star:
      return ir.ShapeNode(
        common: common.copyWith(name: 'Star'),
        geometry: const ir.ShapeGeometry.star(),
        appearance: const ir.Appearance(fills: [_shapeFill]),
      );
    case EditorTool.line:
      return ir.ShapeNode(
        common: common.copyWith(name: 'Line'),
        geometry: const ir.ShapeGeometry.line(),
        appearance: const ir.Appearance(strokes: _lineStroke),
      );
    case EditorTool.text:
      return ir.TextNode(
        common: common.copyWith(
          name: 'Text',
          role: ir.NodeRole.paragraph,
          layoutChild: inFlow
              ? const ir.LayoutChild(
                  horizontalSizing: ir.Sizing.hug,
                  verticalSizing: ir.Sizing.hug,
                )
              : const ir.LayoutChild(),
        ),
        content: const [
          ir.Paragraph(spans: [ir.Span(text: '')]),
        ],
        autoResize: drawn
            ? ir.TextAutoResize.height
            : ir.TextAutoResize.widthAndHeight,
      );
    case EditorTool.move || EditorTool.hand || EditorTool.image:
      return null;
  }
}

/// A frame showing [asset] as an image fill: scale mode `fill`, focal point
/// at the centre, role `figure`, alt text from the asset (empty until the
/// author writes it).
ir.FrameNode buildImageFrame(
  ir.Asset asset,
  String id,
  String paintId,
  Rect box,
) => ir.FrameNode(
  common: ir.NodeCommon(
    id: id,
    name: asset.name.isEmpty ? 'Image' : _stem(asset.name),
    x: box.left,
    y: box.top,
    width: box.width,
    height: box.height,
    role: ir.NodeRole.figure,
    altText: asset.alt,
  ),
  appearance: ir.Appearance(
    fills: [
      ir.Paint.image(
        id: paintId,
        assetId: asset.id,
        scaleMode: ir.ImageScaleMode.fill,
        focalPoint: const ir.StagePoint(x: 0.5, y: 0.5),
      ),
    ],
  ),
  clipContent: true,
);

String _stem(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// The size an image of [intrinsic] pixels gets on an artboard of [artboard]:
/// its own size, scaled down to fit within [kImageFitShare] of the
/// artboard's width and height, keeping its aspect ratio. Never scaled up.
Size fitImageSize(Size intrinsic, Size artboard) {
  if (intrinsic.width <= 0 || intrinsic.height <= 0) {
    return kDefaultInsertSize;
  }
  final scale = math.min(
    1.0,
    math.min(
      kImageFitShare * artboard.width / intrinsic.width,
      kImageFitShare * artboard.height / intrinsic.height,
    ),
  );
  return Size(
    (intrinsic.width * scale).roundToDouble().clamp(1, double.infinity),
    (intrinsic.height * scale).roundToDouble().clamp(1, double.infinity),
  );
}

/// What a drag draws: the box in parent space and, for a line, its angle.
typedef DragShape = ({Rect box, double rotation});

/// The shape a drag from [a] to [b] draws (parent space).
///
/// - [square] (Shift): a square for boxes; for a line, the angle snaps to
///   multiples of 15 degrees.
/// - [fromCenter] (Alt): [a] is the centre.
///
/// A line is a horizontal box of the line's length and no height, rotated
/// about its centre (lines are stored the way Figma does).
DragShape dragShape(
  EditorTool tool,
  Offset a,
  Offset b, {
  bool square = false,
  bool fromCenter = false,
}) {
  var d = b - a;
  if (tool == EditorTool.line) {
    final len = d.distance;
    var ang = math.atan2(d.dy, d.dx);
    if (square) {
      const step = math.pi / 12;
      ang = (ang / step).round() * step;
    }
    final v = Offset(math.cos(ang), math.sin(ang)) * len;
    final from = fromCenter ? a - v : a;
    final to = a + v;
    final c = (from + to) / 2;
    final length = fromCenter ? 2 * len : len;
    return (
      box: Rect.fromLTWH(c.dx - length / 2, c.dy, length, 0),
      rotation: ang * 180 / math.pi,
    );
  }
  if (square) {
    final m = math.max(d.dx.abs(), d.dy.abs());
    d = Offset(d.dx.isNegative ? -m : m, d.dy.isNegative ? -m : m);
  }
  final from = fromCenter ? a - d : a;
  return (box: Rect.fromPoints(from, a + d), rotation: 0);
}
