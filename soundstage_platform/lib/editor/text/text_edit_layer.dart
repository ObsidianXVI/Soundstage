import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../canvas/canvas_controller.dart';
import '../shortcuts/shortcut_map.dart';
import 'text_edit_controller.dart';
import 'text_edit_session.dart';

/// Maximum gap between the clicks of a double or triple click.
const Duration kTextMultiClickTime = Duration(milliseconds: 400);

/// The caret blink half-period.
const Duration kCaretBlink = Duration(milliseconds: 530);

/// In-place text editing on the canvas (T1.8), above the canvas tools.
///
/// - **Entering:** a text-edit request from the selection rules
///   (double-click: the word under the pointer is selected; Enter: all the
///   text), or typing a character that is not a shortcut while one text
///   node is selected (the caret goes to the end and the character is
///   typed).
/// - **Editing** happens on the real `RenderStageText` of the edited
///   artboard: it paints the selection, the blinking caret (solid while
///   typing) and the IME composing underline from a `StageTextEditing`. The
///   other artboards show the text only and update live from the document.
/// - **Pointer** inside the edited box: click places the caret, drag
///   selects, Shift-click extends, double-click selects a word (drag: by
///   words), triple-click a paragraph. Presses outside fall through to the
///   canvas tools, whose click ends edit mode.
/// - **Leaving:** Esc and Cmd+Enter keep the node selected. The session's
///   steps then squash into one undo step ("Edit text").
/// - On hover, a text node with a semantic role shows a small role label at
///   its top-left.
class TextEditLayer extends ConsumerStatefulWidget {
  const TextEditLayer({
    required this.controller,
    this.contentOnly = false,
    super.key,
  });

  final CanvasController controller;

  /// Content mode (T1.13): sessions change the words only (no style or
  /// link shortcuts), and a tap places the caret instead of selecting a
  /// word.
  final bool contentOnly;

  @override
  ConsumerState<TextEditLayer> createState() => TextEditLayerState();
}

/// The state of [TextEditLayer]; public for tests.
class TextEditLayerState extends ConsumerState<TextEditLayer> {
  final StageTextFocusNode _focus = StageTextFocusNode();
  late final EditorController _ctl = ref.read(
    editorControllerProvider.notifier,
  );
  StreamSubscription<TextEditRequest>? _requests;
  TextEditSession? _session;
  RenderStageText? _decorated;
  Timer? _blink;
  bool _caretOn = true;
  bool _restoring = false;
  FocusNode? _previousFocus;
  SsPopoverHandle? _linkPopover;
  String? _typeStart;
  final _RoleLabels _labels = _RoleLabels();

  ({Duration time, Offset global})? _lastDown;
  int _clicks = 0;
  Duration _lastClickTime = Duration.zero;
  Offset _lastClickAt = Offset.zero;
  int? _dragPointer;
  int _dragClicks = 1;
  (int, int)? _dragWord;

  /// The active session (tests).
  @visibleForTesting
  TextEditSession? get session => _session;

