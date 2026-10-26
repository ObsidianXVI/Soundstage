import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../agent/agent_panel.dart' show agentSessionProvider;
import '../agent/agent_session.dart';
import '../canvas/canvas_controller.dart';
import '../core/core.dart';
import 'annotate_state.dart';

/// The colour of annotations (distinct from the design and the chrome).
const Color kAnnotationColor = Color(0xFFFF4FA3);

/// A drag shorter than this (screen pixels) makes no frame, text area or
/// arrow.
const double kAnnotationMinDrag = 6;

/// Annotate mode on the canvas (product spec "Annotate mode"): draws the
/// active scene's annotations on their artboards; while annotating, a drag
/// draws the chosen mark and opens its note, a click on a mark selects it.
/// When the agent asks the author to point at the canvas, the next click
/// answers it.
class AnnotationLayer extends ConsumerStatefulWidget {
  const AnnotationLayer({required this.controller, super.key});

  final CanvasController controller;

  @override
  ConsumerState<AnnotationLayer> createState() => _AnnotationLayerState();
}

class _AnnotationLayerState extends ConsumerState<AnnotationLayer> {
  CanvasController get _c => widget.controller;
  EditorController get _editor => ref.read(editorControllerProvider.notifier);

  /// The mark being drawn: its artboard and points (artboard pixels).
  ({ArtboardInfo board, List<Offset> points})? _draft;
  Offset? _downScreen;
  int _n = 0;

  /// Stands in for the agent's request listenable when there is no agent.
  final ValueNotifier<PointRequest?> _noRequest = ValueNotifier(null);

  @override
  void dispose() {
    _noRequest.dispose();
    super.dispose();
  }

  /// The artboard under [screen], with the point in its pixels.
  (ArtboardInfo, Offset)? _hit(Offset screen) {
    final world = _c.camera.value.toWorld(screen);
    for (final a in _c.artboards.values) {
      if (a.worldRect.contains(world)) return (a, world - a.worldRect.topLeft);
    }
    return null;
  }

  Offset _toScreen(ArtboardInfo a, Offset p) =>
      _c.camera.value.toScreen(a.worldRect.topLeft + p);

  /// The annotation under [screen] (within a few pixels), topmost first.
  ir.Annotation? _markAt(Offset screen, List<ir.Annotation> marks) {
    for (final m in marks.reversed) {
      final a = _c.artboards[m.breakpointId];
      if (a == null || m.points.isEmpty) continue;
      final pts = [for (final p in m.points) _toScreen(a, Offset(p.x, p.y))];
      final box = _bounds(
        pts,
      ).inflate(m.kind == ir.AnnotationKind.comment ? 12 : 6);
      if (box.contains(screen)) return m;
    }
    return null;
  }

  void _down(PointerDownEvent e, List<ir.Annotation> marks) {
    final session = ref.read(agentSessionProvider);
    final hit = _hit(e.localPosition);
    final scene = ref.read(editorControllerProvider).activeSceneId;
    // The agent's question comes first.
    if (session?.pointRequest.value != null) {
      if (hit == null || scene == null) return;
      final (board, p) = hit;
      session!.answerPoint((
        sceneId: scene,
        breakpointId: board.breakpointId,
        x: p.dx.roundToDouble(),
        y: p.dy.roundToDouble(),
      ));
      return;
    }
    final mark = _markAt(e.localPosition, marks);
    if (mark != null) {
      ref.read(annotateProvider.notifier).select(mark.id);
      return;
    }
    if (hit == null) {
      ref.read(annotateProvider.notifier).select(null);
      return;
    }
    _downScreen = e.localPosition;
    setState(() => _draft = (board: hit.$1, points: [hit.$2]));
  }

  void _move(PointerMoveEvent e) {
    final d = _draft;
    if (d == null) return;
    final p =
        _c.camera.value.toWorld(e.localPosition) - d.board.worldRect.topLeft;
    setState(() {
      if (ref.read(annotateProvider).tool == ir.AnnotationKind.path) {
        d.points.add(p);
      } else if (d.points.length == 1) {
        d.points.add(p);
      } else {
        d.points[d.points.length - 1] = p;
      }
    });
  }

  void _up(PointerUpEvent e) {
    final d = _draft;
    final start = _downScreen;
    setState(() => _draft = null);
    _downScreen = null;
    final scene = ref.read(editorControllerProvider).activeSceneId;
    if (d == null || start == null || scene == null) return;
    final tool = ref.read(annotateProvider).tool;
    final dragged = (e.localPosition - start).distance >= kAnnotationMinDrag;
    if (tool != ir.AnnotationKind.comment && !dragged) return;
    final points = tool == ir.AnnotationKind.comment
        ? [d.points.first]
        : (tool == ir.AnnotationKind.path
              ? d.points
              : [d.points.first, d.points.last]);
    final id =
        'an${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${_n++}';
    _editor.execute(
      AddAnnotation(
        ir.Annotation(
          id: id,
          kind: tool,
          sceneId: scene,
          breakpointId: d.board.breakpointId,
          points: [
            for (final p in points)
              ir.StagePoint(x: p.dx.roundToDouble(), y: p.dy.roundToDouble()),
          ],
          targetIds: _targetsUnder(d.board, points),
        ),
      ),
    );
    ref.read(annotateProvider.notifier).select(id);
  }

