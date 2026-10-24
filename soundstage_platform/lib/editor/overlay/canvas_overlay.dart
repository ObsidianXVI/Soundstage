import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/editor_controller.dart';
import 'package:soundstage_platform/editor/core/editor_state.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../canvas/camera.dart';
import '../canvas/canvas_controller.dart';
import '../inspector/fields/field_frame.dart' show overrideColor;
import '../interaction/transform_math.dart';
import 'interaction_model.dart';
import 'overlay_geometry.dart';
import 'selection_frame.dart';

/// The overlay above the canvas (m1.md "Overlay"), painted in screen space
/// so hairlines and handles stay crisp at any zoom:
///
/// - artboard labels and outlines;
/// - hover outline, selection outlines on every artboard (mirrored), the
///   union bounds of a multi-selection, the parent (context) frame hint;
/// - resize handles (rotated with the node) and the size label under the
///   selection (W × H, "Hug"/"Fill" for hugging or filling axes);
/// - auto-layout padding and gap bands with direction arrows on a selected
///   or hovered auto-layout frame;
/// - the transient state of the canvas tools ([InteractionModel]): marquee,
///   snapping guides with distances, smart-spacing gap markers, Alt
///   measurements, the auto-layout insertion indicator and drag ghosts, the
///   drop target, and the painted rotation cursor.
///
/// It never rebuilds the canvas, nor itself on edits: it listens to the
/// editor state without rebuilding and repaints on camera, geometry,
/// selection, hover, document and interaction changes. Geometry is read at
/// paint time from the artboards' node registries ([OverlayGeometry]).
class CanvasOverlay extends ConsumerStatefulWidget {
  const CanvasOverlay({required this.controller, super.key});

  final CanvasController controller;

  @override
  ConsumerState<CanvasOverlay> createState() => _CanvasOverlayState();
}

class _CanvasOverlayState extends ConsumerState<CanvasOverlay> {
  final OverlayModel _model = OverlayModel();

  @override
  void initState() {
    super.initState();
    ref.listenManual<EditorState>(editorControllerProvider, (prev, next) {
      _model.update(
        selection: next.selection,
        hoverId: next.hoverId,
        document: next.document,
        context: next.selectionContext,
        showHandles: next.tool == EditorTool.move && next.textEditId == null,
      );
    }, fireImmediately: true);
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: OverlayPainter(
          geometry: widget.controller.overlay,
          model: _model,
          interaction: widget.controller.interaction,
          colors: OverlayColors(
            accent: t.colors.accent,
            onAccent: t.colors.textOnAccent,
            artboardOutline: t.colors.border,
            measure: t.colors.measure,
            spacing: t.colors.spacing,
            overrideMarker: overrideColor(context),
          ),
          labelStyle: t.text.caption.copyWith(color: t.colors.textSecondary),
          sizeStyle: t.text.caption.copyWith(color: t.colors.textDisabled),
          badgeStyle: t.text.caption,
          repaint: Listenable.merge([
            widget.controller.camera,
            widget.controller.geometry,
            widget.controller.interaction,
            _model,
          ]),
        ),
      ),
    );
  }
}

/// What the overlay shows from the editor state, fed without rebuilds.
class OverlayModel extends ChangeNotifier {
  Set<String> selection = const {};
  String? hoverId;
  String? context;
  bool showHandles = true;
  Object? _document;

  /// The document shown (for the per-artboard override markers).
  ir.StageDocument? get document => _document as ir.StageDocument?;

  /// Repaints when anything it shows changed (identity for collections).
  void update({
    required Set<String> selection,
    required String? hoverId,
    required Object document,
    String? context,
    bool showHandles = true,
  }) {
    if (identical(selection, this.selection) &&
        hoverId == this.hoverId &&
        identical(document, _document) &&
        context == this.context &&
        showHandles == this.showHandles) {
      return;
    }
    this.selection = selection;
    this.hoverId = hoverId;
    this.context = context;
    this.showHandles = showHandles;
    _document = document;
    notifyListeners();
  }
}

/// The overlay's colour roles (from the design system).
@immutable
class OverlayColors {
  const OverlayColors({
    required this.accent,
    required this.onAccent,
    required this.artboardOutline,
    required this.measure,
    required this.spacing,
    this.overrideMarker = const Color(0xFFB48CFF),
  });

  final Color accent, onAccent, artboardOutline, measure, spacing;

  /// Breakpoint override markers (the inspector's override tint).
  final Color overrideMarker;

