import 'dart:ui';

import 'package:soundstage_platform/ir/ir.dart' as ir;

// Turning a box the user dragged into stored properties (T1.5), through the
// inverse of the §4.3 constraint math: the artboard may show a free width,
// so the parent's actual size differs from the reference size its
// children were designed against, and the stored x/y/width/height must
// mean the same thing at the design size (m1.md "Free-width preview vs
// editing").

/// Where a node sits on the edited artboard, as laid out (read from the
/// render tree when a gesture starts).
class Placement {
  const Placement({
    required this.id,
    required this.node,
    required this.box,
    required this.parentSize,
    required this.reference,
    this.inFlow = false,
    this.hugsWidth = false,
    this.hugsHeight = false,
  });

  final String id;

  /// The node as resolved for the artboard (its layoutChild, rotation,
  /// text auto-resize).
  final ir.Node node;

  /// The node's unrotated laid-out box in its parent's space.
  final Rect box;

  /// The parent's laid-out size.
  final Size parentSize;

  /// The size the parent's children are designed against: its stored size,
  /// or the breakpoint's design size for a scene root.
  final Size reference;

  /// An in-flow child of an auto-layout frame (placed by the flow, not by
  /// its stored x/y).
  final bool inFlow;

  /// Whether the node measures its own content on that axis (a hugging
  /// auto-layout frame, auto-width/height text).
  final bool hugsWidth, hugsHeight;

  ir.LayoutChild get layoutChild => node.common.layoutChild;
  double get rotation => node.common.rotation;
}

/// [v] rounded to 1/100 px (kills floating-point noise; Figma shows two
/// decimals).
double roundGeometry(double v) {
  final r = (v * 100).roundToDouble() / 100;
  return r == 0 ? 0 : r;
}

/// The property writes that make [p] lay out at [target] (an unrotated box
/// in the parent's space, at the parent's actual size).
///
/// - [moveX]/[moveY]: write the position on that axis (skipped for in-flow
///   children, which the flow places).
/// - [sizeX]/[sizeY]: the size changed on that axis (a resize). A `hug` or
///   `fill` axis becomes `fixed` (Figma). Text switches its auto-resize mode:
///   a width change makes auto-width text wrap (`height`), a height change
///   makes it `fixed`; the other axis is then written at its current size so
///   the box doesn't jump.
///
/// Positions and sizes go through `inverseResolveAxisConstraint` with the
/// node's constraint, min/max and (for an axis that still hugs) its
/// content size.
Map<String, ir.IrValue> geometryWrites(
  Placement p,
  Rect target, {
  bool moveX = false,
  bool moveY = false,
  bool sizeX = false,
  bool sizeY = false,
}) {
  final lc = p.layoutChild;
  final node = p.node;
  final out = <String, ir.IrValue>{};
  var hugX = p.hugsWidth, hugY = p.hugsHeight;
  if (node is ir.TextNode && (sizeX || sizeY)) {
    final mode = node.autoResize;
    ir.TextAutoResize? next;
    if (sizeY &&
        mode != ir.TextAutoResize.fixed &&
        mode != ir.TextAutoResize.truncate) {
      next = ir.TextAutoResize.fixed;
    } else if (sizeX && mode == ir.TextAutoResize.widthAndHeight) {
      next = ir.TextAutoResize.height;
    }
    if (next != null) {
      out['autoResize'] = ir.IrValue.enumValue(next.name);
      // The other axis keeps its laid-out size as stored size.
      sizeX = true;
      if (next == ir.TextAutoResize.fixed) sizeY = true;
      hugX = false;
      hugY = next == ir.TextAutoResize.height;
    }
  }
  if (sizeX) {
    hugX = false;
    if (lc.horizontalSizing != ir.Sizing.fixed) {
      out['layoutChild.horizontalSizing'] = const ir.IrValue.enumValue('fixed');
    }
  }
  if (sizeY) {
    hugY = false;
    if (lc.verticalSizing != ir.Sizing.fixed) {
      out['layoutChild.verticalSizing'] = const ir.IrValue.enumValue('fixed');
    }
  }
  if (p.inFlow) {
    // The flow places the node; only its size is stored.
    if (sizeX) out['width'] = ir.IrValue.number(roundGeometry(target.width));
    if (sizeY) out['height'] = ir.IrValue.number(roundGeometry(target.height));
    return out;
  }
  final hK = ir.horizontalAxisConstraint(lc.constraints.horizontal);
  final vK = ir.verticalAxisConstraint(lc.constraints.vertical);
  if (moveX || sizeX) {
    final h = ir.inverseResolveAxisConstraint(
      constraint: hK,
      offset: target.left,
      size: target.width,
      reference: p.reference.width,
      parent: p.parentSize.width,
      min: lc.minWidth,
      max: lc.maxWidth,
      contentSize: hugX && !ir.constraintSetsSize(hK) ? target.width : null,
    );
    out['x'] = ir.IrValue.number(roundGeometry(h.position));
    if (sizeX) out['width'] = ir.IrValue.number(roundGeometry(h.size));
  }
  if (moveY || sizeY) {
    final v = ir.inverseResolveAxisConstraint(
      constraint: vK,
      offset: target.top,
      size: target.height,
      reference: p.reference.height,
      parent: p.parentSize.height,
      min: lc.minHeight,
      max: lc.maxHeight,
      contentSize: hugY && !ir.constraintSetsSize(vK) ? target.height : null,
    );
    out['y'] = ir.IrValue.number(roundGeometry(v.position));
    if (sizeY) out['height'] = ir.IrValue.number(roundGeometry(v.size));
  }
  return out;
}