  /// Layers the mark covers: those whose boxes contain its first point (the
  /// innermost last), so the agent knows what it is about.
  List<String> _targetsUnder(ArtboardInfo board, List<Offset> points) {
    final scene = board.scene;
    if (scene == null || points.isEmpty) return const [];
    final p = points.first;
    final out = <String>[];
    void visit(ir.ResolvedNode n, Offset origin) {
      final c = n.node.common;
      final box = Rect.fromLTWH(
        origin.dx + c.x,
        origin.dy + c.y,
        c.width,
        c.height,
      );
      if (!box.contains(p)) return;
      out.add(n.id);
      for (final k in n.children) {
        visit(k, box.topLeft);
      }
    }

    final root = scene.root;
    for (final k in root.children) {
      visit(k, Offset.zero);
    }
    return out.isEmpty ? const [] : [out.last];
  }

  @override
  Widget build(BuildContext context) {
    final annotate = ref.watch(annotateProvider);
    final scene = ref.watch(
      editorControllerProvider.select((s) => s.activeSceneId),
    );
    final all = ref.watch(
      editorControllerProvider.select((s) => s.document.annotations),
    );
    final marks = [
      for (final m in all)
        if (m.sceneId == scene) m,
    ];
    final session = ref.watch(agentSessionProvider);
    return ValueListenableBuilder<PointRequest?>(
      valueListenable:
          session?.pointRequest ?? ValueNotifier<PointRequest?>(null),
      builder: (context, request, _) {
        final capturing = annotate.on || request != null;
        final painter = CustomPaint(
          painter: _MarksPainter(
            controller: _c,
            marks: marks,
            draft: _draft,
            draftKind: annotate.tool,
            selectedId: annotate.selectedId,
            numbers: {for (final (i, m) in all.indexed) m.id: i + 1},
          ),
          size: Size.infinite,
        );
        final selected = annotate.on
            ? marks.where((m) => m.id == annotate.selectedId).firstOrNull
            : null;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (capturing)
              Listener(
                key: const ValueKey<String>('annotation-layer'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: (e) => _down(e, marks),
                onPointerMove: _move,
                onPointerUp: _up,
                child: MouseRegion(
                  cursor: SystemMouseCursors.precise,
                  child: painter,
                ),
              )
            else
              IgnorePointer(child: painter),
            if (annotate.on && request == null) const _ToolPicker(),
            if (!annotate.on && request == null)
              Positioned(
                top: SsSpace.s2,
                right: SsSpace.s2,
                child: SsButton(
                  key: const ValueKey<String>('toolbar-annotate'),
                  label: 'Annotate',
                  icon: SsIcons.penTool,
                  variant: SsButtonVariant.secondary,
                  onPressed: ref.read(annotateProvider.notifier).toggle,
                ),
              ),
            if (request != null)
              _PointBanner(request: request, session: session!),
            if (selected != null)
              _NoteCard(
                key: ValueKey<String>('annotation-note:${selected.id}'),
                annotation: selected,
                anchor: _anchorOf(selected),
                number: all.indexWhere((m) => m.id == selected.id) + 1,
              ),
          ],
        );
      },
    );
  }

  Offset _anchorOf(ir.Annotation m) {
    final a = _c.artboards[m.breakpointId];
    if (a == null || m.points.isEmpty) return const Offset(24, 80);
    final pts = [for (final p in m.points) _toScreen(a, Offset(p.x, p.y))];
    final b = _bounds(pts);
    return Offset(b.left, b.bottom + 8);
  }
}

Rect _bounds(List<Offset> pts) {
  var l = double.infinity, t = double.infinity;
  var r = -double.infinity, b = -double.infinity;
  for (final p in pts) {
    l = math.min(l, p.dx);
    t = math.min(t, p.dy);
    r = math.max(r, p.dx);
    b = math.max(b, p.dy);
  }
  return Rect.fromLTRB(l, t, r, b);
}

class _MarksPainter extends CustomPainter {
  _MarksPainter({
    required this.controller,
    required this.marks,
    required this.draft,
    required this.draftKind,
    required this.selectedId,
    required this.numbers,
  }) : super(
         repaint: Listenable.merge([controller.camera, controller.geometry]),
       );

