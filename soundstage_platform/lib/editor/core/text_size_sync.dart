import 'dart:ui' show Size;

import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

// Stored size of auto-sized text (DECISIONS 25/10/26 "T1.12-1 stored size of
// auto-sized text", Figma's model): when an edit changes an auto-sized text,
// the measured size is written into its stored geometry in the same undo
// step, per primary breakpoint, into the layer that supplies that geometry.
// The runtime anchors constrained text on its stored box, so without this a
// bottom- or centre-pinned text grows away from where it was placed.

/// The natural size of resolved text node [text]: wrapped at [width] (auto
/// height), or unwrapped when [width] is null (auto width and height).
typedef TextMeasurer = Size Function(ir.ResolvedNode text, double? width);

/// A [TextMeasurer] with the runtime's own text layout and the font table
/// [fonts] returns (the canvas's environment), so measured sizes are the
/// ones the canvas and the player lay out.
TextMeasurer stageTextMeasurer(StageFontTable Function() fonts) => (rn, width) {
  final node = rn.node as ir.TextNode;
  final layout = StageTextLayout(
    paragraphs: rn.paragraphs ?? const [],
    fonts: fonts(),
    settings: StageTextSettings.of(node),
  );
  layout.layout(width: width);
  final size = layout.size;
  layout.dispose();
  return size;
};

/// Whether stored dimension [path] (`width` or `height`) of [node] is
/// derived from measurement (an auto-sized axis of an auto-sized text).
/// Such keys in breakpoint patches are not shown as overrides.
bool isMeasuredDimension(ir.Node node, String path) {
  if (node is! ir.TextNode) return false;
  return switch (node.autoResize) {
    ir.TextAutoResize.widthAndHeight => path == 'width' || path == 'height',
    ir.TextAutoResize.height => path == 'height',
    _ => false,
  };
}

/// The authored text nodes of [next] that are new or changed since [prev]
/// (scenes and the overlay; unchanged subtrees are skipped by identity, so
/// the walk follows only the edited paths).
List<ir.TextNode> changedTextNodes(
  ir.StageDocument prev,
  ir.StageDocument next,
) {
  final old = ir.DocumentIndex.of(prev);
  final out = <ir.TextNode>[];
  void walk(ir.Node n) {
    if (identical(old.node(n.common.id), n)) return;
    if (n is ir.TextNode) out.add(n);
    if (n is ir.FrameNode) n.children.forEach(walk);
  }

  for (final s in next.scenes) {
    walk(s.root);
  }
  if (next.overlay case final o?) walk(o);
  return out;
}

/// [next] with the stored size of every changed auto-sized text brought in
/// line with its measured size at each primary breakpoint.
///
/// For each primary breakpoint the size is measured on the node as that
/// breakpoint resolves it ([resolve] gives the resolved node index). A
/// dimension supplied by a breakpoint patch (the breakpoint's own or one up
/// its `inheritsFrom` chain) is written into that patch; one supplied by
/// the base is written into the base for the first primary breakpoint that
/// needs it, and into the others' own patches when they measure
/// differently. Texts placed by an auto-layout flow are skipped (the layout
/// sizes them; their stored size is unused), as are nodes inside instances.
ir.StageDocument syncTextSizes(
  ir.StageDocument prev,
  ir.StageDocument next, {
  required TextMeasurer measure,
  required Map<String, ir.ResolvedNode> Function(
    ir.StageDocument doc,
    String breakpointId,
  )
  resolve,
}) {
  final texts = [
    for (final t in changedTextNodes(prev, next))
      if (t.autoResize == ir.TextAutoResize.height ||
          t.autoResize == ir.TextAutoResize.widthAndHeight)
        t,
  ];
  if (texts.isEmpty) return next;
  final primaries = next.primaryBreakpoints.toList();
  if (primaries.isEmpty) return next;
  final index = ir.DocumentIndex.of(next);
  final resolved = {for (final b in primaries) b.id: resolve(next, b.id)};

  var doc = next;
  for (final t in texts) {
    final id = t.common.id;
    final loc = index.locate(id);
    if (loc == null) continue;
    final paths = t.autoResize == ir.TextAutoResize.widthAndHeight
        ? const ['width', 'height']
        : const ['height'];
    // path → breakpoint id → measured value.
    final measured = <String, Map<String, double>>{
      for (final p in paths) p: {},
    };
    for (final b in primaries) {
      final rn = resolved[b.id]![id];
      final node = rn?.node;
      if (rn == null || node is! ir.TextNode) continue;
      final parentId = loc.parentId;
      final parent = parentId == null ? null : resolved[b.id]![parentId]?.node;
      if (parent is ir.FrameNode &&
          parent.autoLayout != null &&
          node.common.layoutChild.positioning == ir.Positioning.auto) {
        continue;
      }
      final hugsWidth = node.autoResize == ir.TextAutoResize.widthAndHeight;
      final size = measure(rn, hugsWidth ? null : node.common.width);
      if (hugsWidth) measured['width']![b.id] = size.width;
      measured['height']![b.id] = size.height;
    }
    for (final p in paths) {
      doc = _write(doc, id, p, measured[p]!, primaries);
    }
  }
  return doc;
}

