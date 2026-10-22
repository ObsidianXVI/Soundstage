import 'dart:math' as math;
import 'dart:ui' show Rect, Size;

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
    return ideal.clamp(boxLen - len, 0.0);
  }

  return Rect.fromLTWH(
    place(box.width, w, focalPoint.x),
    place(box.height, h, focalPoint.y),
    w,
    h,
  );
}