  final CanvasController controller;
  final List<ir.Annotation> marks;
  final ({ArtboardInfo board, List<Offset> points})? draft;
  final ir.AnnotationKind draftKind;
  final String? selectedId;
  final Map<String, int> numbers;

  @override
  void paint(Canvas canvas, Size size) {
    final cam = controller.camera.value;
    for (final m in marks) {
      final a = controller.artboards[m.breakpointId];
      if (a == null || m.points.isEmpty) continue;
      final pts = [
        for (final p in m.points)
          cam.toScreen(a.worldRect.topLeft + Offset(p.x, p.y)),
      ];
      _mark(
        canvas,
        m.kind,
        pts,
        selected: m.id == selectedId,
        resolved: m.status == ir.AnnotationStatus.resolved,
        number: numbers[m.id],
      );
    }
    final d = draft;
    if (d != null && d.points.length > 1) {
      _mark(
        canvas,
        draftKind,
        [for (final p in d.points) cam.toScreen(d.board.worldRect.topLeft + p)],
        selected: true,
        resolved: false,
      );
    }
  }

  void _mark(
    Canvas canvas,
    ir.AnnotationKind kind,
    List<Offset> pts, {
    required bool selected,
    required bool resolved,
    int? number,
  }) {
    final color = resolved
        ? kAnnotationColor.withValues(alpha: 0.35)
        : kAnnotationColor;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = selected ? 2.5 : 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color.withValues(alpha: 0.08);
    switch (kind) {
      case ir.AnnotationKind.frame || ir.AnnotationKind.text:
        if (pts.length < 2) break;
        final r = Rect.fromPoints(pts.first, pts.last);
        canvas
          ..drawRect(r, fill)
          ..drawRect(r, stroke);
        if (kind == ir.AnnotationKind.text) {
          // Text lines.
          final line = Paint()
            ..color = color.withValues(alpha: 0.5)
            ..strokeWidth = 2;
          for (var y = r.top + 12; y < r.bottom - 6; y += 12) {
            canvas.drawLine(
              Offset(r.left + 8, y),
              Offset(r.right - 8, y),
              line,
            );
          }
        }
      case ir.AnnotationKind.arrow:
        if (pts.length < 2) break;
        final a = pts.first, b = pts.last;
        canvas.drawLine(a, b, stroke);
        final angle = (b - a).direction;
        for (final da in const [2.6, -2.6]) {
          canvas.drawLine(b, b + Offset.fromDirection(angle + da, 12), stroke);
        }
      case ir.AnnotationKind.path:
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (final p in pts.skip(1)) {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawPath(path, stroke);
      case ir.AnnotationKind.comment:
        canvas
          ..drawCircle(pts.first, 10, Paint()..color = color)
          ..drawCircle(pts.first, 10, stroke..color = const Color(0xFFFFFFFF));
    }
    if (number != null) {
      final at = kind == ir.AnnotationKind.comment
          ? pts.first - const Offset(4, 7)
          : _bounds(pts).topLeft + const Offset(-6, -18);
      final tp = TextPainter(
        text: TextSpan(
          text: '$number',
          style: const TextStyle(
            color: Color(0xFFFFFFFF),
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (kind != ir.AnnotationKind.comment) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(at.dx - 3, at.dy - 1, tp.width + 6, tp.height + 2),
            const Radius.circular(4),
          ),
          Paint()..color = color,
        );
      }
      tp.paint(canvas, at);
    }
  }

  @override
  bool shouldRepaint(_MarksPainter old) =>
      !identical(old.marks, marks) ||
      old.draft != draft ||
      old.selectedId != selectedId ||
      old.draftKind != draftKind;
}

/// The marks to draw with, while annotating.
class _ToolPicker extends ConsumerWidget {
  const _ToolPicker();

  static const _icons = {
    ir.AnnotationKind.frame: SsIcons.square,
    ir.AnnotationKind.text: SsIcons.type,
    ir.AnnotationKind.arrow: SsIcons.arrowRight,
    ir.AnnotationKind.path: SsIcons.pencil,
    ir.AnnotationKind.comment: SsIcons.stickyNote,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.ss;
    final state = ref.watch(annotateProvider);
    final n = ref.read(annotateProvider.notifier);
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        key: const ValueKey<String>('annotate-tools'),
        margin: const EdgeInsets.only(top: SsSpace.s2),
        padding: const EdgeInsets.all(SsSpace.s1),
        decoration: BoxDecoration(
          color: t.colors.surface1,
          borderRadius: BorderRadius.circular(SsRadius.md),
          border: Border.all(color: kAnnotationColor.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: SsSpace.s2),
              child: Text(
                'Annotate',
                style: t.text.small.copyWith(color: kAnnotationColor),
              ),
            ),
            for (final k in ir.AnnotationKind.values)
              SsIconButton(
                key: ValueKey<String>('annotate-tool:${k.name}'),
                icon: _icons[k]!,
                semanticLabel: annotationKindLabel(k),
                size: 28,
                selected: state.tool == k,
                onPressed: () => n.setTool(k),
              ),
            const SizedBox(width: SsSpace.s1),
            SsButton(
              label: 'Done',
              variant: SsButtonVariant.ghost,
              onPressed: n.toggle,
            ),
          ],
        ),
      ),
    );
  }
}

