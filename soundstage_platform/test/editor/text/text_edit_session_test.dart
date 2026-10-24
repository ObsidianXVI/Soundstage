import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/text/rich_text_model.dart';
import 'package:soundstage_platform/editor/text/text_edit_session.dart';
import 'package:soundstage_platform/ir/ir.dart';

import '../core/fixtures.dart';

/// t1: "Hello bold" / "world" ("bold" is bold).
StageDocument textDoc() => updateNode(
  fixtureDoc(),
  't1',
  (n) => (n as TextNode).copyWith(
    content: const [
      Paragraph(
        spans: [
          Span(text: 'Hello '),
          Span(text: 'bold', style: TextStyleOverride(fontWeight: 700)),
        ],
      ),
      Paragraph(spans: [Span(text: 'world')]),
    ],
  ),
).document;

/// A monospace view: every character 10 px wide, one 10 px line per
/// paragraph (no wrapping).
class FakeView implements TextEditView {
  FakeView(this.content);

  final List<Paragraph> Function() content;

  @override
  int? offsetAt(Offset local) {
    final c = content();
    final p = (local.dy / 10).floor().clamp(0, c.length - 1);
    final o = (local.dx / 10).round().clamp(0, paragraphLength(c[p]));
    return offsetOf(c, TextPoint(p, o));
  }

  @override
  Rect? caretRect(int offset, {bool upstream = false}) {
    final pt = pointOf(content(), offset);
    return Rect.fromLTWH(pt.offset * 10.0, pt.paragraph * 10.0, 0, 10);
  }

  @override
  (int, int)? lineBoundary(int offset, {bool upstream = false}) {
    final c = content();
    final p = pointOf(c, offset).paragraph;
    final s = paragraphStart(c, p);
    return (s, s + paragraphLength(c[p]));
  }
}

class Harness {
  Harness({bool mac = true}) {
    c = editorContainer(textDoc());
    c.ctl
      ..select({'t1'})
      ..applySelection(
        const SelectionState(selection: {'t1'}, textEditId: 't1'),
      );
    session = TextEditSession(
      controller: c.ctl,
      readState: () => c.st,
      nodeId: 't1',
      breakpointId: 'desktop',
      view: FakeView(() => session.content),
      mac: mac,
      clock: () => now,
      onExit: () => exits++,
      onLinkRequest: () => linkRequests++,
    );
    addTearDown(session.dispose);
  }

  late final ProviderContainer c;
  late final TextEditSession session;
  Duration now = Duration.zero;
  int exits = 0;
  int linkRequests = 0;

  String get text => session.text;
  TextSelection get sel => session.selection;
  TextNode get node => c.node('t1') as TextNode;

  void caret(int o) => session.selection = TextSelection.collapsed(offset: o);

  void type(String s) {
    for (final ch in s.split('')) {
      final at = sel.start;
      session.updateEditingValueWithDeltas([
        TextEditingDeltaReplacement(
          oldText: text,
          replacementText: ch,
          replacedRange: TextRange(start: sel.start, end: sel.end),
          selection: TextSelection.collapsed(offset: at + 1),
          composing: TextRange.empty,
        ),
      ]);
      now += const Duration(milliseconds: 100);
    }
  }
}

/// Pumps a focus that forwards keys to [h]'s session.
Future<void> pumpKeys(WidgetTester tester, Harness h) => tester.pumpWidget(
  Focus(
    autofocus: true,
    onKeyEvent: (_, e) => h.session.handleKey(e),
    child: const SizedBox(),
  ),
);

Future<void> key(
  WidgetTester tester,
  LogicalKeyboardKey k, {
  bool shift = false,
  bool alt = false,
  bool meta = false,
  bool ctrl = false,
}) async {
  final mods = [
    if (shift) LogicalKeyboardKey.shiftLeft,
    if (alt) LogicalKeyboardKey.altLeft,
    if (meta) LogicalKeyboardKey.metaLeft,
    if (ctrl) LogicalKeyboardKey.controlLeft,
  ];
  for (final m in mods) {
    await tester.sendKeyDownEvent(m);
  }
  await tester.sendKeyEvent(k);
  for (final m in mods.reversed) {
    await tester.sendKeyUpEvent(m);
  }
}