  @override
  bool operator ==(Object other) =>
      other is OverlayColors &&
      other.accent == accent &&
      other.onAccent == onAccent &&
      other.artboardOutline == artboardOutline &&
      other.measure == measure &&
      other.spacing == spacing &&
      other.overrideMarker == overrideMarker;

  @override
  int get hashCode => Object.hash(
    accent,
    onAccent,
    artboardOutline,
    measure,
    spacing,
    overrideMarker,
  );
}

/// Paints the overlay (see [CanvasOverlay]).
class OverlayPainter extends CustomPainter {
  OverlayPainter({
    required this.geometry,
    required this.model,
    required this.interaction,
    required this.colors,
    required this.labelStyle,
    required this.sizeStyle,
    required this.badgeStyle,
    super.repaint,
  });

  final OverlayGeometry geometry;
  final OverlayModel model;
  final InteractionModel interaction;
  final OverlayColors colors;
  final TextStyle labelStyle;
  final TextStyle sizeStyle;

  /// Text style of the size and distance badges (colour set per badge).
  final TextStyle badgeStyle;

  /// Test counter: overlay paints.
  static int debugPaintCount = 0;

  /// Gap between an artboard and its label, in screen pixels.
  static const double labelGap = 6;

  /// Gap between the selection and its size label.
  static const double sizeLabelGap = 8;

  @override
  void paint(Canvas canvas, Size size) {
    assert(() {
      debugPaintCount++;
      return true;
    }());
    final cam = geometry.canvas.camera.value;
    final hair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..isAntiAlias = true;
    final viewport = Offset.zero & size;
    for (final a in geometry.canvas.artboards.values) {
      if (a.worldRect.isEmpty) continue;
      final r = cam.rectToScreen(a.worldRect);
      if (!r.inflate(40).overlaps(viewport)) continue;
      _artboardLabel(canvas, a, r, hair);
      final bp = a.breakpointId;

      // Context (parent) frame hint.
      final ctx = model.context;
      if (ctx != null && model.selection.isNotEmpty) {
        final o = geometry.rectFor(ctx, bp);
        if (o != null) {
          canvas.drawPath(
            o.outline,
            hair..color = colors.accent.withValues(alpha: 0.35),
          );
        }
      }

      // Auto-layout padding and gaps on hovered/selected frames.
      final alFrames = <String>{
        ?model.hoverId,
        if (model.selection.length == 1) model.selection.single,
      };
      if (interaction.gesture == CanvasGestureKind.none ||
          interaction.gesture == CanvasGestureKind.resize) {
        for (final id in alFrames) {
          _autoLayout(canvas, id, bp);
        }
      }

      final hover = model.hoverId;
      if (hover != null && !model.selection.contains(hover)) {
        final o = geometry.rectFor(hover, bp);
        if (o != null) {
          canvas.drawPath(
            o.outline,
            hair
              ..color = colors.accent
              ..strokeWidth = 1.5,
          );
          hair.strokeWidth = 1;
        }
      }
      final drop = interaction.dropTargetId;
      if (drop != null && interaction.breakpointId == bp) {
        final o = geometry.rectFor(drop, bp);
        if (o != null) {
          canvas.drawPath(
            o.outline,
            hair
              ..color = colors.accent
              ..strokeWidth = 2,
          );
          hair.strokeWidth = 1;
        }
      }
      for (final id in model.selection) {
        final o = geometry.rectFor(id, bp);
        if (o == null) continue;
        canvas.drawPath(o.outline, hair..color = colors.accent);
      }
      _overrideMarkers(canvas, a);
      if (model.selection.isNotEmpty) {
        final frame = SelectionFrame.of(geometry, model.selection, bp);
        if (frame != null) {
          if (!frame.single) {
            canvas.drawPath(
              Path()..addPolygon(frame.corners, true),
              hair..color = colors.accent,
            );
          }
          if (model.showHandles && interaction.showsHandles) {
            _handles(canvas, frame);
          }
          if (interaction.gesture != CanvasGestureKind.marquee &&
              interaction.measures.isEmpty) {
            _sizeLabel(canvas, frame, bp);
          }
        }
      }
    }
    _interaction(canvas, cam);
  }

  /// Test hook: the (node, artboard) pairs that got an override marker in
  /// the last paint.
  static final List<(String, String)> debugOverrideMarkers = [];