/// The agent's question while it waits for a click.
class _PointBanner extends StatelessWidget {
  const _PointBanner({required this.request, required this.session});

  final PointRequest request;
  final AgentSession session;

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        key: const ValueKey<String>('point-request'),
        margin: const EdgeInsets.only(top: SsSpace.s2),
        padding: const EdgeInsets.symmetric(
          horizontal: SsSpace.s3,
          vertical: SsSpace.s2,
        ),
        decoration: BoxDecoration(
          color: t.colors.surface1,
          borderRadius: BorderRadius.circular(SsRadius.md),
          border: Border.all(color: kAnnotationColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SsIcon(SsIcons.sparkles, size: 14, color: kAnnotationColor),
            const SizedBox(width: SsSpace.s2),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                '${request.question} Click the place on the canvas.',
                style: t.text.small,
              ),
            ),
            const SizedBox(width: SsSpace.s2),
            SsButton(
              label: 'Cancel',
              variant: SsButtonVariant.ghost,
              onPressed: () => session.answerPoint(null),
            ),
          ],
        ),
      ),
    );
  }
}

/// The selected annotation's note, status and removal.
class _NoteCard extends ConsumerStatefulWidget {
  const _NoteCard({
    required this.annotation,
    required this.anchor,
    required this.number,
    super.key,
  });

  final ir.Annotation annotation;
  final Offset anchor;
  final int number;

  @override
  ConsumerState<_NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends ConsumerState<_NoteCard> {
  late final TextEditingController _text = TextEditingController(
    text: widget.annotation.note,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'annotation note');

  EditorController get _editor => ref.read(editorControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _editor.beginGesture();
      } else {
        _editor.endGesture();
      }
    });
    // A new mark opens straight into its note.
    if (widget.annotation.note.isEmpty) _focus.requestFocus();
  }

  @override
  void dispose() {
    if (_focus.hasFocus) _editor.endGesture();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final a = widget.annotation;
    return Positioned(
      left: widget.anchor.dx,
      top: widget.anchor.dy,
      width: 280,
      child: Container(
        padding: const EdgeInsets.all(SsSpace.s2),
        decoration: BoxDecoration(
          color: t.colors.surface1,
          borderRadius: BorderRadius.circular(SsRadius.md),
          border: Border.all(color: kAnnotationColor),
          boxShadow: const [
            BoxShadow(color: Color(0x55000000), blurRadius: 12),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  '${widget.number}. ${annotationKindLabel(a.kind)}',
                  style: t.text.caption.copyWith(color: kAnnotationColor),
                ),
                const Spacer(),
                SsDropdown<ir.AnnotationStatus>(
                  semanticLabel: 'Annotation status',
                  width: 120,
                  value: a.status,
                  items: const [
                    SsDropdownItem(
                      value: ir.AnnotationStatus.open,
                      label: 'Open',
                    ),
                    SsDropdownItem(
                      value: ir.AnnotationStatus.inProgress,
                      label: 'In progress',
                    ),
                    SsDropdownItem(
                      value: ir.AnnotationStatus.resolved,
                      label: 'Resolved',
                    ),
                  ],
                  onChanged: (s) =>
                      _editor.execute(UpdateAnnotation(a.copyWith(status: s))),
                ),
                SsIconButton(
                  icon: SsIcons.trash2,
                  semanticLabel: 'Remove annotation',
                  size: 24,
                  onPressed: () {
                    _editor.execute(RemoveAnnotation(a.id));
                    ref.read(annotateProvider.notifier).select(null);
                  },
                ),
              ],
            ),
            TextField(
              key: ValueKey<String>('annotation-text:${a.id}'),
              controller: _text,
              focusNode: _focus,
              minLines: 2,
              maxLines: 6,
              style: t.text.small,
              decoration: InputDecoration.collapsed(
                hintText:
                    'What goes here? Font, colour, content, motion… '
                    '(the agent reads this)',
                hintStyle: t.text.small.copyWith(color: t.colors.textDisabled),
              ),
              onChanged: (v) =>
                  _editor.execute(UpdateAnnotation(a.copyWith(note: v))),
            ),
          ],
        ),
      ),
    );
  }
}
