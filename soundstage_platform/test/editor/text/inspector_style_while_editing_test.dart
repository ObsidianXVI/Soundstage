// FINDING-1 (T1.12 re-check): an inspector style change while a text is
// being edited on the canvas applies to the session's selection, is visible
// at once, and keeps the session (focus returns to the text).
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/text/text_edit_controller.dart'
    show primaryFocusIsStageText;
import 'package:soundstage_platform/editor/text/text_edit_layer.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../../acceptance/acceptance_rig.dart';
import '../insert/fakes.dart';

const _ink = ir.StageColor(r: 0.1, g: 0.1, b: 0.1);

ir.StageDocument _doc() {
  final ids = ir.IdGenerator.seeded(3);
  final empty = ir.StageDocument.empty(ids: ids);
  final scene = ir.Scene.blankPinned(
    ids: ids,
    breakpoint: empty.breakpoints.first,
    name: 'One',
  );
  final root = scene.root.copyWith(
    children: [
      const ir.TextNode(
        common: ir.NodeCommon(
          id: 'txt',
          name: 'txt',
          x: 100,
          y: 100,
          width: 400,
          height: 40,
        ),
        autoResize: ir.TextAutoResize.height,
        style: ir.TextStyleOverride(
          fontSize: 32,
          fills: [ir.Paint.solid(id: 'text', color: _ink)],
        ),
        content: [
          ir.Paragraph(spans: [ir.Span(text: 'Hello world')]),
        ],
      ),
    ],
  );
  return empty.copyWith(scenes: [scene.copyWith(root: root)]);
}

List<ir.Span> _spans(Rig r) =>
    (r.node('txt') as ir.TextNode).content.single.spans;

ir.StageColor? _colourOf(ir.Span s) =>
    (s.style.fills?.firstOrNull as ir.SolidPaint?)?.color;

Future<void> _startEditing(Rig r) async {
  await r.selectNode('txt');
  await r.focusEditor();
  await r.tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await r.pump();
  expect(r.st.textEditId, 'txt');
}

void main() {
  setUp(() => StageAssetResolver.defaultLocal = StubPngLoader());
  tearDown(() => StageAssetResolver.defaultLocal = null);

  testWidgets('a Fill hex committed with Enter colours the selected word and '
      'keeps the session', (tester) async {
    final r = await pumpEditor(tester, _doc());
    await r.zoomToFit();
    await _startEditing(r);
    await r.selectText(0, 5); // "Hello"

    final hex = r.field('style.fills.text.color');
    await r.reveal(hex);
    expect(hex, findsOneWidget);
    await r.scrollInspectorTo(hex);
    await tester.tap(hex);
    await r.pump();
    await tester.enterText(hex, 'ff0000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await r.pump(3);

    expect(r.st.textEditId, 'txt', reason: 'the session stays alive');
    final spans = _spans(r);
    expect(spans.first.text, 'Hello');
    expect(_colourOf(spans.first), const ir.StageColor(r: 1, g: 0, b: 0));
    expect(spans.last.text, ' world');
    expect(_colourOf(spans.last), anyOf(isNull, _ink));
    // The node's own fill is unchanged.
    final own = (r.node('txt') as ir.TextNode).style.fills!.single;
    expect((own as ir.SolidPaint).color, _ink);
    // Focus is back on the text: typing goes into it.
    final layer = tester.state<TextEditLayerState>(find.byType(TextEditLayer));
    expect(layer.session, isNotNull);
    expect(
      layer.session!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 5),
    );
    await r.pump(2);
    expect(
      primaryFocusIsStageText(),
      isTrue,
      reason: 'focus is back on the edited text',
    );
  });

  testWidgets('with a collapsed caret the colour applies to the whole text', (
    tester,
  ) async {
    final r = await pumpEditor(tester, _doc());
    await r.zoomToFit();
    await _startEditing(r);
    await r.selectText(3, 3);
    final hex = r.field('style.fills.text.color');
    await r.reveal(hex);
    await r.scrollInspectorTo(hex);
    await tester.tap(hex);
    await r.pump();
    await tester.enterText(hex, '00ff00');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await r.pump(3);
    expect(r.st.textEditId, 'txt');
    const green = ir.StageColor(r: 0, g: 1, b: 0);
    final own = (r.node('txt') as ir.TextNode).style.fills!.single;
    for (final s in _spans(r)) {
      expect(_colourOf(s) ?? (own as ir.SolidPaint).color, green);
    }
  });
}