  CanvasController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _requests = _ctl.events.textEditRequests.listen(_onRequest);
    ref.listenManual<EditorState>(editorControllerProvider, _onState);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    HardwareKeyboard.instance.addHandler(_typeToStart);
    _focus
      ..onKeyEvent = _onKey
      ..addListener(_focusChanged);
    _c.camera.addListener(_decorate);
  }

  @override
  void dispose() {
    _end(squash: false, clearEditId: false, disposing: true);
    _requests?.cancel();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    HardwareKeyboard.instance.removeHandler(_typeToStart);
    _c.camera.removeListener(_decorate);
    _focus.dispose();
    _labels.dispose();
    super.dispose();
  }

  EditorState get _st => ref.read(editorControllerProvider);

  // ---- Starting and ending ----------------------------------------------------

  void _onGlobalPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      _lastDown = (time: e.timeStamp, global: e.position);
    }
  }

  void _onRequest(TextEditRequest req) {
    if (_restoring || !mounted) return;
    if (_session?.nodeId == req.nodeId) return;
    _end(clearEditId: false);
    final id = req.nodeId;
    if (id.contains('/')) {
      // Instance text is edited on its component (M3).
      _ctl.applySelection(_ctl.selectionState.copyWith(textEditId: null));
      return;
    }
    final bp = _artboardFor(id, req.breakpointId);
    if (bp == null) return;
    final session = TextEditSession(
      controller: _ctl,
      readState: () => ref.read(editorControllerProvider),
      nodeId: id,
      breakpointId: bp,
      view: _RenderView(this, id, bp),
      onExit: () => _end(),
      onLinkRequest: _showLinkPrompt,
      onRestoreEditMode: _onRestore,
      contentOnly: widget.contentOnly,
    );
    final typed = _typeStart;
    _typeStart = null;
    final down = _lastDown;
    if (typed != null) {
      session.selection = TextSelection.collapsed(offset: session.text.length);
    } else if (down != null) {
      final local = _nodeLocal(_toLayer(down.global), id, bp);
      final box = _box(id, bp);
      if (local != null &&
          box != null &&
          (Offset.zero & box.size).inflate(4).contains(local)) {
        if (widget.contentOnly) {
          // A tap: the caret goes where the finger is.
          session.pointerAt(box.textOffsetAt(local));
          _clicks = 1;
        } else {
          // Entered by double-click: select the word; a third click
          // selects the paragraph.
          session.selectWordAt(box.textOffsetAt(local));
          _clicks = 2;
        }
        _lastClickTime = down.time;
        _lastClickAt = _toLayer(down.global);
      }
    }
    _session = session;
    session.addListener(_onSession);
    ref.read(textEditProvider).setSession(session);
    _previousFocus = FocusManager.instance.primaryFocus;
    _focus.requestFocus();
    _restartBlink();
    setState(() {});
    if (typed != null) session.insert(typed);
    _decorate();
    WidgetsBinding.instance.addPostFrameCallback((_) => _decorate());
  }

  /// The artboard to edit [id] on: [preferred] when the node is laid out
  /// there, else the first artboard where it is.
  String? _artboardFor(String id, String? preferred) {
    if (preferred != null && _box(id, preferred) != null) return preferred;
    for (final bp in _c.artboards.keys) {
      if (_box(id, bp) != null) return bp;
    }
    return preferred ?? (_c.artboards.isEmpty ? null : _c.artboards.keys.first);
  }

  void _onRestore(bool restoring) {
    final s = _session;
    if (restoring) {
      _restoring = true;
      return;
    }
    // Undo/redo leave edit mode in the controller: put it back.
    if (s != null && s.alive && _st.textEditId != s.nodeId) {
      _ctl.applySelection(
        SelectionState(
          selection: {s.nodeId},
          context: _st.selectionContext,
          textEditId: s.nodeId,
        ),
      );
    }
    _restoring = false;
  }

  void _onState(EditorState? prev, EditorState next) {
    final s = _session;
    if (s == null || _restoring) return;
    if (next.textEditId != s.nodeId || !s.alive) {
      _end(clearEditId: false);
      return;
    }
    if (!identical(prev?.document, next.document)) {
      _decorate();
      WidgetsBinding.instance.addPostFrameCallback((_) => _decorate());
    }
  }

  /// Leaves edit mode: closes the input, removes the decoration, squashes
  /// the session's steps into one undo step and keeps the node selected.
  void _end({
    bool squash = true,
    bool clearEditId = true,
    bool disposing = false,
  }) {
    final s = _session;
    if (s == null) return;
    _session = null;
    s
      ..removeListener(_onSession)
      ..end();
    _linkPopover?.close();
    _linkPopover = null;
    _blink?.cancel();
    final box = _decorated;
    if (box != null && box.attached) box.editing = null;
    _decorated = null;
    if (disposing) {
      s.dispose();
      return;
    }
    ref.read(textEditProvider).setSession(null);
    if (squash) _ctl.squashHistoryAfter(s.historyAnchor, 'Edit text');
    if (clearEditId && _st.textEditId == s.nodeId) {
      _ctl.applySelection(_ctl.selectionState.copyWith(textEditId: null));
    }
    if (_focus.hasFocus) {
      final prev = _previousFocus;
      if (prev != null && prev.context != null && prev.canRequestFocus) {
        prev.requestFocus();
      } else {
        _focus.unfocus();
      }
    }
    _previousFocus = null;
    s.dispose();
    if (mounted) setState(() {});
  }

  /// Typing a character with one text node selected starts editing it.
  bool _typeToStart(KeyEvent e) {
    if (_session != null || !mounted || e is! KeyDownEvent) return false;
    final ch = e.character;
    if (ch == null || ch.isEmpty || ch.codeUnitAt(0) < 0x20) return false;
    if (ch.codeUnitAt(0) == 0x7F) return false;
    final k = HardwareKeyboard.instance;
    if (k.isMetaPressed || k.isControlPressed || k.isAltPressed) return false;
    if (primaryFocusIsTextInput() || primaryFocusIsStageText()) return false;
    final st = _st;
    if (st.tool != EditorTool.move || st.selection.length != 1) return false;
    final id = st.selection.single;
    if (id.contains('/')) return false;
    if (ir.DocumentIndex.of(st.document).node(id) is! ir.TextNode) return false;
    for (final a in buildShortcutMap().keys) {
      if (a.accepts(e, k)) return false;
    }
    _typeStart = ch;
    _ctl.applySelection(_ctl.selectionState.copyWith(textEditId: id));
    if (_typeStart != null) {
      // No request went out (already editing in the controller).
      _typeStart = null;
      return false;
    }
    return true;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) =>
      _session?.handleKey(e) ?? KeyEventResult.ignored;

  void _focusChanged() {
    final s = _session;
    if (s == null) return;
    if (_focus.hasFocus) {
      s.attach();
      _restartBlink();
    } else {
      s.detach();
    }
    _decorate();
  }

  // ---- Decoration ------------------------------------------------------------------

  RenderStageText? _box(String id, String bp) {
    final b = _c.artboards[bp]?.registry[id];
    if (b is! RenderStageText || !b.attached || !b.hasSize) return null;
    return b;
  }

  void _onSession() {
    _restartBlink();
    _decorate();
  }

  void _restartBlink() {
    _blink?.cancel();
    _caretOn = true;
    if (_session == null) return;
    _blink = Timer.periodic(kCaretBlink, (_) {
      _caretOn = !_caretOn;
      _decorate();
    });
  }

  void _decorate() {
    final s = _session;
    if (s == null || !mounted) return;
    final box = _box(s.nodeId, s.breakpointId);
    if (!identical(box, _decorated)) {
      final old = _decorated;
      if (old != null && old.attached) old.editing = null;
      _decorated = box;
    }
    if (box == null) return;
    final colors = context.ss.colors;
    final zoom = _c.camera.value.zoom;
    final sel = s.selection;
    final comp = s.composing;
    box.editing = StageTextEditing(
      selectionColor: colors.selection,
      caretColor: colors.accent,
      selection: (sel.start, sel.end),
      caret: sel.isCollapsed ? sel.extentOffset : null,
      caretVisible: _caretOn && _focus.hasFocus,
      caretUpstream: sel.affinity == TextAffinity.upstream,
      caretWidth: 1.5 / (zoom <= 0 ? 1 : zoom),
      composing: comp.isValid && !comp.isCollapsed
          ? (comp.start, comp.end)
          : null,
    );
    if (s.attached) {
      s.setInputGeometry(
        box.size,
        box.getTransformTo(null),
        box.caretRectAt(sel.extentOffset, width: 0),
      );
    }
  }

  // ---- Coordinates -------------------------------------------------------------------

  Offset _toLayer(Offset global) {
    final rb = context.findRenderObject();
    return rb is RenderBox && rb.attached ? rb.globalToLocal(global) : global;
  }

  /// [layer] (this layer's coordinates, the canvas viewport) in node [id]'s
  /// own coordinates on artboard [bp].
  Offset? _nodeLocal(Offset layer, String id, String bp) {
    final m = _c.overlay.screenTransformFor(id, bp);
    if (m == null) return null;
    final inv = Matrix4.tryInvert(m);
    return inv == null ? null : MatrixUtils.transformPoint(inv, layer);
  }

  bool _hitsText(Offset layer) {
    final s = _session;
    if (s == null) return false;
    final box = _box(s.nodeId, s.breakpointId);
    final local = _nodeLocal(layer, s.nodeId, s.breakpointId);
    if (box == null || local == null) return false;
    final zoom = _c.camera.value.zoom;
    return (Offset.zero & box.size)
        .inflate(4 / (zoom <= 0 ? 1 : zoom))
        .contains(local);
  }

  int? _offsetAt(Offset layer) {
    final s = _session;
    if (s == null) return null;
    final box = _box(s.nodeId, s.breakpointId);
    final local = _nodeLocal(layer, s.nodeId, s.breakpointId);
    if (box == null || local == null) return null;
    return box.textOffsetAt(local);
  }

  // ---- Pointer ------------------------------------------------------------------------

  void _onDown(PointerDownEvent e) {
    final s = _session;
    if (s == null || e.buttons & kPrimaryButton == 0) return;
    final o = _offsetAt(e.localPosition);
    if (o == null) return;
    final again =
        e.timeStamp - _lastClickTime <= kTextMultiClickTime &&
        (e.localPosition - _lastClickAt).distance <= 5;
    _clicks = again ? (_clicks % 3) + 1 : 1;
    _lastClickTime = e.timeStamp;
    _lastClickAt = e.localPosition;
    if (!_focus.hasFocus) _focus.requestFocus();
    final shift = HardwareKeyboard.instance.isShiftPressed;
    switch (_clicks) {
      case 1:
        s.pointerAt(o, extend: shift);
      case 2:
        s.selectWordAt(o);
        _dragWord = s.wordRangeAt(o);
      default:
        s.selectParagraphAt(o);
    }
    _dragPointer = e.pointer;
    _dragClicks = _clicks;
  }

  void _onMove(PointerMoveEvent e) {
    final s = _session;
    if (s == null || e.pointer != _dragPointer) return;
    final o = _offsetAt(e.localPosition);
    if (o == null) return;
    switch (_dragClicks) {
      case 1:
        s.pointerAt(o, extend: true);
      case 2:
        s.selectWordAt(o, extendFrom: _dragWord);
      default:
        final base = s.selection.start;
        s.selectParagraphAt(o);
        final p = s.selection;
        s.selection = TextSelection(
          baseOffset: base < p.start ? base : p.end,
          extentOffset: base < p.start ? p.end : p.start,
        );
    }
  }

  void _onUp(PointerEvent e) {
    if (e.pointer == _dragPointer) _dragPointer = null;
  }

  // ---- Links ----------------------------------------------------------------------------

  void _showLinkPrompt() {
    final s = _session;
    if (s == null) return;
    final box = _box(s.nodeId, s.breakpointId);
    final m = _c.overlay.screenTransformFor(s.nodeId, s.breakpointId);
    final rb = context.findRenderObject();
    if (box == null || m == null || rb is! RenderBox) return;
    final caret = MatrixUtils.transformRect(
      m,
      box.caretRectAt(s.selection.extentOffset, width: 0),
    );
    final anchor = rb.localToGlobal(caret.topLeft) & caret.size;
    final link = s.currentLink;
    final initial = link is ir.UrlLink ? link.url : '';
    _linkPopover?.close();
    late final SsPopoverHandle handle;
    handle = showSsPopover(
      context,
      anchor: anchor,
      builder: (_) => SsPopoverSurface(
        width: 280,
        padding: const EdgeInsets.all(SsSpace.s2),
        child: SsTextField(
          key: const ValueKey<String>('text-link-field'),
          initialValue: initial,
          placeholder: 'https://',
          semanticLabel: 'Link URL',
          autofocus: true,
          selectAllOnFocus: true,
          dense: true,
          onSubmitted: (url) {
            handle.close();
            if (identical(_session, s)) s.applyLink(url);
          },
        ),
      ),
      onClosed: () {
        _linkPopover = null;
        if (identical(_session, s) && !_focus.hasFocus) _focus.requestFocus();
      },
    );
    _linkPopover = handle;
  }

  // ---- Build ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final editing = _session != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        IgnorePointer(
          child: _RoleLabelLayer(
            controller: _c,
            labels: _labels,
            style: t.text.caption.copyWith(color: t.colors.textSecondary),
            background: t.colors.surface2,
          ),
        ),
        Focus(
          focusNode: _focus,
          child: editing
              ? Listener(
                  behavior: HitTestBehavior.deferToChild,
                  onPointerDown: _onDown,
                  onPointerMove: _onMove,
                  onPointerUp: _onUp,
                  onPointerCancel: _onUp,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.text,
                    hitTestBehavior: HitTestBehavior.deferToChild,
                    child: _HitRegion(contains: _hitsText),
                  ),
                )
              : const SizedBox.expand(),
        ),
      ],
    );
  }
}

