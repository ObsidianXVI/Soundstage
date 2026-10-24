import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/inspector/property_writer.dart';
import 'package:soundstage_platform/editor/inspector/sections/paint_stack.dart';
import 'package:soundstage_platform/editor/inspector/sections/text_section.dart';
import 'package:soundstage_platform/editor/text/text_edit_controller.dart';
import 'package:soundstage_platform/editor/text/text_edit_session.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

/// t: "Hello big" / "world" ("big" is 24 px), with a named style; u: plain.
ir.StageDocument _doc() =>
    inspectorDoc([
      const ir.TextNode(
        common: ir.NodeCommon(id: 't', name: 't', width: 200, height: 40),
        style: ir.TextStyleOverride(fontSize: 16),
        autoResize: ir.TextAutoResize.height,
        content: [
          ir.Paragraph(
            spans: [
              ir.Span(text: 'Hello '),
              ir.Span(text: 'big', style: ir.TextStyleOverride(fontSize: 24)),
            ],
          ),
          ir.Paragraph(spans: [ir.Span(text: 'world')]),
        ],
      ),
      const ir.TextNode(
        common: ir.NodeCommon(
          id: 'u',
          name: 'u',
          y: 100,
          width: 200,
          height: 40,
        ),
        textStyleId: 'body',
        content: [
          ir.Paragraph(spans: [ir.Span(text: 'Plain')]),
        ],
      ),
    ]).copyWith(
      tokens: const ir.TokenSystem(
        textStyles: {
          'body': ir.TextStyleDef(
            name: 'Body',
            style: ir.TextStyleOverride(fontSize: 18, fontWeight: 500),
          ),
        },
      ),
      fonts: {
        'serif': const ir.FontFamily(
          id: 'serif',
          name: 'Serif',
          faces: [
            ir.FontFace(assetId: 'a1', weight: 400),
            ir.FontFace(assetId: 'a2', weight: 700),
          ],
        ),
        'var': const ir.FontFamily(
          id: 'var',
          name: 'Variable',
          faces: [
            ir.FontFace(
              assetId: 'a3',
              variable: true,
              axes: [
                ir.FontAxis(tag: 'wght', min: 100, max: 900, defaultValue: 400),
              ],
            ),
          ],
        ),
      },
    );

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Set<String> select = const {'t'},
}) => pumpInspector(tester, _doc(), select: select, height: 4000);

ir.TextNode _t(ProviderContainer c, [String id = 't']) =>
    nodeOf(c, id) as ir.TextNode;

SsNumberField _num(WidgetTester tester, String path) =>
    tester.widget<SsNumberField>(find.byKey(ValueKey<String>('field:$path')));

Finder _seg(String key, String label) => find.descendant(
  of: find.byKey(ValueKey<String>(key)),
  matching: find.text(label),
);

/// Starts an edit session on t with [selection].
TextEditSession _edit(ProviderContainer c, TextSelection selection) {
  final ctl = c.read(editorControllerProvider.notifier);
  ctl.applySelection(const SelectionState(selection: {'t'}, textEditId: 't'));
  final s = TextEditSession(
    controller: ctl,
    readState: () => c.read(editorControllerProvider),
    nodeId: 't',
    breakpointId: 'desktop',
    view: _NoView(),
    selection: selection,
  );
  c.read(textEditProvider).setSession(s);
  addTearDown(() {
    c.read(textEditProvider).setSession(null);
    s.dispose();
  });
  return s;
}

class _NoView implements TextEditView {
  @override
  int? offsetAt(Offset local) => null;
  @override
  Rect? caretRect(int offset, {bool upstream = false}) => null;
  @override
  (int, int)? lineBoundary(int offset, {bool upstream = false}) => null;
}

Finder _icon(String key, IconData icon) => find.descendant(
  of: find.byKey(ValueKey<String>(key)),
  matching: find.byWidgetPredicate((w) => w is SsIcon && w.icon == icon),
);

