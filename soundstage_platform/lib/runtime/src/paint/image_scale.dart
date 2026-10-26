import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;

import 'package:flutter/rendering.dart' show Matrix4;
import 'package:soundstage_platform/ir/ir.dart' as ir;

/// Where an image of [image] size lands inside a node box of [box] size in
/// `fill` scale mode (architecture §6), in box coordinates.
///
/// The image is scaled to cover the box. The crop is positioned so the
/// image's [focalPoint] (normalised in the image) sits as close to the box
/// centre as the bounds allow: the image never leaves a gap.
Rect imageFillRect(Size box, Size image, ir.StagePoint focalPoint) {
  if (image.isEmpty || box.isEmpty) {
    return Rect.fromLTWH(0, 0, box.width, box.height);
  }
  final scale = math.max(box.width / image.width, box.height / image.height);
  final w = image.width * scale;
  final h = image.height * scale;
  double place(double boxLen, double len, double focal) {
    final ideal = boxLen / 2 - focal.clamp(0.0, 1.0) * len;
    // `len` can come out a rounding error short of `boxLen` (scale ×
    // image length); clamp would throw on a lower bound above 0.
    return ideal.clamp(math.min(boxLen - len, 0.0), 0.0);
  }

  return Rect.fromLTWH(
    place(box.width, w, focalPoint.x),
    place(box.height, h, focalPoint.y),
    w,
    h,
  );
}

/// Where an image lands in `fit` mode: scaled to sit entirely inside the box
/// and letterboxed, with the free space split by [focalPoint]
/// (0 = against the start edge, 0.5 = centred, 1 = against the end edge).
Rect imageFitRect(Size box, Size image, ir.StagePoint focalPoint) {
  if (image.isEmpty || box.isEmpty) {
    return Rect.fromLTWH(0, 0, box.width, box.height);
  }
  final scale = math.min(box.width / image.width, box.height / image.height);
  final w = image.width * scale;
  final h = image.height * scale;
  return Rect.fromLTWH(
    (box.width - w) * focalPoint.x.clamp(0.0, 1.0),
    (box.height - h) * focalPoint.y.clamp(0.0, 1.0),
    w,
    h,
  );
}

/// The number of clockwise quarter turns for a rotation in degrees (the IR
/// stores 0, 90, 180 or 270; anything else snaps to the nearest quarter).
int quarterTurnsOf(int degrees) => ((degrees / 90).round() % 4 + 4) % 4;

/// [image] as displayed after [quarterTurns] clockwise turns.
Size rotatedImageSize(Size image, int quarterTurns) =>
    quarterTurns.isOdd ? Size(image.height, image.width) : image;

/// How an image is mapped onto a node box (architecture §6), in the
/// *rotated* image space (the image after its quarter turns).
class ImagePlacement {
  const ImagePlacement({
    required this.src,
    required this.dst,
    this.tile = false,
  });

  /// The part of the (rotated) image that is shown.
  final Rect src;

  /// Where [src] lands, in box coordinates (may extend past the box; the
  /// painter clips to the node).
  final Rect dst;

  /// Whether the image repeats. Then [dst] is one cell at the box origin.
  final bool tile;

  @override
  bool operator ==(Object other) =>
      other is ImagePlacement &&
      other.src == src &&
      other.dst == dst &&
      other.tile == tile;

  @override
  int get hashCode => Object.hash(src, dst, tile);

  @override
  String toString() => 'ImagePlacement(src: $src, dst: $dst, tile: $tile)';
}

/// Places an image on a node box for each scale mode.
///
/// [image] is the displayed (rotated) image size and may be the decoded
/// size or the original: only its aspect matters, except for `tile`, which
/// uses [intrinsic] (default [image]) times [tileScale] as the cell size.
/// `crop` maps [cropRect] (normalised, in the displayed image) exactly onto
/// the box, stretching when the aspects differ.
ImagePlacement placeImage({
  required Size box,
  required Size image,
  required ir.ImageScaleMode mode,
  ir.StagePoint focalPoint = const ir.StagePoint(x: 0.5, y: 0.5),
  ir.StageRect? cropRect,
  double tileScale = 1,
  Size? intrinsic,
}) {
  final full = Offset.zero & image;
  switch (mode) {
    case ir.ImageScaleMode.fill:
      return ImagePlacement(
        src: full,
        dst: imageFillRect(box, image, focalPoint),
      );
    case ir.ImageScaleMode.fit:
      return ImagePlacement(
        src: full,
        dst: imageFitRect(box, image, focalPoint),
      );
    case ir.ImageScaleMode.crop:
      final c = cropRect;
      if (c == null) {
        return ImagePlacement(src: full, dst: Offset.zero & box);
      }
      final left = c.x.clamp(0.0, 1.0);
      final top = c.y.clamp(0.0, 1.0);
      final right = (c.x + c.width).clamp(left, 1.0);
      final bottom = (c.y + c.height).clamp(top, 1.0);
      if (right - left <= 0 || bottom - top <= 0) {
        return ImagePlacement(src: full, dst: Offset.zero & box);
      }
      return ImagePlacement(
        src: Rect.fromLTRB(
          left * image.width,
          top * image.height,
          right * image.width,
          bottom * image.height,
        ),
        dst: Offset.zero & box,
      );
    case ir.ImageScaleMode.tile:
      final cell = intrinsic ?? image;
      final s = tileScale <= 0 ? 1.0 : tileScale;
      return ImagePlacement(
        src: full,
        dst: Rect.fromLTWH(0, 0, cell.width * s, cell.height * s),
        tile: true,
      );
  }
}

/// The matrix taking a decoded image's pixel coordinates (unrotated, of
/// [decoded] size) to box coordinates, for [placement] made on the image
/// rotated by [quarterTurns] clockwise.
Matrix4 imageTransform(
  ImagePlacement placement,
  Size decoded,
  int quarterTurns,
) {
  final rotated = rotatedImageSize(decoded, quarterTurns);
  final src = placement.src, dst = placement.dst;
  final sx = src.width == 0 ? 1.0 : dst.width / src.width;
  final sy = src.height == 0 ? 1.0 : dst.height / src.height;
  return Matrix4.identity()
    ..translateByDouble(dst.left, dst.top, 0, 1)
    ..scaleByDouble(sx, sy, 1, 1)
    ..translateByDouble(-src.left, -src.top, 0, 1)
    ..translateByDouble(rotated.width / 2, rotated.height / 2, 0, 1)
    ..rotateZ(quarterTurns * math.pi / 2)
    ..translateByDouble(-decoded.width / 2, -decoded.height / 2, 0, 1);
}