void main() {
  group('delta input', () {
    test('insertion, deletion, replacement', () {
      final h = Harness()..caret(5);
      h.session.updateEditingValueWithDeltas([
        TextEditingDeltaInsertion(
          oldText: h.text,
          textInserted: ',',
          insertionOffset: 5,
          selection: const TextSelection.collapsed(offset: 6),
          composing: TextRange.empty,
        ),
      ]);
      expect(h.text, 'Hello, bold\nworld');
      expect(h.sel, const TextSelection.collapsed(offset: 6));
      h.session.updateEditingValueWithDeltas([
        TextEditingDeltaDeletion(
          oldText: h.text,
          deletedRange: const TextRange(start: 0, end: 1),
          selection: const TextSelection.collapsed(offset: 0),
          composing: TextRange.empty,
        ),
      ]);
      expect(h.text, 'ello, bold\nworld');
      h.session.updateEditingValueWithDeltas([
        TextEditingDeltaReplacement(
          oldText: h.text,
          replacementText: 'BOLD',
          replacedRange: const TextRange(start: 6, end: 10),
          selection: const TextSelection.collapsed(offset: 10),
          composing: TextRange.empty,
        ),
      ]);
      expect(h.text, 'ello, BOLD\nworld');
      // The replaced word keeps its (bold) style.
      expect(h.node.content.first.spans.last.style.fontWeight, 700);
    });

    test('IME composition shows a composing range, then commits', () {
      final h = Harness()..caret(16);
      h.session.updateEditingValueWithDeltas([
        TextEditingDeltaInsertion(
          oldText: h.text,
          textInserted: 'k',
          insertionOffset: 16,
          selection: const TextSelection.collapsed(offset: 17),
          composing: const TextRange(start: 16, end: 17),
        ),
      ]);
      expect(h.session.composing, const TextRange(start: 16, end: 17));
      h.session.updateEditingValueWithDeltas([
        TextEditingDeltaReplacement(
          oldText: h.text,
          replacementText: 'か',
          replacedRange: const TextRange(start: 16, end: 17),
          selection: const TextSelection.collapsed(offset: 17),
          composing: const TextRange(start: 16, end: 17),
        ),
        const TextEditingDeltaNonTextUpdate(
          oldText: 'Hello bold\nworldか',
          selection: TextSelection.collapsed(offset: 17),
          composing: TextRange.empty,
        ),
      ]);
      expect(h.text, 'Hello bold\nworldか');
      expect(h.session.composing, TextRange.empty);
    });

    test('out-of-sync deltas are ignored', () {
      final h = Harness()..caret(0);
      h.session.updateEditingValueWithDeltas([
        const TextEditingDeltaInsertion(
          oldText: 'stale',
          textInserted: 'x',
          insertionOffset: 0,
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange.empty,
        ),
      ]);
      expect(h.text, 'Hello bold\nworld');
    });

    test('the non-delta path diffs', () {
      final h = Harness()..caret(5);
      h.session.updateEditingValue(
        const TextEditingValue(
          text: 'Hello! bold\nworld',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      expect(h.text, 'Hello! bold\nworld');
      expect(h.sel.baseOffset, 6);
    });
  });

  group('undo', () {
    test('typing coalesces by word and by pause; edit-mode undo restores '
        'the caret', () {
      final h = Harness()..caret(16);
      h.type(' big');
      h.type(' sea');
      h.now += const Duration(seconds: 2);
      h.type('s');
      expect(h.text, 'Hello bold\nworld big seas');
      expect(h.session.undo(), isTrue);
      expect(h.text, 'Hello bold\nworld big sea');
      expect(h.sel, const TextSelection.collapsed(offset: 24));
      // A word groups with the space that ends it.
      expect(h.session.undo(), isTrue);
      expect(h.text, 'Hello bold\nworld big ');
      expect(h.session.undo(), isTrue);
      expect(h.text, 'Hello bold\nworld ');
      expect(h.session.undo(), isTrue);
      expect(h.text, 'Hello bold\nworld');
      expect(h.sel, const TextSelection.collapsed(offset: 16));
      expect(h.session.redo(), isTrue);
      expect(h.text, 'Hello bold\nworld ');
    });

    test('ending squashes the session into one step', () {
      final h = Harness()..caret(16);
      h.type(' a');
      h.type(' b');
      h.session.end();
      h.c.ctl.squashHistoryAfter(h.session.historyAnchor, 'Edit text');
      expect(h.c.st.history.undoLabel, 'Edit text');
      h.c.ctl.undo();
      expect(h.text, 'Hello bold\nworld');
    });
  });

  group('keyboard', () {
    testWidgets('navigation table (macOS)', (tester) async {
      final h = Harness()..caret(2);
      await pumpKeys(tester, h);
      Future<int> press(
        LogicalKeyboardKey k, {
        bool shift = false,
        bool alt = false,
        bool meta = false,
      }) async {
        await key(tester, k, shift: shift, alt: alt, meta: meta);
        return h.sel.extentOffset;
      }

      expect(await press(LogicalKeyboardKey.arrowRight), 3);
      expect(await press(LogicalKeyboardKey.arrowLeft), 2);
      expect(await press(LogicalKeyboardKey.arrowRight, alt: true), 5);
      expect(await press(LogicalKeyboardKey.arrowRight, alt: true), 10);
      expect(await press(LogicalKeyboardKey.arrowLeft, alt: true), 6);
      expect(await press(LogicalKeyboardKey.arrowRight, meta: true), 10);
      expect(await press(LogicalKeyboardKey.arrowLeft, meta: true), 0);
      expect(await press(LogicalKeyboardKey.arrowDown), 11);
      expect(await press(LogicalKeyboardKey.arrowDown), 16); // last line: end
      expect(await press(LogicalKeyboardKey.arrowUp, meta: true), 0);
      expect(await press(LogicalKeyboardKey.arrowDown, meta: true), 16);
      expect(await press(LogicalKeyboardKey.home), 11);
      expect(await press(LogicalKeyboardKey.end), 16);
      // Shift extends; an arrow collapses to the selection's edge.
      h.caret(2);
      await press(LogicalKeyboardKey.arrowRight, shift: true);
      await press(LogicalKeyboardKey.arrowRight, shift: true);
      expect(h.sel, const TextSelection(baseOffset: 2, extentOffset: 4));
      await press(LogicalKeyboardKey.arrowLeft);
      expect(h.sel, const TextSelection.collapsed(offset: 2));
      // Cmd+A.
      await key(tester, LogicalKeyboardKey.keyA, meta: true);
      expect(h.sel, const TextSelection(baseOffset: 0, extentOffset: 16));
    });

    testWidgets('Enter splits, Backspace merges, word and line deletes', (
      tester,
    ) async {
      final h = Harness()..caret(5);
      await pumpKeys(tester, h);
      await key(tester, LogicalKeyboardKey.enter);
      expect(h.text, 'Hello\n bold\nworld');
      expect(h.node.content, hasLength(3));
      await key(tester, LogicalKeyboardKey.backspace);
      expect(h.text, 'Hello bold\nworld');
      h.caret(11);
      await key(tester, LogicalKeyboardKey.backspace);
      expect(h.text, 'Hello boldworld');
      await key(tester, LogicalKeyboardKey.backspace, alt: true);
      expect(h.text, 'Hello world');
      await key(tester, LogicalKeyboardKey.backspace, meta: true);
      expect(h.text, 'world');
      await key(tester, LogicalKeyboardKey.delete);
      expect(h.text, 'orld');
      // Shift+Enter: a line break inside the paragraph.
      await key(tester, LogicalKeyboardKey.enter, shift: true);
      expect(h.node.content, hasLength(1));
      expect(h.text, ' orld');
    });

    testWidgets('Esc and Cmd+Enter exit; Cmd+K asks for a link', (
      tester,
    ) async {
      final h = Harness();
      await pumpKeys(tester, h);
      await key(tester, LogicalKeyboardKey.escape);
      await key(tester, LogicalKeyboardKey.enter, meta: true);
      expect(h.exits, 2);
      await key(tester, LogicalKeyboardKey.keyK, meta: true);
      expect(h.linkRequests, 1);
    });

    testWidgets('bare keys never reach the editor shortcuts', (tester) async {
      final h = Harness()..caret(0);
      await pumpKeys(tester, h);
      expect(
        h.session.handleKey(
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.keyV,
            logicalKey: LogicalKeyboardKey.keyV,
            character: 'v',
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.skipRemainingHandlers,
      );
    });

    testWidgets('Cmd+B / I / U toggle over the selection', (tester) async {
      final h = Harness();
      await pumpKeys(tester, h);
      h.session.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await key(tester, LogicalKeyboardKey.keyB, meta: true);
      expect(h.node.content.first.spans.first.style.fontWeight, 700);
      expect(h.node.content.first.spans.first.text, 'Hello');
      await key(tester, LogicalKeyboardKey.keyB, meta: true);
      // Back to inherited: the spans merge again.
      expect(h.node.content.first.spans.first.text, 'Hello ');
      // "Hello bold": mixed → on for all, then off for all.
      h.session.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 10,
      );
      await key(tester, LogicalKeyboardKey.keyB, meta: true);
      expect(h.node.content.first.spans.single.style.fontWeight, 700);
      await key(tester, LogicalKeyboardKey.keyB, meta: true);
      expect(h.node.content.first.spans.single.style.fontWeight, isNull);
      await key(tester, LogicalKeyboardKey.keyI, meta: true);
      expect(h.node.content.first.spans.single.style.italic, isTrue);
      await key(tester, LogicalKeyboardKey.keyU, meta: true);
      expect(
        h.node.content.first.spans.single.style.decoration?.kind,
        TextDecorationKind.underline,
      );
      expect(h.c.st.textEditId, 't1');
    });

    testWidgets('Cmd+B at a collapsed caret styles the next typed text', (
      tester,
    ) async {
      final h = Harness()..caret(16);
      await pumpKeys(tester, h);
      await key(tester, LogicalKeyboardKey.keyB, meta: true);
      expect(h.session.pendingStyle, {'fontWeight': const IrValue.number(700)});
      h.type('!');
      expect(h.node.content.last.spans.last.text, '!');
      expect(h.node.content.last.spans.last.style.fontWeight, 700);
      expect(h.session.pendingStyle, isEmpty);
    });

    testWidgets('role shortcuts: Cmd+Alt+1…6, 0', (tester) async {
      final h = Harness();
      await pumpKeys(tester, h);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
      expect(h.node.common.role, NodeRole.heading2);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
      expect(h.node.common.role, NodeRole.paragraph);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    });

    testWidgets('off macOS: Ctrl is the modifier', (tester) async {
      final h = Harness(mac: false)..caret(0);
      await pumpKeys(tester, h);
      await key(tester, LogicalKeyboardKey.arrowRight, ctrl: true);
      expect(h.sel.extentOffset, 5);
      await key(tester, LogicalKeyboardKey.end, ctrl: true);
      expect(h.sel.extentOffset, 16);
    });
  });

  group('pointer and links', () {
    test('word and paragraph selection', () {
      final h = Harness();
      h.session.selectWordAt(8);
      expect(h.sel, const TextSelection(baseOffset: 6, extentOffset: 10));
      h.session.selectWordAt(2, extendFrom: (6, 10));
      expect(h.sel, const TextSelection(baseOffset: 10, extentOffset: 0));
      h.session.selectParagraphAt(13);
      expect(h.sel, const TextSelection(baseOffset: 11, extentOffset: 16));
      h.session.pointerAt(3);
      h.session.pointerAt(8, extend: true);
      expect(h.sel, const TextSelection(baseOffset: 3, extentOffset: 8));
    });

    test('links: on a selection, edited at a caret inside, inserted at a '
        'caret outside', () {
      final h = Harness();
      h.session.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      h.session.applyLink('https://a.b');
      expect(
        h.node.content.first.spans.first.link,
        const SpanLink.url('https://a.b'),
      );
      h.caret(2);
      expect(h.session.linkRange, (0, 5));
      h.session.applyLink('https://c.d');
      expect(
        h.node.content.first.spans.first.link,
        const SpanLink.url('https://c.d'),
      );
      h.caret(16);
      h.session.applyLink('https://e.f');
      expect(h.text, 'Hello bold\nworldhttps://e.f');
      expect(
        h.node.content.last.spans.last.link,
        const SpanLink.url('https://e.f'),
      );
      // Removing.
      h.caret(2);
      h.session.applyLink('');
      expect(h.node.content.first.spans.first.link, isNull);
    });
  });
}