Future<void> _pick(WidgetTester tester, String key, String label) async {
  await tester.tap(find.byKey(ValueKey<String>(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('outside edit mode: reads the whole text (Mixed across spans), '
      'writes the node style and clears span overrides', (tester) async {
    final c = await _pump(tester);
    expect(find.byType(TextSectionBody), findsOneWidget);
    expect(_num(tester, 'style.fontSize').mixed, isTrue);
    await typeInto(tester, 'style.fontSize', '20');
    final t = _t(c);
    expect(t.style.fontSize, 20);
    expect(t.content.first.spans.single.text, 'Hello big'); // merged back
    expect(_num(tester, 'style.fontSize').mixed, isFalse);
    expect(_num(tester, 'style.fontSize').value, 20);
  });

  testWidgets('in edit mode: reads and writes the selected spans', (
    tester,
  ) async {
    final c = await _pump(tester);
    _edit(c, const TextSelection(baseOffset: 0, extentOffset: 5));
    await tester.pump();
    expect(find.byKey(const ValueKey('text-editing-hint')), findsOneWidget);
    expect(_num(tester, 'style.fontSize').mixed, isFalse);
    expect(_num(tester, 'style.fontSize').value, 16);
    await typeInto(tester, 'style.fontSize', '30');
    final t = _t(c);
    expect(t.style.fontSize, 16); // the node style is untouched
    expect(t.content.first.spans.map((s) => s.text), ['Hello', ' ', 'big']);
    expect(t.content.first.spans.first.style.fontSize, 30);
    expect(c.read(editorControllerProvider).textEditId, 't');
  });

  testWidgets('in edit mode a collapsed caret sets the typing style', (
    tester,
  ) async {
    final c = await _pump(tester);
    final s = _edit(c, const TextSelection.collapsed(offset: 3));
    await tester.pump();
    final before = c.read(editorControllerProvider).document;
    await typeInto(tester, 'style.fontSize', '40');
    expect(
      identical(c.read(editorControllerProvider).document, before),
      isTrue,
    );
    expect(s.pendingStyle, {'fontSize': const ir.IrValue.number(40)});
    expect(_num(tester, 'style.fontSize').value, 40);
  });

  testWidgets('paragraph fields: alignment, spacing, indent, list', (
    tester,
  ) async {
    final c = await _pump(tester);
    await tester.tap(_icon('field:alignHorizontal', SsIcons.alignCenter));
    await tester.pump();
    expect(_t(c).alignHorizontal, ir.TextAlignHorizontal.center);
    await typeInto(tester, 'style.paragraphSpacing', '12');
    expect(_t(c).style.paragraphSpacing, 12);
    // In edit mode: only the paragraphs the selection touches.
    _edit(c, const TextSelection.collapsed(offset: 12));
    await tester.pump();
    await typeInto(tester, 'style.paragraphIndent', '8');
    expect(_t(c).content[1].style?.paragraphIndent, 8);
    expect(_t(c).content[0].style?.paragraphIndent, isNull);
    await tester.tap(_icon('field:style.listStyle', SsIcons.listOrdered));
    await tester.pump();
    expect(_t(c).content[1].style?.listStyle, ir.ListStyle.ordered);
  });

  testWidgets('font family and weights (named and variable)', (tester) async {
    final c = await _pump(tester);
    await _pick(tester, 'field:style.fontFamilyId', 'Serif');
    expect(_t(c).style.fontFamilyId, 'serif');
    // Static faces: the family's weights.
    await _pick(tester, 'field:style.fontWeight', 'Bold');
    expect(_t(c).style.fontWeight, 700);
    await _pick(tester, 'field:style.fontFamilyId', 'Variable (variable)');
    expect(
      tester.widget(find.byKey(const ValueKey('field:style.fontWeight'))),
      isA<SsNumberField>(),
    );
    expect(_num(tester, 'style.fontWeight').max, 900);
    await typeInto(tester, 'style.fontWeight', '650');
    expect(_t(c).style.fontWeight, 650);
    await _pick(tester, 'field:style.fontFamilyId', 'Default (sans)');
    expect(_t(c).style.fontFamilyId, isNull);
  });

  testWidgets('line height and letter spacing units', (tester) async {
    final c = await _pump(tester);
    expect(_num(tester, 'style.lineHeight').value, isNull); // auto
    await _pick(tester, 'field:style.lineHeight:unit', '%');
    expect(_t(c).style.lineHeight, const ir.LineHeight.percent(120));
    await typeInto(tester, 'style.lineHeight', '150');
    expect(_t(c).style.lineHeight, const ir.LineHeight.percent(150));
    await _pick(tester, 'field:style.letterSpacing:unit', 'px');
    expect(_t(c).style.letterSpacing, const ir.LetterSpacing.px(0));
    await typeInto(tester, 'style.letterSpacing', '2');
    expect(_t(c).style.letterSpacing, const ir.LetterSpacing.px(2));
  });

  testWidgets('style toggles, decoration details, case, baseline, OpenType', (
    tester,
  ) async {
    final c = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('field:style.italic')));
    await tester.pump();
    expect(_t(c).style.italic, isTrue);
    expect(
      find.byKey(const ValueKey('field:style.decoration.style')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey('field:style.decoration.kind:underline')),
    );
    await tester.pump();
    expect(_t(c).style.decoration?.kind, ir.TextDecorationKind.underline);
    await _pick(tester, 'field:style.decoration.style', 'Wavy');
    expect(_t(c).style.decoration?.style, ir.TextDecorationStyle.wavy);
    await typeInto(tester, 'style.decoration.thickness', '2');
    expect(_t(c).style.decoration?.thickness, 2);
    await _pick(tester, 'field:style.textCase', 'UPPERCASE');
    expect(_t(c).style.textCase, ir.TextCase.upper);
    await tester.tap(_seg('field:leadingTrim', 'Cap height'));
    await tester.pump();
    expect(_t(c).leadingTrim, ir.LeadingTrim.capHeight);
    await tester.tap(find.byKey(const ValueKey('field:style.openType.tnum')));
    await tester.pump();
    expect(_t(c).style.openType, {'tnum': 1});
    await tester.tap(find.byKey(const ValueKey('field:style.openType.liga')));
    await tester.pump();
    expect(_t(c).style.openType!['liga'], 0);
    await tester.tap(_icon('field:style.baselineShift', SsIcons.superscript));
    await tester.pump();
    expect(_t(c).style.baselineShift, ir.BaselineShift.superscript);
  });

  testWidgets('box: auto-resize, max lines, ellipsis, vertical alignment', (
    tester,
  ) async {
    final c = await _pump(tester);
    await tester.tap(_icon('field:autoResize', SsIcons.ellipsis));
    await tester.pump();
    expect(_t(c).autoResize, ir.TextAutoResize.truncate);
    await typeInto(tester, 'maxLines', '2');
    expect(_t(c).maxLines, 2);
    await tester.tap(find.byKey(const ValueKey('field:maxLines:clear')));
    await tester.pump();
    expect(_t(c).maxLines, isNull);
    await tester.tap(find.byKey(const ValueKey('field:truncation')));
    await tester.pump();
    expect(_t(c).truncation, ir.TextTruncation.ending);
    await tester.tap(
      _icon('field:alignVertical', SsIcons.alignVerticalJustifyEnd),
    );
    await tester.pump();
    expect(_t(c).alignVertical, ir.TextAlignVertical.bottom);
  });

  testWidgets('named text style: shown, Mixed, detach keeps its values', (
    tester,
  ) async {
    final c = await _pump(tester, select: {'u'});
    expect(find.text('Style: Body'), findsOneWidget);
    await tester.tap(find.text('Detach'));
    await tester.pump();
    final u = _t(c, 'u');
    expect(u.textStyleId, isNull);
    expect(u.style.fontSize, 18);
    expect(u.style.fontWeight, 500);
    c.read(editorControllerProvider.notifier).undo();
    c.read(editorControllerProvider.notifier).select({'t', 'u'});
    await tester.pump();
    expect(find.byKey(const ValueKey('text-style-mixed')), findsOneWidget);
  });

  testWidgets('text fills reuse the paint stack, per span in edit mode', (
    tester,
  ) async {
    final c = await _pump(tester);
    final stacks = tester
        .widgetList<PaintStackEditor>(find.byType(PaintStackEditor))
        .where((e) => e.stackPath == 'style.fills');
    expect(stacks, hasLength(1));
    _edit(c, const TextSelection(baseOffset: 6, extentOffset: 9));
    await tester.pump();
    final w = tester.widget<SsNumberField>(
      find.byKey(const ValueKey('field:style.fontSize')),
    );
    expect(w.value, 24);
    // A paint field write (as the stack's colour field does) targets the
    // selected span only, copying its effective fills.
    final writer = InspectorScope.of(
      tester.element(
        find.byWidgetPredicate(
          (w) => w is PaintStackEditor && w.stackPath == 'style.fills',
        ),
      ),
    ).writer;
    writer.set(
      'style.fills.text.color',
      const ir.IrValue.color(ir.StageColor(r: 1, g: 0, b: 0)),
    );
    await tester.pump();
    final spans = _t(c).content.first.spans;
    expect(spans.last.text, 'big');
    expect(
      (spans.last.style.fills!.single as ir.SolidPaint).color,
      const ir.StageColor(r: 1, g: 0, b: 0),
    );
    expect(spans.first.style.fills, isNull);
  });
}