const double _eps = 0.01;

/// Writes the measured values of [path] on node [id] per breakpoint.
ir.StageDocument _write(
  ir.StageDocument doc,
  String id,
  String path,
  Map<String, double> byBreakpoint,
  List<ir.Breakpoint> primaries,
) {
  var current = doc;
  double? baseValue;
  for (final b in primaries) {
    final want = byBreakpoint[b.id];
    if (want == null) continue;
    final node = ir.DocumentIndex.of(current).node(id);
    if (node == null) return current;
    // The layer supplying [path] at [b]: the last patch along its chain
    // that sets it, else the base.
    String? supplier;
    for (final c in ir.breakpointChain(current.breakpoints, b.id).chain) {
      if (node.common.breakpointOverrides[c.id]?.containsKey(path) ?? false) {
        supplier = c.id;
      }
    }
    final stored = _valueAt(node, path, supplier);
    if ((stored - want).abs() < _eps) {
      if (supplier == null) baseValue ??= stored;
      continue;
    }
    final value = ir.IrValue.number(_round(want));
    ir.EditResult r;
    if (supplier != null) {
      r = ir.setBreakpointPatchValue(current, id, supplier, path, value);
    } else if (baseValue == null) {
      baseValue = _round(want);
      r = ir.updateNode(
        current,
        id,
        (n) => ir.PropertyRegistry.standard.trySet(n, path, value) ?? n,
      );
    } else if ((baseValue - want).abs() < _eps) {
      continue;
    } else {
      r = ir.setBreakpointPatchValue(current, id, b.id, path, value);
    }
    if (r.ok) current = r.document;
  }
  return current;
}

double _valueAt(ir.Node node, String path, String? patchId) {
  if (patchId != null) {
    final v = node.common.breakpointOverrides[patchId]![path];
    if (v is ir.NumberValue) return v.value;
  }
  return path == 'width' ? node.common.width : node.common.height;
}

/// Stored sizes keep 1/100 px (measurements carry float noise).
double _round(double v) => (v * 100).roundToDouble() / 100;

/// Whether patch key [key] on [node] for breakpoint [breakpointId] is a
/// user override (shown by override indicators): every key but measured
/// dimensions of auto-sized text (the patch's own `autoResize` counts).
bool isShownOverrideKey(ir.Node node, String breakpointId, String key) {
  if (node is! ir.TextNode || (key != 'width' && key != 'height')) return true;
  final patched = node.common.breakpointOverrides[breakpointId]?['autoResize'];
  final mode = patched is ir.EnumValue
      ? ir.TextAutoResize.values.asNameMap()[patched.value] ?? node.autoResize
      : node.autoResize;
  return !isMeasuredDimension(node.copyWith(autoResize: mode), key);
}

/// Whether [node] has a user override on [breakpointId] (see
/// [isShownOverrideKey]).
bool hasShownOverride(ir.Node node, String breakpointId) {
  final patch = node.common.breakpointOverrides[breakpointId];
  if (patch == null) return false;
  return patch.keys.any((k) => isShownOverrideKey(node, breakpointId, k));
}

/// Whether [node] has a user override on any breakpoint.
bool hasAnyShownOverride(ir.Node node) =>
    node.common.breakpointOverrides.keys.any((b) => hasShownOverride(node, b));