/// [TextEditView] over the edited node's `RenderStageText`.
class _RenderView implements TextEditView {
  _RenderView(this._layer, this._id, this._bp);

  final TextEditLayerState _layer;
  final String _id;
  final String _bp;

  RenderStageText? get _b => _layer._box(_id, _bp);

  @override
  int? offsetAt(Offset local) => _b?.textOffsetAt(local);

  @override
  Rect? caretRect(int offset, {bool upstream = false}) =>
      _b?.caretRectAt(offset, upstream: upstream, width: 0);

  @override
  (int, int)? lineBoundary(int offset, {bool upstream = false}) =>
      _b?.lineBoundaryAt(offset, upstream: upstream);
}

/// A box that is hit only where [contains] says (the edited text).
class _HitRegion extends LeafRenderObjectWidget {
  const _HitRegion({required this.contains});

  final bool Function(Offset local) contains;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHitRegion(contains);

  @override
  void updateRenderObject(BuildContext context, _RenderHitRegion r) =>
      r.contains = contains;
}

class _RenderHitRegion extends RenderBox {
  _RenderHitRegion(this.contains);

  bool Function(Offset local) contains;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => contains(position);
}

// ---- Role labels -------------------------------------------------------------------

/// The short label of a role ("H1", "Quote"); null for none.
String? roleLabel(ir.NodeRole role) => switch (role) {
  ir.NodeRole.none => null,
  ir.NodeRole.heading1 => 'H1',
  ir.NodeRole.heading2 => 'H2',
  ir.NodeRole.heading3 => 'H3',
  ir.NodeRole.heading4 => 'H4',
  ir.NodeRole.heading5 => 'H5',
  ir.NodeRole.heading6 => 'H6',
  ir.NodeRole.paragraph => 'Paragraph',
  ir.NodeRole.quote => 'Quote',
  ir.NodeRole.caption => 'Caption',
  ir.NodeRole.figure => 'Figure',
  ir.NodeRole.decorative => 'Decorative',
};

