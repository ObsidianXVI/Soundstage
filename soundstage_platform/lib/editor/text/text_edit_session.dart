import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'rich_text_model.dart';
import 'text_style_target.dart';

// One in-place text-editing session (T1.8): the caret and selection of the
// text node being edited, the platform text input (delta model), keyboard
// editing and navigation, and undo grouping. Edits are commands on the
// `EditorController`, so the edited artboard and its mirror both update from
// the document; the geometry (hit testing, caret rects, lines) comes from
// the real `RenderStageText` through a [TextEditView].

/// The text geometry of the node being edited, in its own coordinates
/// (document offsets). Implemented over `RenderStageText` by the canvas
/// layer; null results mean the node is not laid out.
abstract interface class TextEditView {
  /// The document offset nearest [local].
  int? offsetAt(Offset local);

  /// The caret rect at [offset].
  Rect? caretRect(int offset, {bool upstream = false});

  /// The visual line around [offset].
  (int, int)? lineBoundary(int offset, {bool upstream = false});
}

/// How a typed burst groups into undo steps.
enum _Burst { insert, delete }

/// A typing pause that starts a new undo step (Figma groups by word or by
/// pause).
const Duration kTypingPause = Duration(seconds: 1);

/// The in-place editing session of text node [nodeId] on the artboard of
/// [breakpointId].
///
/// - **Selection:** [selection] in document offsets (paragraphs joined by
///   one unit); [composing] is the IME composing range.
/// - **Input:** a delta-model text input connection ([attach]); typed text,
///   IME composition, autocorrect replacements (off by configuration) and
///   browser paste (plain text) arrive as deltas. Keys that edit structure
///   or move the caret are handled in [handleKey].
/// - **Undo:** typing coalesces into words or pauses ([kTypingPause]) as one
///   gesture each; [undo]/[redo] keep edit mode and restore the caret.
class TextEditSession extends ChangeNotifier
    with TextInputClient, DeltaTextInputClient {
  TextEditSession({
    required this.controller,
    required this.readState,
    required this.nodeId,
    required this.breakpointId,
    required this.view,
    TextSelection? selection,
    bool? mac,
    Duration Function()? clock,
    this.onExit,
    this.onLinkRequest,
    this.onRestoreEditMode,
  }) : _mac = mac ?? _isMac(),
       _clock = clock ?? _defaultClock,
       historyAnchor = controller.history.lastEntry {
    final len = documentLength(content);
    this.selection =
        selection ?? TextSelection(baseOffset: 0, extentOffset: len);
    _remember(readState().revision);
  }

  final EditorController controller;

  /// The current editor state (`ref.read(editorControllerProvider)`).
  final EditorState Function() readState;
  final String nodeId;
  final String breakpointId;
  final TextEditView view;
  final bool _mac;
  final Duration Function() _clock;

  /// Asked to leave edit mode (Esc, Cmd+Enter).
  final VoidCallback? onExit;

  /// Cmd+K: the shell shows the link prompt for [linkRange].
  final VoidCallback? onLinkRequest;

  /// Called around undo/redo, which leave edit mode in the controller, so
  /// the owner can put it back (true before, false after).
  final void Function(bool restoring)? onRestoreEditMode;

  static final Stopwatch _watch = Stopwatch()..start();
  static Duration _defaultClock() => _watch.elapsed;

  static bool _isMac() =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  /// The history entry before this session: what it records after it is
  /// squashed into one step when it ends.
  final HistoryEntry? historyAnchor;

  // ---- Content ---------------------------------------------------------------

  /// The node's content (authored base; content is not per breakpoint).
  List<ir.Paragraph> get content {
    final n = ir.DocumentIndex.of(readState().document).node(nodeId);
    return n is ir.TextNode ? n.content : const [];
  }

  List<ir.Paragraph>? _textOf;
  String _text = '';

  /// The plain text (paragraphs joined by `\n`).
  String get text {
    final c = content;
    if (!identical(c, _textOf)) {
      _textOf = c;
      _text = plainTextOf(c);
    }
    return _text;
  }

  /// Whether the node still exists as a text node.
  bool get alive =>
      ir.DocumentIndex.of(readState().document).node(nodeId) is ir.TextNode;

  // ---- Selection ---------------------------------------------------------------

  TextSelection _selection = const TextSelection.collapsed(offset: 0);
  TextRange _composing = TextRange.empty;
  double? _goalX;

  TextSelection get selection => _selection;
  set selection(TextSelection s) {
    final len = text.length;
    final next = s.copyWith(
      baseOffset: s.baseOffset.clamp(0, len),
      extentOffset: s.extentOffset.clamp(0, len),
    );
    if (next == _selection) return;
    _selection = next;
    if (_pendingAt != next.extentOffset || !next.isCollapsed) _pending = {};
    notifyListeners();
  }

  TextRange get composing => _composing;

  /// The style target for the inspector (selection range plus the pending
  /// typing style).
  TextRangeTarget get target => TextRangeTarget(
    nodeId: nodeId,
    start: _selection.start,
    end: _selection.end,
    pending: _pending,
  );

  Map<String, ir.IrValue> _pending = const {};
  int? _pendingAt;

  /// Span-relative style writes the next typed text gets (Cmd+B with a
  /// collapsed caret, or the inspector).
  Map<String, ir.IrValue> get pendingStyle => _pending;

  /// Merges [writes] into the pending typing style at the caret.
  void addPendingStyle(Map<String, ir.IrValue> writes) {
    _pending = {..._pending, ...writes};
    _pendingAt = _selection.extentOffset;
    notifyListeners();
  }

  void _select(TextSelection s, {bool keepGoal = false}) {
    if (!keepGoal) _goalX = null;
    _endBurst();
    selection = s;
    _syncPlatform();
  }

  // ---- Undo grouping -----------------------------------------------------------

  _Burst? _burst;
  Duration _lastInput = Duration.zero;
  bool _inGesture = false;
  final Map<int, TextSelection> _selectionAt = {};

  void _remember(int revision) => _selectionAt[revision] = _selection;

  void _beginBurst(_Burst kind) {
    final now = _clock();
    final continues =
        _inGesture && _burst == kind && now - _lastInput < kTypingPause;
    _lastInput = now;
    if (continues) return;
    _endBurst();
    _burst = kind;
    _inGesture = true;
    controller.beginGesture();
  }

  void _endBurst() {
    if (!_inGesture) return;
    _inGesture = false;
    _burst = null;
    controller.endGesture();
  }

  // ---- Editing -----------------------------------------------------------------

  /// Replaces [start, end) with [inserted] and puts the caret after it.
  /// Returns whether the document changed.
  bool replace(
    int start,
    int end,
    String inserted, {
    TextSelection? selectionAfter,
    bool burst = true,
  }) {
    if (!alive) return false;
    final before = text;
    final a = math.min(start, end).clamp(0, before.length);
    final b = math.max(start, end).clamp(0, before.length);
    if (a == b && inserted.isEmpty) return false;
    final kind = inserted.isEmpty ? _Burst.delete : _Burst.insert;
    if (burst) {
      _beginBurst(kind);
    } else {
      _endBurst();
    }
    final pending = _pendingAt == a && a == b
        ? _pending
        : const <String, ir.IrValue>{};
    _remember(readState().revision);
    final r = controller.execute(
      ReplaceText(
        nodeId,
        a,
        b,
        inserted,
        styleWrites: pending,
        coalesceKey: burst ? 'text:$nodeId:${kind.name}' : null,
      ),
    );
    if (!r.ok) return false;
    _pending = const {};
    _goalX = null;
    _selection =
        selectionAfter ?? TextSelection.collapsed(offset: a + inserted.length);
    _remember(readState().revision);
    if (!burst ||
        (kind == _Burst.insert && endsWord(before.substring(0, a), inserted)) ||
        inserted.contains('\n')) {
      _endBurst();
    }
    if (!_fromPlatform) _syncPlatform();
    notifyListeners();
    return r.changed;
  }

  /// Types [inserted] over the selection.
  void insert(String inserted) =>
      replace(_selection.start, _selection.end, inserted);

  /// Runs a style command over the selection (keeps edit mode; one step).
  CommandResult runStyle(EditCommand command) {
    _endBurst();
    _remember(readState().revision);
    final r = controller.execute(command);
    _remember(readState().revision);
    notifyListeners();
    return r;
  }

  /// The resolved node at the edited breakpoint (effective styles).
  ir.ResolvedNode? get resolvedNode =>
      controller.resolvedFor(_effectiveBreakpoint).resolved.nodeIndex[nodeId];

  String get _effectiveBreakpoint => readState().breakpointId ?? breakpointId;

  /// Cmd+B / I / U: toggles [t] over the selection, or for the next typed
  /// text at a collapsed caret.
  void toggle(TextToggle t) {
    final rn = resolvedNode;
    if (rn == null) return;
    final c = content;
    final refs = spanRefsFor(c, _selection.start, _selection.end);
    var styles = [for (final s in resolvedSpansAt(rn, refs)) s.style];
    if (_selection.isCollapsed && _pending.isNotEmpty) {
      styles = [
        for (final s in styles)
          applyStyleWrites(s, _pending, inherited: rn.textStyle),
      ];
    }
    final writes = toggleWrites(t, styles, rn.textStyle);
    final emptyParagraph =
        _selection.isCollapsed &&
        paragraphLength(c[pointOf(c, _selection.start).paragraph]) == 0;
    if (_selection.isCollapsed && !emptyParagraph) {
      addPendingStyle(writes);
      return;
    }
    runStyle(
      StyleTextRange(
        nodeId,
        _selection.start,
        _selection.end,
        writes,
        effective: (p, s) => resolvedSpanStyle(rn, p, s),
        customLabel: switch (t) {
          TextToggle.bold => 'Bold',
          TextToggle.italic => 'Italic',
          TextToggle.underline => 'Underline',
        },
      ),
    );
  }

  /// The range a link edit applies to: the selection, or the link span
  /// around a collapsed caret (null when there is none).
  (int, int)? get linkRange {
    if (!_selection.isCollapsed) return (_selection.start, _selection.end);
    final c = content;
    final at = locate(c, _selection.start, before: false);
    if (at == null) return null;
    final span = c[at.paragraph].spans[at.span];
    if (span.link == null) return null;
    var start = paragraphStart(c, at.paragraph);
    for (var i = 0; i < at.span; i++) {
      start += c[at.paragraph].spans[i].text.length;
    }
    return (start, start + span.text.length);
  }

  /// The link at the selection start, if any.
  ir.SpanLink? get currentLink {
    final c = content;
    final at = locate(c, _selection.start, before: false);
    if (at == null) return null;
    return c[at.paragraph].spans[at.span].link;
  }

  /// Applies the link prompt's result: [url] null or empty removes the link;
  /// with a collapsed caret outside a link, the URL is inserted as linked
  /// text.
  void applyLink(String? url) {
    final link = url == null || url.trim().isEmpty
        ? null
        : ir.SpanLink.url(url.trim());
    final range = linkRange;
    if (range == null) {
      if (link == null) return;
      final at = _selection.start;
      final t = url!.trim();
      _remember(readState().revision);
      controller.execute(
        CommandBatch([
          ReplaceText(nodeId, at, at, t),
          SetTextLink(nodeId, at, at + t.length, link),
        ], label: 'Add link'),
      );
      _selection = TextSelection.collapsed(offset: at + t.length);
      _remember(readState().revision);
      notifyListeners();
      _syncPlatform();
      return;
    }
    runStyle(SetTextLink(nodeId, range.$1, range.$2, link));
  }

  /// Sets the node's semantic role (Cmd+Alt+1…6, 0). Roles are not per
  /// breakpoint.
  void setRole(ir.NodeRole role) {
    _endBurst();
    _remember(readState().revision);
    controller.execute(_SharedSetProperty(nodeId, 'role', role.name));
    _remember(readState().revision);
    notifyListeners();
  }

  // ---- Undo ------------------------------------------------------------------------

  /// Undoes the last step and stays in edit mode with the caret where it
  /// was. Returns false when the node no longer exists (edit mode ends).
  bool undo() => _history(controller.undo);

  bool redo() => _history(controller.redo);

  bool _history(bool Function() step) {
    _endBurst();
    onRestoreEditMode?.call(true);
    try {
      if (!step()) return true;
    } finally {
      onRestoreEditMode?.call(false);
    }
    if (!alive) return false;
    final s = _selectionAt[readState().revision];
    _composing = TextRange.empty;
    selection = s ?? _selection;
    _syncPlatform(force: true);
    notifyListeners();
    return true;
  }

  // ---- Keyboard ---------------------------------------------------------------------

  bool get _composingActive => _composing.isValid && !_composing.isCollapsed;

  /// Handles a key in edit mode. Text-producing keys are left to the text
  /// input (`skipRemainingHandlers`: the browser still types them, but no
  /// editor shortcut fires); unhandled modified keys go on to the editor's
  /// shortcuts (save, zoom).
  KeyEventResult handleKey(KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    final shift = k.isShiftPressed;
    final alt = k.isAltPressed;
    final meta = k.isMetaPressed;
    final ctrl = k.isControlPressed;
    final mod = _mac ? meta : ctrl;
    final word = _mac ? alt : ctrl;
    final key = e.logicalKey;

    // The IME owns keys while composing.
    if (_composingActive && !mod) return KeyEventResult.skipRemainingHandlers;

    if (key == LogicalKeyboardKey.escape) {
      onExit?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (mod) {
        onExit?.call();
        return KeyEventResult.handled;
      }
      // Shift+Enter: a line break inside the paragraph.
      insert(shift ? ' ' : '\n');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab && !mod && !alt) {
      insert('\t');
      return KeyEventResult.handled;
    }

    // Role shortcuts: Cmd+Alt+1…6 (H1–H6), Cmd+Alt+0 (paragraph).
    if (mod && alt && !shift) {
      final role = _roleForDigit(e.physicalKey);
      if (role != null) {
        setRole(role);
        return KeyEventResult.handled;
      }
    }

    if (mod && !alt) {
      switch (key) {
        case LogicalKeyboardKey.keyA when !shift:
          _select(TextSelection(baseOffset: 0, extentOffset: text.length));
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyB when !shift:
          toggle(TextToggle.bold);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyI when !shift:
          toggle(TextToggle.italic);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyU when !shift:
          toggle(TextToggle.underline);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyK when !shift:
          onLinkRequest?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyZ:
          if (!(shift ? redo() : undo())) onExit?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyY when !_mac:
          if (!redo()) onExit?.call();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyC ||
            LogicalKeyboardKey.keyX ||
            LogicalKeyboardKey.keyV:
          if (kIsWeb) {
            // The browser copies, cuts and pastes plain text natively on
            // the synced input element; pastes come back as deltas.
            return KeyEventResult.skipRemainingHandlers;
          }
          unawaited(_clipboard(key));
          return KeyEventResult.handled;
      }
    }

    final arrows = _arrow(key, shift: shift, word: word, mod: mod, alt: alt);
    if (arrows != null) return arrows;

    if (key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.delete) {
      _delete(
        forward: key == LogicalKeyboardKey.delete,
        word: word,
        line: _mac && meta,
      );
      return KeyEventResult.handled;
    }

    // Anything else without Cmd/Ctrl types (or is a dead key): the text
    // input handles it; keep it from the editor's tool shortcuts.
    if (!mod) return KeyEventResult.skipRemainingHandlers;
    return KeyEventResult.ignored;
  }

  static ir.NodeRole? _roleForDigit(PhysicalKeyboardKey k) {
    if (k == PhysicalKeyboardKey.digit0) return ir.NodeRole.paragraph;
    if (k == PhysicalKeyboardKey.digit1) return ir.NodeRole.heading1;
    if (k == PhysicalKeyboardKey.digit2) return ir.NodeRole.heading2;
    if (k == PhysicalKeyboardKey.digit3) return ir.NodeRole.heading3;
    if (k == PhysicalKeyboardKey.digit4) return ir.NodeRole.heading4;
    if (k == PhysicalKeyboardKey.digit5) return ir.NodeRole.heading5;
    if (k == PhysicalKeyboardKey.digit6) return ir.NodeRole.heading6;
    return null;
  }

  KeyEventResult? _arrow(
    LogicalKeyboardKey key, {
    required bool shift,
    required bool word,
    required bool mod,
    required bool alt,
  }) {
    final t = text;
    final sel = _selection;
    final ext = sel.extentOffset;
    TextSelection to(
      int offset, {
      TextAffinity affinity = TextAffinity.downstream,
    }) => shift
        ? sel.copyWith(extentOffset: offset, affinity: affinity)
        : TextSelection.collapsed(offset: offset, affinity: affinity);

    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      final fwd = key == LogicalKeyboardKey.arrowRight;
      if (_mac && mod) {
        _lineEdge(fwd, shift);
        return KeyEventResult.handled;
      }
      if (!shift && !sel.isCollapsed && !word) {
        _select(TextSelection.collapsed(offset: fwd ? sel.end : sel.start));
        return KeyEventResult.handled;
      }
      final int next;
      if (word) {
        next = fwd ? nextWordBoundary(t, ext) : previousWordBoundary(t, ext);
      } else {
        next = fwd ? nextCharBoundary(t, ext) : previousCharBoundary(t, ext);
      }
      _select(to(next));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final down = key == LogicalKeyboardKey.arrowDown;
      if (mod || (alt && _mac)) {
        // Document (Cmd) or paragraph (Option) start/end.
        if (mod) {
          _select(to(down ? t.length : 0));
        } else {
          final c = content;
          final p = pointOf(c, ext).paragraph;
          final ps = paragraphStart(c, p);
          final pe = ps + paragraphLength(c[p]);
          final int target;
          if (down) {
            target = ext < pe || p + 1 >= c.length
                ? pe
                : paragraphStart(c, p + 1) + paragraphLength(c[p + 1]);
          } else {
            target = ext > ps || p == 0 ? ps : paragraphStart(c, p - 1);
          }
          _select(to(target));
        }
        return KeyEventResult.handled;
      }
      _vertical(down, shift);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end) {
      final fwd = key == LogicalKeyboardKey.end;
      if (mod) {
        _select(to(fwd ? t.length : 0));
      } else {
        _lineEdge(fwd, shift);
      }
      return KeyEventResult.handled;
    }
    return null;
  }

  void _lineEdge(bool end, bool shift) {
    final sel = _selection;
    final b = view.lineBoundary(
      sel.extentOffset,
      upstream: sel.affinity == TextAffinity.upstream,
    );
    final c = content;
    final pt = pointOf(c, sel.extentOffset);
    final ps = paragraphStart(c, pt.paragraph);
    final (a, z) = b ?? (ps, ps + paragraphLength(c[pt.paragraph]));
    final target = end ? z : a;
    // At a soft wrap the line end is the next line's start: draw the caret
    // at the end of this line.
    final pe = ps + paragraphLength(c[pt.paragraph]);
    final affinity = end && target < pe
        ? TextAffinity.upstream
        : TextAffinity.downstream;
    _select(
      shift
          ? sel.copyWith(extentOffset: target, affinity: affinity)
          : TextSelection.collapsed(offset: target, affinity: affinity),
    );
  }

  void _vertical(bool down, bool shift) {
    final sel = _selection;
    final t = text;
    final caret = view.caretRect(
      sel.extentOffset,
      upstream: sel.affinity == TextAffinity.upstream,
    );
    int target;
    if (caret == null) {
      target = down ? t.length : 0;
    } else {
      final x = _goalX ?? caret.center.dx;
      final first = view.caretRect(0);
      final last = view.caretRect(t.length);
      if (!down && first != null && caret.top <= first.top + 0.5) {
        target = 0;
      } else if (down && last != null && caret.top >= last.top - 0.5) {
        target = t.length;
      } else {
        final y = down ? caret.bottom + 0.5 : caret.top - 0.5;
        target = view.offsetAt(Offset(x, y)) ?? (down ? t.length : 0);
      }
      _goalX = x;
    }
    final goal = _goalX;
    _select(
      shift
          ? sel.copyWith(extentOffset: target)
          : TextSelection.collapsed(offset: target),
      keepGoal: true,
    );
    _goalX = goal;
  }

  void _delete({
    required bool forward,
    required bool word,
    required bool line,
  }) {
    final sel = _selection;
    if (!sel.isCollapsed) {
      replace(sel.start, sel.end, '');
      return;
    }
    final t = text;
    final at = sel.extentOffset;
    int other;
    if (line) {
      final b = view.lineBoundary(
        at,
        upstream: sel.affinity == TextAffinity.upstream,
      );
      other = forward ? (b?.$2 ?? t.length) : (b?.$1 ?? 0);
      if (other == at) {
        other = forward ? nextCharBoundary(t, at) : previousCharBoundary(t, at);
      }
    } else if (word) {
      other = forward ? nextWordBoundary(t, at) : previousWordBoundary(t, at);
    } else {
      other = forward ? nextCharBoundary(t, at) : previousCharBoundary(t, at);
    }
    if (other == at) return;
    replace(math.min(at, other), math.max(at, other), '');
  }

  Future<void> _clipboard(LogicalKeyboardKey key) async {
    final sel = _selection;
    final t = text;
    if (key == LogicalKeyboardKey.keyV) {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final pasted = data?.text;
      if (pasted == null || pasted.isEmpty || !alive) return;
      replace(sel.start, sel.end, _normaliseNewlines(pasted), burst: false);
      _syncPlatform(force: true);
      return;
    }
    if (sel.isCollapsed) return;
    await Clipboard.setData(
      ClipboardData(text: t.substring(sel.start, sel.end)),
    );
    if (key == LogicalKeyboardKey.keyX && alive) {
      replace(sel.start, sel.end, '', burst: false);
      _syncPlatform(force: true);
    }
  }

  static String _normaliseNewlines(String s) =>
      s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  // ---- Pointer -------------------------------------------------------------------------

  /// Places the caret at [offset] (a click), or extends the selection to it
  /// (Shift-click, drag).
  void pointerAt(int offset, {bool extend = false}) {
    _select(
      extend
          ? _selection.copyWith(extentOffset: offset)
          : TextSelection.collapsed(offset: offset),
    );
  }

  /// Selects the word around [offset] (double-click); with [extendFrom],
  /// the selection grows word by word from that word (double-click drag).
  void selectWordAt(int offset, {(int, int)? extendFrom}) {
    final t = text;
    final (a, b) = _wordRange(t, offset);
    if (extendFrom == null) {
      _select(TextSelection(baseOffset: a, extentOffset: b));
      return;
    }
    final (fa, fb) = extendFrom;
    _select(
      offset < fa
          ? TextSelection(baseOffset: fb, extentOffset: a)
          : TextSelection(baseOffset: fa, extentOffset: math.max(b, fb)),
    );
  }

  (int, int) wordRangeAt(int offset) => _wordRange(text, offset);

  static (int, int) _wordRange(String t, int offset) {
    // Within the paragraph only (wordAt treats \n as a space).
    final (a, b) = wordAt(t, offset);
    return (a, b);
  }

  /// Selects the paragraph around [offset] (triple-click).
  void selectParagraphAt(int offset) {
    final c = content;
    final pt = pointOf(c, offset);
    final a = paragraphStart(c, pt.paragraph);
    _select(
      TextSelection(
        baseOffset: a,
        extentOffset: a + paragraphLength(c[pt.paragraph]),
      ),
    );
  }

  // ---- Text input ----------------------------------------------------------------------

  TextInputConnection? _connection;
  TextEditingValue? _sent;

  bool get attached => _connection?.attached ?? false;

  /// The configuration: multiline, delta model, no autocorrect or smart
  /// punctuation (writers' own text), no suggestions.
  static const TextInputConfiguration configuration = TextInputConfiguration(
    inputType: TextInputType.multiline,
    inputAction: TextInputAction.newline,
    enableDeltaModel: true,
    autocorrect: false,
    enableSuggestions: false,
    smartDashesType: SmartDashesType.disabled,
    smartQuotesType: SmartQuotesType.disabled,
  );

  /// Opens the platform text input (on focus).
  void attach() {
    if (attached) return;
    _connection = TextInput.attach(this, configuration)..show();
    _syncPlatform(force: true);
  }

  /// Closes the platform text input (on blur or exit).
  void detach() {
    final c = _connection;
    _connection = null;
    _composing = TextRange.empty;
    if (c != null && c.attached) c.close();
  }

  /// Places the platform's (invisible) input over the node so IME
  /// candidate windows appear by the text.
  void setInputGeometry(Size size, Matrix4 transform, Rect? caret) {
    final c = _connection;
    if (c == null || !c.attached) return;
    c.setEditableSizeAndTransform(size, transform);
    if (caret != null) {
      c
        ..setCaretRect(caret)
        ..setComposingRect(caret);
    }
  }

  @override
  TextEditingValue get currentTextEditingValue => TextEditingValue(
    text: text,
    selection: _selection,
    composing: _composing,
  );

  void _syncPlatform({bool force = false}) {
    final c = _connection;
    if (c == null || !c.attached) return;
    final v = currentTextEditingValue;
    if (!force && v == _sent) return;
    _sent = v;
    c.setEditingState(v);
  }

  /// Set while applying the platform's own edits (no echo back).
  bool _fromPlatform = false;

  @override
  void updateEditingValueWithDeltas(List<TextEditingDelta> deltas) {
    if (!alive) return;
    _fromPlatform = true;
    try {
      _applyDeltas(deltas);
    } finally {
      _fromPlatform = false;
    }
  }

  void _applyDeltas(List<TextEditingDelta> deltas) {
    for (final d in deltas) {
      if (d.oldText != text) {
        // Out of sync (an edit the platform did not see): resend ours.
        _syncPlatform(force: true);
        return;
      }
      switch (d) {
        case TextEditingDeltaInsertion(
          :final textInserted,
          :final insertionOffset,
        ):
          replace(
            insertionOffset,
            insertionOffset,
            textInserted.replaceAll('\r', '\n'),
            selectionAfter: d.selection,
          );
        case TextEditingDeltaDeletion(:final deletedRange):
          replace(
            deletedRange.start,
            deletedRange.end,
            '',
            selectionAfter: d.selection,
          );
        case TextEditingDeltaReplacement(
          :final replacedRange,
          :final replacementText,
        ):
          replace(
            replacedRange.start,
            replacedRange.end,
            replacementText.replaceAll('\r', '\n'),
            selectionAfter: d.selection,
          );
        case TextEditingDeltaNonTextUpdate():
          if (d.selection != _selection) {
            _goalX = null;
            _endBurst();
            selection = d.selection;
          }
      }
      _composing = d.composing.isValid && !d.composing.isCollapsed
          ? d.composing
          : TextRange.empty;
    }
    _sent = currentTextEditingValue;
    notifyListeners();
  }

  @override
  void updateEditingValue(TextEditingValue value) {
    // The non-delta path (platforms that ignore the delta model): diff.
    final old = text;
    final next = value.text;
    if (next == old) {
      if (value.selection.isValid && value.selection != _selection) {
        selection = value.selection;
      }
      _composing = value.composing;
      notifyListeners();
      return;
    }
    var a = 0;
    while (a < old.length &&
        a < next.length &&
        old.codeUnitAt(a) == next.codeUnitAt(a)) {
      a++;
    }
    var zo = old.length, zn = next.length;
    while (zo > a &&
        zn > a &&
        old.codeUnitAt(zo - 1) == next.codeUnitAt(zn - 1)) {
      zo--;
      zn--;
    }
    _fromPlatform = true;
    try {
      replace(
        a,
        zo,
        next.substring(a, zn),
        selectionAfter: value.selection.isValid ? value.selection : null,
      );
    } finally {
      _fromPlatform = false;
    }
    _composing = value.composing;
    _sent = value;
    notifyListeners();
  }

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline) insert('\n');
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _connection = null;
    _composing = TextRange.empty;
    notifyListeners();
  }

  // ---- Lifetime ---------------------------------------------------------------------

  bool _ended = false;

  /// Ends the session: closes the input and the typing gesture.
  void end() {
    if (_ended) return;
    _ended = true;
    _endBurst();
    detach();
  }

  @override
  void dispose() {
    end();
    super.dispose();
  }
}

/// A property write to the shared base regardless of the edit scope (roles
/// are not per breakpoint).
class _SharedSetProperty extends EditCommand {
  const _SharedSetProperty(this.nodeId, this.path, this.enumName);

  final String nodeId;
  final String path;
  final String enumName;

  @override
  String get label => 'Change $path';

  @override
  CommandResult apply(EditorState state) => SetProperty(
    [nodeId],
    path,
    ir.IrValue.enumValue(enumName),
  ).apply(state.copyWith(editScope: EditScope.both, scopeFlipped: false));
}