  /// A small diamond at the top-right corner of each selected node that
  /// has a patch on the breakpoint in effect on artboard [a] (T1.10).
  void _overrideMarkers(Canvas canvas, ArtboardInfo a) {
    if (identical(a, geometry.canvas.artboards.values.first)) {
      debugOverrideMarkers.clear();
    }
    final doc = model.document;
    final bp = a.effectiveBreakpointId;
    if (doc == null || bp.isEmpty || model.selection.isEmpty) return;
    final index = ir.DocumentIndex.of(doc);
    final fill = Paint()..color = colors.overrideMarker;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFFFFFFF);
    for (final id in model.selection) {
      final n = index.node(id);
      if (n == null || !ir.hasBreakpointPatch(n, bp)) continue;
      final o = geometry.rectFor(id, a.breakpointId);
      if (o == null) continue;
      final b = o.bounds;
      final c = Offset(b.right + 7, b.top - 7);
      const r = 4.0;
      final diamond = Path()
        ..moveTo(c.dx, c.dy - r)
        ..lineTo(c.dx + r, c.dy)
        ..lineTo(c.dx, c.dy + r)
        ..lineTo(c.dx - r, c.dy)
        ..close();
      canvas
        ..drawPath(diamond, fill)
        ..drawPath(diamond, edge);
      debugOverrideMarkers.add((id, a.breakpointId));
    }
  }

  void _artboardLabel(Canvas canvas, ArtboardInfo a, Rect r, Paint hair) {
    canvas.drawRect(_snap(r), hair..color = colors.artboardOutline);
    final w = a.worldRect.width.round();
    final h = a.worldRect.height.round();
    final label = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(text: a.name, style: labelStyle),
          TextSpan(text: '  $w × $h', style: sizeStyle),
        ],
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: r.width < 120 ? 120 : r.width);
    label.paint(canvas, Offset(r.left, r.top - labelGap - label.height));
    label.dispose();
  }

  void _handles(Canvas canvas, SelectionFrame f) {
    final fill = Paint()..color = const Color(0xFFFFFFFF);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = colors.accent;
    final angle = f.angle * math.pi / 180;
    for (final h in ResizeHandle.values) {
      if (!h.isCorner && !f.showsEdgeHandle(h)) continue;
      final c = f.pointOf(h);
      canvas
        ..save()
        ..translate(c.dx, c.dy)
        ..rotate(angle);
      final r = Rect.fromCenter(
        center: Offset.zero,
        width: kHandleSize,
        height: kHandleSize,
      );
      canvas
        ..drawRect(r, fill)
        ..drawRect(r, stroke)
        ..restore();
    }
  }

  static String _num(double v) {
    final r = (v * 100).roundToDouble() / 100;
    return r == r.roundToDouble()
        ? r.toInt().toString()
        : r.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
  }

  /// "W × H" under the selection; "Hug"/"Fill" replace the number of an
  /// axis that hugs or fills.
  void _sizeLabel(Canvas canvas, SelectionFrame f, String bp) {
    String text;
    if (f.single) {
      final box =
          geometry.canvas.artboards[bp]?.registry[model.selection.first];
      if (box == null || !box.hasSize) return;
      final lc = box.baseNode.common.layoutChild;
      final parent = box.parent;
      final inAutoLayout =
          parent is RenderStageFrame &&
          parent.frame.grid == null &&
          parent.frame.autoLayout != null;
      String axis(double v, ir.Sizing s, bool hugs) =>
          inAutoLayout && s == ir.Sizing.fill
          ? 'Fill'
          : (hugs ? 'Hug' : _num(v));
      final w = axis(box.size.width, lc.horizontalSizing, box.hugsWidth);
      final h = axis(box.size.height, lc.verticalSizing, box.hugsHeight);
      text = '$w × $h';
    } else {
      Rect? u;
      for (final id in model.selection) {
        final r = geometry.worldRectFor(id, bp);
        if (r == null) continue;
        u = u == null ? r : u.expandToInclude(r);
      }
      if (u == null) return;
      text = '${_num(u.width)} × ${_num(u.height)}';
    }
    final b = f.bounds;
    _badge(
      canvas,
      text,
      Offset(b.center.dx, b.bottom + sizeLabelGap),
      colors.accent,
      above: false,
    );
  }

  /// A rounded badge with [text], centred on [anchor] horizontally; its top
  /// at [anchor], its bottom with [above], or centred on it with
  /// [centred].
  void _badge(
    Canvas canvas,
    String text,
    Offset anchor,
    Color background, {
    bool above = false,
    bool centred = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: badgeStyle.copyWith(color: colors.onAccent),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    const padH = 4.0, padV = 1.0;
    final w = tp.width + padH * 2, h = tp.height + padV * 2;
    final top = centred
        ? anchor.dy - h / 2
        : (above ? anchor.dy - h : anchor.dy);
    final rect = Rect.fromLTWH(
      (anchor.dx - w / 2).roundToDouble(),
      top.roundToDouble(),
      w,
      h,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(2)),
      Paint()..color = background,
    );
    tp.paint(canvas, rect.topLeft + const Offset(padH, padV));
    tp.dispose();
  }

  /// Padding areas and gap bands (with direction arrows) of auto-layout
  /// frame [id].
  void _autoLayout(Canvas canvas, String id, String bp) {
    final box = geometry.canvas.artboards[bp]?.registry[id];
    if (box is! RenderStageFrame || !box.hasSize) return;
    final al = box.frame.grid == null ? box.frame.autoLayout : null;
    if (al == null) return;
    final m = geometry.screenTransformFor(id, bp);
    if (m == null) return;
    final s = box.size;
    final pad = al.padding;
    final tint = Paint()..color = colors.spacing.withValues(alpha: 0.16);
    final band = Paint()..color = colors.spacing.withValues(alpha: 0.28);
    Path quad(Rect local) => Path()
      ..addPolygon([
        MatrixUtils.transformPoint(m, local.topLeft),
        MatrixUtils.transformPoint(m, local.topRight),
        MatrixUtils.transformPoint(m, local.bottomRight),
        MatrixUtils.transformPoint(m, local.bottomLeft),
      ], true);
    for (final r in [
      Rect.fromLTWH(0, 0, s.width, pad.top),
      Rect.fromLTWH(0, s.height - pad.bottom, s.width, pad.bottom),
      Rect.fromLTWH(0, pad.top, pad.left, s.height - pad.top - pad.bottom),
      Rect.fromLTWH(
        s.width - pad.right,
        pad.top,
        pad.right,
        s.height - pad.top - pad.bottom,
      ),
    ]) {
      if (r.width > 0 && r.height > 0) canvas.drawPath(quad(r), tint);
    }
    final horizontal = al.direction == ir.LayoutDirection.horizontal;
    final kids = <Rect>[];
    box.visitChildren((k) {
      if (k is! RenderStageBox || !k.hasSize) return;
      final c = k.common;
      if (!c.visible || c.layoutChild.positioning != ir.Positioning.auto) {
        return;
      }
      kids.add((k.parentData! as BoxParentData).offset & k.size);
    });
    final content = Rect.fromLTRB(
      pad.left,
      pad.top,
      s.width - pad.right,
      s.height - pad.bottom,
    );
    final dir = horizontal ? const Offset(1, 0) : const Offset(0, 1);
    final screenDir =
        MatrixUtils.transformPoint(m, dir) -
        MatrixUtils.transformPoint(m, Offset.zero);
    for (var i = 1; i < kids.length; i++) {
      final a = kids[i - 1], b = kids[i];
      Rect gap;
      if (horizontal) {
        if (b.left < a.right) continue; // wrapped row or overlap
        gap = Rect.fromLTRB(
          a.right,
          al.wrap ? math.min(a.top, b.top) : content.top,
          b.left,
          al.wrap ? math.max(a.bottom, b.bottom) : content.bottom,
        );
      } else {
        if (b.top < a.bottom) continue;
        gap = Rect.fromLTRB(content.left, a.bottom, content.right, b.top);
      }
      if (gap.width <= 0 || gap.height <= 0) continue;
      canvas.drawPath(quad(gap), band);
      final c = MatrixUtils.transformPoint(m, gap.center);
      _arrow(canvas, c, screenDir);
    }
  }

  void _arrow(Canvas canvas, Offset c, Offset dir) {
    if (dir.distanceSquared == 0) return;
    final d = dir / dir.distance;
    final n = Offset(-d.dy, d.dx);
    const len = 4.0;
    final tip = c + d * len;
    final p = Path()
      ..moveTo(c.dx - d.dx * len, c.dy - d.dy * len)
      ..lineTo(tip.dx, tip.dy)
      ..moveTo(tip.dx - d.dx * 3 + n.dx * 3, tip.dy - d.dy * 3 + n.dy * 3)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - d.dx * 3 - n.dx * 3, tip.dy - d.dy * 3 - n.dy * 3);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = colors.spacing,
    );
  }

  void _interaction(Canvas canvas, CanvasCamera cam) {
    final i = interaction;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // Ghosts and insertion indicator.
    for (final g in i.ghosts) {
      final pts = [for (final p in g) cam.toScreen(p)];
      final path = Path()..addPolygon(pts, true);
      canvas
        ..drawPath(path, Paint()..color = colors.accent.withValues(alpha: 0.08))
        ..drawPath(path, line..color = colors.accent);
    }
    final ins = i.insertion;
    if (ins != null) {
      final a = cam.toScreen(ins.$1), b = cam.toScreen(ins.$2);
      canvas.drawLine(
        a,
        b,
        Paint()
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = colors.accent,
      );
    }
    // Smart spacing.
    for (final g in i.gaps) {
      final r = cam.rectToScreen(g.area);
      canvas.drawRect(
        r,
        Paint()..color = colors.spacing.withValues(alpha: 0.25),
      );
      final c = r.center;
      if (g.horizontal) {
        canvas.drawLine(
          Offset(r.left, c.dy),
          Offset(r.right, c.dy),
          line..color = colors.spacing,
        );
      } else {
        canvas.drawLine(
          Offset(c.dx, r.top),
          Offset(c.dx, r.bottom),
          line..color = colors.spacing,
        );
      }
      _badge(canvas, _num(g.value), c, colors.spacing, centred: true);
    }
    // Snapping guides and measurements.
    for (final g in [...i.guides, ...i.measures]) {
      final a = cam.toScreen(g.a), b = cam.toScreen(g.b);
      line.color = colors.measure;
      if (g.dashed) {
        _dashed(canvas, a, b, line);
      } else {
        canvas.drawLine(_crisp(a), _crisp(b), line);
      }
      final label = g.label;
      if (label != null && label > 0.004) {
        // A line too short for its badge gets the badge beside it.
        final d = b - a;
        var at = (a + b) / 2;
        if (d.distance < 36) {
          at += d.dx.abs() >= d.dy.abs()
              ? const Offset(0, -12)
              : const Offset(22, 0);
        }
        _badge(canvas, _num(label), at, colors.measure, centred: true);
      }
    }
    // Marquee.
    final mq = i.marquee;
    if (mq != null) {
      canvas
        ..drawRect(mq, Paint()..color = colors.accent.withValues(alpha: 0.1))
        ..drawRect(mq, line..color = colors.accent);
    }
    // Rotation cursor.
    final rc = i.rotateCursor;
    if (rc != null) _rotateCursor(canvas, rc, i.rotateCursorAngle);
  }

  static Offset _crisp(Offset p) =>
      Offset(p.dx.roundToDouble() + 0.5, p.dy.roundToDouble() + 0.5);

  void _dashed(Canvas canvas, Offset a, Offset b, Paint p) {
    final d = b - a;
    final len = d.distance;
    if (len == 0) return;
    final u = d / len;
    for (var t = 0.0; t < len; t += 6) {
      canvas.drawLine(a + u * t, a + u * math.min(t + 3, len), p);
    }
  }

  /// A curved double arrow (Figma's rotate cursor), [angle] degrees.
  void _rotateCursor(Canvas canvas, Offset at, double angle) {
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..rotate(angle * math.pi / 180);
    final arc = Path()
      ..addArc(
        Rect.fromCircle(center: const Offset(-6, 6), radius: 9),
        -math.pi / 2,
        math.pi / 2,
      );
    final heads = Path()
      ..moveTo(-9, -6)
      ..lineTo(-6, -3)
      ..lineTo(-9, 0)
      ..moveTo(0, 9)
      ..lineTo(3, 6)
      ..lineTo(6, 9);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFFFFFFFF);
    final ink = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF000000);
    canvas
      ..drawPath(arc, outline)
      ..drawPath(heads, outline)
      ..drawPath(arc, ink)
      ..drawPath(heads, ink)
      ..restore();
  }

  /// Aligns a rect to half pixels so a 1 px stroke is crisp.
  static Rect _snap(Rect r) => Rect.fromLTRB(
    r.left.roundToDouble() - 0.5,
    r.top.roundToDouble() - 0.5,
    r.right.roundToDouble() + 0.5,
    r.bottom.roundToDouble() + 0.5,
  );

  @override
  bool shouldRepaint(OverlayPainter old) =>
      !identical(old.geometry, geometry) ||
      !identical(old.model, model) ||
      !identical(old.interaction, interaction) ||
      old.colors != colors ||
      old.labelStyle != labelStyle ||
      old.sizeStyle != sizeStyle ||
      old.badgeStyle != badgeStyle;
}