class _RoleLabels extends ChangeNotifier {
  String? nodeId;
  String? label;

  void set(String? id, String? l) {
    if (id == nodeId && l == label) return;
    nodeId = id;
    label = l;
    notifyListeners();
  }
}

class _RoleLabelLayer extends ConsumerStatefulWidget {
  const _RoleLabelLayer({
    required this.controller,
    required this.labels,
    required this.style,
    required this.background,
  });

  final CanvasController controller;
  final _RoleLabels labels;
  final TextStyle style;
  final Color background;

  @override
  ConsumerState<_RoleLabelLayer> createState() => _RoleLabelLayerState();
}

class _RoleLabelLayerState extends ConsumerState<_RoleLabelLayer> {
  @override
  void initState() {
    super.initState();
    ref.listenManual<EditorState>(editorControllerProvider, (_, s) {
      final id = s.hoverId;
      String? label;
      if (id != null && !id.contains('/')) {
        final n = ir.DocumentIndex.of(s.document).node(id);
        if (n is ir.TextNode) label = roleLabel(n.common.role);
      }
      widget.labels.set(label == null ? null : id, label);
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.infinite,
    painter: _RoleLabelPainter(
      controller: widget.controller,
      labels: widget.labels,
      style: widget.style,
      background: widget.background,
    ),
  );
}

class _RoleLabelPainter extends CustomPainter {
  _RoleLabelPainter({
    required this.controller,
    required this.labels,
    required this.style,
    required this.background,
  }) : super(
         repaint: Listenable.merge([
           labels,
           controller.camera,
           controller.geometry,
         ]),
       );

  final CanvasController controller;
  final _RoleLabels labels;
  final TextStyle style;
  final Color background;

  @override
  void paint(Canvas canvas, Size size) {
    final id = labels.nodeId;
    final label = labels.label;
    if (id == null || label == null) return;
    final tp = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    for (final bp in controller.artboards.keys) {
      final r = controller.overlay.rectFor(id, bp);
      if (r == null) continue;
      final at = r.toScreen(Offset.zero);
      final box = Rect.fromLTWH(
        at.dx,
        at.dy - tp.height - 6,
        tp.width + 8,
        tp.height + 4,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(3)),
        Paint()..color = background.withValues(alpha: 0.85),
      );
      tp.paint(canvas, box.topLeft + const Offset(4, 2));
    }
    tp.dispose();
  }

  @override
  bool shouldRepaint(_RoleLabelPainter old) =>
      old.style != style || old.background != background;
}
