import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/text/text_edit_controller.dart';
import 'package:soundstage_platform/editor/text/text_edit_layer.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../interaction/interaction_harness.dart';

// txt: "Hello" at (100, 650), 16 px test-font glyphs (16 px squares).

extension on Harness {
  TextEditLayerState get layer =>
      tester.state<TextEditLayerState>(find.byType(TextEditLayer));
  RenderStageText box(String bp) =>
      canvas.artboards[bp]!.registry['txt']! as RenderStageText;
  String get txtText => (node('txt') as ir.TextNode).content
      .map((p) => p.spans.map((s) => s.text).join())
      .join('\n');

  Future<void> typeDelta(String s) async {
    final session = layer.session!;
    for (final ch in s.split('')) {
      final sel = session.selection;
      session.updateEditingValueWithDeltas([
        TextEditingDeltaReplacement(
          oldText: session.text,
          replacementText: ch,
          replacedRange: TextRange(start: sel.start, end: sel.end),
          selection: TextSelection.collapsed(offset: sel.start + 1),
          composing: TextRange.empty,
        ),
      ]);
    }
    await tester.pump();
  }
}

void main() {
  testWidgets('double-click enters edit mode on the clicked artboard with the '
      'word selected; typing updates both artboards', (tester) async {
    final h = await pumpCanvas(tester);
    await h.doubleClick(h.mob(120, 658));
    expect(h.st.textEditId, 'txt');
    final s = h.layer.session!;
    expect(s.breakpointId, 'mobile');
    expect(s.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
    expect(primaryFocusIsStageText(), isTrue);
    // Only the edited artboard paints the decoration.
    expect(h.box('mobile').editing, isNotNull);
    expect(h.box('desktop').editing, isNull);
    await h.typeDelta('Hi');
    expect(h.txtText, 'Hi');
    // Auto-width text grows live on both artboards.
    expect(h.box('desktop').size.width, 32);
    expect(h.box('mobile').size.width, 32);
    expect(h.box('mobile').editing!.caret, 2);
    // A third click selects the paragraph; a click places the caret.
    await h.click(h.mob(108, 658));
    expect(s.selection, const TextSelection.collapsed(offset: 1));
    // Drag-select inside the text.
    await h.drag(h.mob(101, 658), h.mob(131, 658), steps: 2);
    expect(s.selection, const TextSelection(baseOffset: 0, extentOffset: 2));
    // Esc leaves edit mode, keeps the selection, and the session is one
    // undo step.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(h.st.textEditId, isNull);
    expect(h.st.selection, {'txt'});
    expect(h.box('mobile').editing, isNull);
    expect(h.st.history.undoLabel, 'Edit text');
    h.ctl.undo();
    await tester.pump();
    expect(h.txtText, 'Hello');
  });

  testWidgets('Enter on a selected text node selects all; clicking outside '
      'ends editing', (tester) async {
    final h = await pumpCanvas(tester);
    await h.click(h.desk(110, 658));
    expect(h.st.selection, {'txt'});
    h.ctl.selectChildrenOfSelection(); // Enter (the shell's shortcut)
    await tester.pump();
    final s = h.layer.session!;
    expect(s.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
    await h.click(h.desk(150, 150));
    expect(h.layer.session, isNull);
    expect(h.st.textEditId, isNull);
    expect(h.st.selection, {'a'});
  });

  testWidgets('typing a non-shortcut character with a text node selected '
      'starts editing at the end', (tester) async {
    final h = await pumpCanvas(tester);
    await h.click(h.desk(110, 658));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV); // the move tool
    await tester.pump();
    expect(h.layer.session, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pump();
    expect(h.layer.session, isNotNull);
    expect(h.txtText, 'Hellox');
    expect(
      h.layer.session!.selection,
      const TextSelection.collapsed(offset: 6),
    );
    // In edit mode bare keys type instead of switching tools.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(h.st.tool, EditorTool.move);
  });

  testWidgets('undo inside edit mode keeps editing', (tester) async {
    final h = await pumpCanvas(tester);
    await h.click(h.desk(110, 658));
    h.ctl.selectChildrenOfSelection(); // Enter (the shell's shortcut)
    await tester.pump();
    await h.typeDelta('Yo');
    final s = h.layer.session!;
    expect(s.undo(), isTrue);
    await tester.pump();
    expect(h.txtText, 'Hello');
    expect(h.st.textEditId, 'txt');
    expect(identical(h.layer.session, s), isTrue);
    expect(s.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
  });

  testWidgets('a role label shows over a hovered text node with a role', (
    tester,
  ) async {
    final h = await pumpCanvas(tester);
    h.ctl.execute(
      SetProperty(['txt'], 'role', const ir.IrValue.enumValue('heading2')),
    );
    h.ctl.hover('txt');
    await tester.pump();
    expect(roleLabel(ir.NodeRole.heading2), 'H2');
    expect(roleLabel(ir.NodeRole.none), isNull);
  });

  for (final (mode, grows) in [
    (ir.TextAutoResize.height, true),
    (ir.TextAutoResize.fixed, false),
    (ir.TextAutoResize.truncate, false),
  ]) {
    testWidgets('auto-resize while typing: ${mode.name}', (tester) async {
      final doc = ir
          .updateNode(
            interactionDoc(),
            'txt',
            (n) => (n as ir.TextNode).copyWith(
              autoResize: mode,
              maxLines: mode == ir.TextAutoResize.truncate ? 1 : null,
            ),
          )
          .document;
      final h = await pumpCanvas(tester, doc: doc);
      await h.click(h.desk(110, 658));
      h.ctl.selectChildrenOfSelection();
      await tester.pump();
      final before = h.box('desktop').size;
      final top = h.worldRect('txt')!.top;
      // 50 px wide: "Hello" + 10 glyphs wraps onto more lines.
      h.layer.session!.selection = const TextSelection.collapsed(offset: 5);
      await h.typeDelta(' wrapping');
      final after = h.box('desktop').size;
      expect(after.width, before.width);
      expect(after.height > before.height, grows);
      expect(h.worldRect('txt')!.top, top); // grows downward
      if (mode == ir.TextAutoResize.truncate) {
        // Edit mode reveals the full text: every line is laid out.
        final l = h.box('desktop').textLayout.paragraphBox(0);
        expect(l.painter.maxLines, isNull);
        expect(h.box('mobile').textLayout.paragraphBox(0).painter.maxLines, 1);
      }
    });
  }

  testWidgets('Cmd+K opens the link prompt; Enter applies the link', (
    tester,
  ) async {
    final h = await pumpCanvas(tester);
    await h.click(h.desk(110, 658));
    h.ctl.selectChildrenOfSelection();
    await tester.pump();
    // Ctrl off macOS (the test platform).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final field = find.descendant(
      of: find.byKey(const ValueKey('text-link-field')),
      matching: find.byType(EditableText),
    );
    expect(field, findsOneWidget);
    await tester.enterText(field, 'https://example.com');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final span = (h.node('txt') as ir.TextNode).content.single.spans.single;
    expect(span.link, const ir.SpanLink.url('https://example.com'));
    expect(h.st.textEditId, 'txt');
  });
}
