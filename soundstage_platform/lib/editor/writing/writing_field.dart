import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/core.dart';
import '../shortcuts/shortcut_map.dart' show isMacPlatform;
import '../text/rich_text_model.dart';
import '../text/text_style_target.dart';

/// The edit that turns [before] into [after]: the replaced range of
/// [before] and the inserted text (common prefix and suffix removed), or
/// null when they are equal. [caret] (the caret after the edit, if known)
/// places an ambiguous insert, e.g. typing "a" in "aa".
({int start, int end, String text})? textDiff(
  String before,
  String after, {
  int? caret,
}) {
  if (before == after) return null;
  var prefix = 0;
  final maxPrefix = before.length < after.length ? before.length : after.length;
  while (prefix < maxPrefix &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  if (caret != null) {
    final inserted = after.length - before.length;
    // The edit ends at the caret: never let the prefix run past where the
    // change started.
    final latest = caret - (inserted > 0 ? inserted : 0);
    if (latest >= 0 && latest < prefix) prefix = latest;
  }
  var suffix = 0;
  while (suffix < before.length - prefix &&
      suffix < after.length - prefix &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  return (
    start: prefix,
    end: before.length - suffix,
    text: after.substring(prefix, after.length - suffix),
  );
}

/// Shows a text node's content with its marks (bold, italic, underline,
/// strikethrough, links) over [base].
class WritingTextController extends TextEditingController {
  WritingTextController({required this.base, super.text});

  TextStyle base;
  Color linkColor = const Color(0xFF6EA8FE);

  /// The node's paragraphs as shown (resolved at the writing breakpoint).
  List<ir.ResolvedParagraph> paragraphs = const [];

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final shown = [
      for (final p in paragraphs) p.spans.map((s) => s.text).join(),
    ].join('\n');
    if (shown != text || (withComposing && value.isComposingRangeValid)) {
      return TextSpan(style: base, text: text);
    }
    final children = <InlineSpan>[];
    for (final (i, p) in paragraphs.indexed) {
      if (i > 0) children.add(const TextSpan(text: '\n'));
      for (final s in p.spans) {
        if (s.text.isEmpty) continue;
        final st = s.style;
        final deco = switch (st.decoration.kind) {
          ir.TextDecorationKind.underline => TextDecoration.underline,
          ir.TextDecorationKind.strikethrough => TextDecoration.lineThrough,
          _ => null,
        };
        children.add(
          TextSpan(
            text: s.text,
            style: TextStyle(
              fontWeight: st.fontWeight >= kBoldThreshold
                  ? FontWeight.w700
                  : null,
              fontVariations: st.fontWeight >= kBoldThreshold
                  ? const [FontVariation('wght', 700)]
                  : null,
              fontStyle: st.italic ? FontStyle.italic : null,
              decoration: s.link != null ? TextDecoration.underline : deco,
              color: s.link != null ? linkColor : null,
            ),
          ),
        );
      }
    }
    return TextSpan(style: base, children: children);
  }
}

/// One text node of the Writing view, edited in place (m5.md T5.2).
///
/// Typing is `ReplaceText` on the node's base content (shared across
/// breakpoints); Cmd+B / Cmd+I toggle bold and italic over the selection
/// with `StyleTextRange`. A focus session is one undo step, and Cmd+Z /
/// Cmd+Shift+Z are the editor's undo and redo.
class WritingField extends ConsumerStatefulWidget {
  const WritingField({
    required this.nodeId,
    required this.breakpointId,
    required this.style,
    this.readOnly = false,
    this.placeholder = 'Empty text',
    this.semanticLabel,
    super.key,
  });

  final String nodeId;

  /// Where marks are read from (the writing breakpoint).
  final String breakpointId;
  final TextStyle style;
  final bool readOnly;
  final String placeholder;

  /// What screen readers call the field ("Heading: Title").
  final String? semanticLabel;

  @override
  ConsumerState<WritingField> createState() => _WritingFieldState();
}

class _WritingFieldState extends ConsumerState<WritingField> {
  late final WritingTextController _text = WritingTextController(
    base: widget.style,
  );
  final FocusNode _focus = FocusNode(debugLabel: 'WritingField');
  String _last = '';

  EditorController get _editor => ref.read(editorControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _sync(_plainOf(ref.read(editorControllerProvider).document));
    _text.addListener(_changed);
    _focus.addListener(_focusChanged);
  }

  /// The node's plain text (paragraphs joined by `\n`).
  String _plainOf(ir.StageDocument doc) {
    final node = ir.DocumentIndex.of(doc).node(widget.nodeId);
    if (node is ir.TextNode) return plainTextOf(node.content);
    // Text inside an instance: as resolved.
    final rn = _editor
        .resolvedFor(widget.breakpointId)
        .resolved
        .nodeIndex[widget.nodeId];
    return rn?.paragraphs
            ?.map((p) => p.spans.map((s) => s.text).join())
            .join('\n') ??
        '';
  }

  @override
  void dispose() {
    if (_focus.hasFocus) _editor.endGesture();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      _editor.beginGesture();
    } else {
      _editor.endGesture();
    }
  }

  void _changed() {
    final now = _text.text;
    if (now == _last || widget.readOnly) return;
    if (_text.value.isComposingRangeValid) return; // wait for the IME
    final caret = _text.selection.isValid ? _text.selection.end : null;
    final d = textDiff(_last, now, caret: caret);
    _last = now;
    if (d == null) return;
    _editor.execute(
      ReplaceText(
        widget.nodeId,
        d.start,
        d.end,
        d.text,
        coalesceKey: 'writing:${widget.nodeId}',
      ),
    );
  }

  /// Takes the node's text after a change from elsewhere (undo, another
  /// view), keeping the caret where it can.
  void _sync(String plain) {
    if (plain == _last) return;
    _last = plain;
    if (_text.text == plain) return;
    final sel = _text.selection;
    _text.value = TextEditingValue(
      text: plain,
      selection: sel.isValid
          ? TextSelection(
              baseOffset: sel.baseOffset.clamp(0, plain.length),
              extentOffset: sel.extentOffset.clamp(0, plain.length),
            )
          : TextSelection.collapsed(offset: plain.length),
    );
  }

  void _history({required bool redo}) {
    _editor.endGesture();
    redo ? _editor.redo() : _editor.undo();
    if (_focus.hasFocus) _editor.beginGesture();
  }

  void _toggle(TextToggle t) {
    if (widget.readOnly) return;
    final sel = _text.selection;
    if (!sel.isValid || sel.isCollapsed) return;
    final doc = ref.read(editorControllerProvider).document;
    final node = ir.DocumentIndex.of(doc).node(widget.nodeId);
    if (node is! ir.TextNode) return;
    final rn = _editor
        .resolvedFor(widget.breakpointId)
        .resolved
        .nodeIndex[widget.nodeId];
    if (rn == null) return;
    final refs = spanRefsFor(node.content, sel.start, sel.end);
    final writes = toggleWrites(t, [
      for (final s in resolvedSpansAt(rn, refs)) s.style,
    ], rn.textStyle);
    _editor.execute(
      StyleTextRange(
        widget.nodeId,
        sel.start,
        sel.end,
        writes,
        effective: (p, s) => resolvedSpanStyle(rn, p, s),
        customLabel: t == TextToggle.bold ? 'Bold' : 'Italic',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    // The document, not a derived value: resolving uses the controller,
    // which selectors may not.
    final doc = ref.watch(editorControllerProvider.select((s) => s.document));
    final plain = _plainOf(doc);
    if (plain != _last) {
      // From elsewhere (undo, another view): take it after this frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _sync(_plainOf(ref.read(editorControllerProvider).document));
      });
    }
    final rn = _editor
        .resolvedFor(widget.breakpointId)
        .resolved
        .nodeIndex[widget.nodeId];
    _text
      ..base = widget.style
      ..linkColor = t.colors.accent
      ..paragraphs = rn?.paragraphs ?? const [];
    const mod = SingleActivator.new;
    final meta = isMacPlatform();
    return Shortcuts(
      shortcuts: {
        mod(LogicalKeyboardKey.keyB, meta: meta, control: !meta):
            const _ToggleIntent(TextToggle.bold),
        mod(LogicalKeyboardKey.keyI, meta: meta, control: !meta):
            const _ToggleIntent(TextToggle.italic),
      },
      child: Actions(
        actions: {
          _ToggleIntent: CallbackAction<_ToggleIntent>(
            onInvoke: (i) => _toggle(i.toggle),
          ),
          UndoTextIntent: CallbackAction<UndoTextIntent>(
            onInvoke: (_) => _history(redo: false),
          ),
          RedoTextIntent: CallbackAction<RedoTextIntent>(
            onInvoke: (_) => _history(redo: true),
          ),
        },
        child: Semantics(
          label: widget.semanticLabel,
          child: TextField(
            key: ValueKey<String>('writing:${widget.nodeId}'),
            controller: _text,
            focusNode: _focus,
            readOnly: widget.readOnly,
            maxLines: null,
            style: widget.style,
            cursorColor: t.colors.accent,
            decoration: InputDecoration.collapsed(
              hintText: widget.placeholder,
              hintStyle: widget.style.copyWith(color: t.colors.textDisabled),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToggleIntent extends Intent {
  const _ToggleIntent(this.toggle);

  final TextToggle toggle;
}
