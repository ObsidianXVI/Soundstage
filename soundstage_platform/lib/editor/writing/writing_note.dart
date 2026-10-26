import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:soundstage_platform/design_system/design_system.dart';

import '../core/core.dart';

/// [child] with the author's meta-note on scene or node [id] (m5.md T5.3):
/// a note button on hover (always while the note is open), and the note
/// below, edited in place. Notes are private; publishing drops them.
class WritingNoted extends ConsumerStatefulWidget {
  const WritingNoted({required this.id, required this.child, super.key});

  final String id;
  final Widget child;

  @override
  ConsumerState<WritingNoted> createState() => _WritingNotedState();
}

class _WritingNotedState extends ConsumerState<WritingNoted> {
  bool _hover = false;
  bool _open = false;
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'WritingNote');

  EditorController get _editor => ref.read(editorControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    _text.text =
        ref.read(editorControllerProvider).document.notes[widget.id] ?? '';
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _editor.beginGesture();
      } else {
        _editor.endGesture();
        // An emptied note closes.
        if (_text.text.trim().isEmpty && mounted) setState(() => _open = false);
      }
    });
  }

  @override
  void dispose() {
    if (_focus.hasFocus) _editor.endGesture();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open || _text.text.trim().isNotEmpty);
    if (_open) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.ss;
    final note = ref.watch(
      editorControllerProvider.select((s) => s.document.notes[widget.id]),
    );
    // Undo, another view: follow the document unless typing here.
    if (!_focus.hasFocus && (note ?? '') != _text.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _focus.hasFocus) return;
        _text.text =
            ref.read(editorControllerProvider).document.notes[widget.id] ?? '';
      });
    }
    final shown = _open || (note?.trim().isNotEmpty ?? false);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: widget.child),
              SizedBox(
                width: 32,
                child: Opacity(
                  opacity: _hover || shown ? 1 : 0,
                  child: SsIconButton(
                    key: ValueKey<String>('note-button:${widget.id}'),
                    icon: SsIcons.stickyNote,
                    semanticLabel: shown ? 'Note' : 'Add a note',
                    size: 24,
                    selected: shown,
                    onPressed: _toggle,
                  ),
                ),
              ),
            ],
          ),
          if (shown)
            Container(
              margin: const EdgeInsets.only(
                top: SsSpace.s1,
                bottom: SsSpace.s2,
                right: 32,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: SsSpace.s3,
                vertical: SsSpace.s2,
              ),
              decoration: BoxDecoration(
                color: t.colors.warning.withValues(alpha: 0.10),
                border: Border(
                  left: BorderSide(color: t.colors.warning, width: 2),
                ),
              ),
              child: TextField(
                key: ValueKey<String>('note:${widget.id}'),
                controller: _text,
                focusNode: _focus,
                maxLines: null,
                style: t.text.small.copyWith(color: t.colors.textPrimary),
                decoration: InputDecoration.collapsed(
                  hintText: 'A note for yourself (never published)',
                  hintStyle: t.text.small.copyWith(
                    color: t.colors.textDisabled,
                  ),
                ),
                onChanged: (v) => _editor.execute(SetNote(widget.id, v)),
              ),
            ),
        ],
      ),
    );
  }
}
