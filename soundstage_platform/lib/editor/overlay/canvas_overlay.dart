import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/editor_controller.dart';
import 'package:soundstage_platform/editor/core/editor_state.dart';

import '../canvas/canvas_controller.dart';
import 'overlay_geometry.dart';

/// The overlay above the canvas (m1.md "Overlay"): artboard labels, the
/// hover outline and the selection outlines on every artboard (mirrored
/// selection), painted in screen space so hairlines stay one pixel at any
/// zoom.
///
/// It never rebuilds the canvas, nor itself on edits: it listens to the
/// editor state without rebuilding and repaints on camera, geometry,
/// selection, hover and document changes. Geometry is read at paint time
/// from the artboards' node registries ([OverlayGeometry]), after layout.
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
          accent: t.colors.accent,
          artboardOutline: t.colors.border,
          labelStyle: t.text.caption.copyWith(color: t.colors.textSecondary),
          sizeStyle: t.text.caption.copyWith(color: t.colors.textDisabled),
          repaint: Listenable.merge([
            widget.controller.camera,
            widget.controller.geometry,
            _model,
          ]),
        ),
      ),
    );
  }
}

/// What the overlay shows, fed by the editor state without rebuilds.
class OverlayModel extends ChangeNotifier {
  Set<String> selection = const {};
  String? hoverId;
  Object? _document;

  /// Repaints when the selection, hover or document changed (identity).
  void update({
    required Set<String> selection,
    required String? hoverId,
    required Object document,
  }) {
    if (identical(selection, this.selection) &&
        hoverId == this.hoverId &&
        identical(document, _document)) {
      return;
    }
    this.selection = selection;
    this.hoverId = hoverId;
    _document = document;
    notifyListeners();
  }
}

/// Paints the overlay. Public for tests and for T1.4/T1.5, which add
/// handles and guides on top.
class OverlayPainter extends CustomPainter {
  OverlayPainter({
    required this.geometry,
    required this.model,
    required this.accent,
    required this.artboardOutline,
    required this.labelStyle,
    required this.sizeStyle,
    super.repaint,
  });

  final OverlayGeometry geometry;
  final OverlayModel model;
  final Color accent;
  final Color artboardOutline;
  final TextStyle labelStyle;
  final TextStyle sizeStyle;

  /// Test counter: overlay paints.
  static int debugPaintCount = 0;

  /// Gap between an artboard and its label, in screen pixels.
  static const double labelGap = 6;

  @override
  void paint(Canvas canvas, Size size) {
    assert(() {
      debugPaintCount++;
      return true;
    }());
    final cam = geometry.canvas.camera.value;
    final hair = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final a in geometry.canvas.artboards.values) {
      if (a.worldRect.isEmpty) continue;
      final r = cam.rectToScreen(a.worldRect);
      if (!r.inflate(40).overlaps(Offset.zero & size)) continue;
      // Artboard outline and label (name, then size).
      canvas.drawRect(_snap(r), hair..color = artboardOutline);
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

      final hover = model.hoverId;
      if (hover != null && !model.selection.contains(hover)) {
        final o = geometry.rectFor(hover, a.breakpointId);
        if (o != null) {
          canvas.drawPath(o.outline, hair..color = accent);
        }
      }
      for (final id in model.selection) {
        final o = geometry.rectFor(id, a.breakpointId);
        if (o == null) continue;
        canvas.drawPath(o.outline, hair..color = accent);
      }
    }
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
      old.accent != accent ||
      old.artboardOutline != artboardOutline ||
      old.labelStyle != labelStyle ||
      old.sizeStyle != sizeStyle;
}
