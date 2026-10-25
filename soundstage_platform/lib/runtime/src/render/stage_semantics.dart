import 'package:flutter/rendering.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'render_stage_box.dart';
import 'stage_environment.dart';

/// Screen-reader semantics of the stage (architecture §4.2, §14).
///
/// Semantics are invisible: they come only from a node's `role`,
/// `readingOrder` and `altText`, and never add anything to the story.
///
/// - Text is exposed with its content: as a header with a heading level for
///   `heading1…6`, as plain text otherwise (paragraph, quote, caption, none).
/// - A frame's text role (heading, paragraph, quote, caption) is inherited by
///   the unroled text inside it.
/// - `figure` is an image labelled by its `altText`.
/// - `decorative`, invisible and faulted nodes (and everything under them)
///   are hidden. Fills never produce semantics: an image without `altText`
///   and without the figure role is not exposed.
/// - Order inside a scene: nodes with a `readingOrder` first, by that
///   number; then the rest top-to-bottom, then left-to-right, in the scene's
///   layout coordinates (so it follows the current breakpoint and ignores
///   paint-only motion).
///
/// Semantics are described when a node's configuration changes, never per
/// animation frame: the animator only repaints.
///
/// Nothing is exposed in [StageRenderMode.edit].

/// Order keys: explicit `readingOrder` sort before any visual position.
const double _explicitBase = -1e15;
const double _rowScale = 1e5;

/// Whether [box] (and its subtree) takes part in semantics.
bool stageExposed(RenderStageBox box) =>
    box.environment.mode != StageRenderMode.edit &&
    !box.placeholder &&
    box.common.visible &&
    box.common.role != ir.NodeRole.decorative;

/// The role in effect for [box]: its own, or for text-bearing roles the
/// nearest frame ancestor's.
ir.NodeRole effectiveStageRole(RenderStageBox box) {
  final own = box.common.role;
  if (own != ir.NodeRole.none) return own;
  RenderObject? p = box.parent;
  while (p is RenderStageBox) {
    final r = p.common.role;
    if (r != ir.NodeRole.none) {
      return r == ir.NodeRole.figure || r == ir.NodeRole.decorative
          ? ir.NodeRole.none
          : r;
    }
    p = p.parent;
  }
  return ir.NodeRole.none;
}

/// The sort key of [box] among its siblings (see the library comment).
double stageSortOrder(RenderStageBox box) {
  final explicit = box.common.readingOrder;
  if (explicit != null) return _explicitBase + explicit;
  var x = 0.0;
  var y = 0.0;
  RenderObject? o = box;
  while (o is RenderStageBox) {
    final pd = o.parentData;
    if (pd is StageParentData) {
      x += pd.offset.dx;
      y += pd.offset.dy;
    }
    o = o.parent;
  }
  return y.roundToDouble() * _rowScale + x;
}

int _headingLevel(ir.NodeRole r) => switch (r) {
  ir.NodeRole.heading1 => 1,
  ir.NodeRole.heading2 => 2,
  ir.NodeRole.heading3 => 3,
  ir.NodeRole.heading4 => 4,
  ir.NodeRole.heading5 => 5,
  ir.NodeRole.heading6 => 6,
  _ => 0,
};

/// Describes [box] into [config]. [text] is the node's text content (null
/// for non-text nodes, which are exposed only as figures).
void describeStageSemantics(
  RenderStageBox box,
  SemanticsConfiguration config,
  String? text,
) {
  if (!stageExposed(box)) return;
  final role = effectiveStageRole(box);
  final alt = box.common.altText;
  final hasText = text != null && text.isNotEmpty;
  String? label;
  if (role == ir.NodeRole.figure) {
    label = (alt != null && alt.isNotEmpty) ? alt : (hasText ? text : null);
    if (label == null) return;
    config.isImage = true;
  } else {
    if (!hasText) return;
    label = text;
    final level = _headingLevel(role);
    if (level > 0) {
      config.isHeader = true;
      config.headingLevel = level;
    }
  }
  config
    ..isSemanticBoundary = true
    ..textDirection = TextDirection.ltr
    ..label = label
    ..sortKey = OrdinalSortKey(stageSortOrder(box));
}

/// A text node's content as one string: paragraphs on their own lines.
String stageParagraphsText(List<ir.ResolvedParagraph> paragraphs) {
  final b = StringBuffer();
  for (var i = 0; i < paragraphs.length; i++) {
    if (i > 0) b.write('\n');
    for (final s in paragraphs[i].spans) {
      b.write(s.text);
    }
  }
  return b.toString();
}
