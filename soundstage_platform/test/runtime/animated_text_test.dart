import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

const Size _viewport = Size(800, 600);

const ir.Breakpoint _bp = ir.Breakpoint(
  id: 'only',
  name: 'Only',
  minWidth: 0,
  designSize: ir.StageSize(width: 800, height: 600),
);

const ir.StageColor _red = ir.StageColor(r: 1, g: 0, b: 0);
const ir.StageColor _blue = ir.StageColor(r: 0, g: 0, b: 1);

ir.Keyframe _kf(double t, ir.IrValue v) =>
    ir.Keyframe(id: 'k$t', t: t, value: v);

ir.Track _track(String property, String clock, ir.IrValue a, ir.IrValue b) =>
    ir.Track(
      id: property,
      target: 'title',
      property: property,
      clockId: clock,
      keyframes: [_kf(0, a), _kf(1, b)],
    );

/// A heading of two spans; span 1 overrides its own font size.
ir.StageDocument _doc(List<ir.Track> tracks) => ir.StageDocument(
  id: 'doc',
  breakpoints: const [_bp],
  baseBreakpointId: 'only',
  scenes: [
    ir.Scene(
      id: 's',
      kind: ir.SceneKind.pinned,
      root: const ir.FrameNode(
        common: ir.NodeCommon(id: 'root', width: 800, height: 600),
        children: [
          ir.TextNode(
            common: ir.NodeCommon(id: 'title'),
            // Colour tracks address a fill by id, so the node holds one.
            style: ir.TextStyleOverride(
              fontSize: 20,
              fills: [ir.Paint.solid(id: 'ink', color: ir.StageColor.black)],
            ),
            content: [
              ir.Paragraph(
                spans: [
                  ir.Span(text: 'Hello '),
                  ir.Span(
                    text: 'world',
                    style: ir.TextStyleOverride(fontSize: 10),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      clocks: const [
        ir.Clock.timeline(id: 'paint', duration: 1),
        ir.Clock.timeline(id: 'layout', duration: 1),
      ],
      tracks: tracks,
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  ir.StageDocument doc,
  Map<String, double> clocks,
) => tester.pumpWidget(
  Directionality(
    textDirection: TextDirection.ltr,
    child: StagePlayer(
      document: doc,
      mode: StageRenderMode.edit,
      viewportOverride: _viewport,
      clockOverrides: clocks,
      environment: const StageEnvironment(),
    ),
  ),
);

RenderStageText _title(WidgetTester tester) => tester
    .renderObjectList<RenderStageText>(find.byType(StageTextWidget))
    .single;

void main() {
  group('compile', () {
    TextStyleChannel? ch(String path) => TextStyleChannel.compile(
      CompiledTrack.compile(
        ir.Track(id: 't', target: 'x', property: path, clockId: 'c'),
      ),
    );

    test('fields, scopes and invalidation classes', () {
      final cases = <String, (TextStyleField, StageInvalidation)>{
        'style.fontSize': (TextStyleField.fontSize, StageInvalidation.layout),
        'style.fontWeight': (
          TextStyleField.fontWeight,
          StageInvalidation.layout,
        ),
        'style.letterSpacing': (
          TextStyleField.letterSpacing,
          StageInvalidation.layout,
        ),
        'style.lineHeight': (
          TextStyleField.lineHeight,
          StageInvalidation.layout,
        ),
        'style.fontVariations.wght': (
          TextStyleField.fontVariation,
          StageInvalidation.layout,
        ),
        'style.fills.ink.color': (
          TextStyleField.fillColor,
          StageInvalidation.paint,
        ),
        'style.fills.ink.opacity': (
          TextStyleField.fillOpacity,
          StageInvalidation.paint,
        ),
        'style.paragraphSpacing': (
          TextStyleField.paragraphSpacing,
          StageInvalidation.layout,
        ),
        'style.textCase': (TextStyleField.generic, StageInvalidation.layout),
        'style.decoration.color': (
          TextStyleField.generic,
          StageInvalidation.paint,
        ),
      };
      cases.forEach((path, expected) {
        final c = ch(path)!;
        expect((c.field, c.invalidation), expected, reason: path);
        expect(c.isNodeLevel, isTrue);
      });
      final span = ch('content.2.spans.3.style.fills.ink.color')!;
      expect((span.paragraph, span.span, span.key), (2, 3, 'ink'));
      expect(span.invalidation, StageInvalidation.paint);
      expect(ch('characters'), isNull);
      expect(ch('opacity'), isNull);
      expect(ch('content.0.spans.0.text'), isNull);
    });
  });

  group('apply', () {
    testWidgets('node-level tracks skip spans that override the field', (
      tester,
    ) async {
      final doc = _doc([
        _track(
          'style.fontSize',
          'layout',
          const ir.IrValue.number(20),
          const ir.IrValue.number(40),
        ),
        _track(
          'content.0.spans.1.style.letterSpacing',
          'layout',
          const ir.IrValue.letterSpacing(ir.LetterSpacing.px(0)),
          const ir.IrValue.letterSpacing(ir.LetterSpacing.px(8)),
        ),
      ]);
      await _pump(tester, doc, {'layout': 0.5});
      final spans = _title(tester).renderedParagraphs.single.spans;
      expect(spans[0].style.fontSize, 30);
      expect(spans[1].style.fontSize, 10, reason: 'the span overrides it');
      expect(spans[1].style.letterSpacing, const ir.LetterSpacing.px(4));
      expect(spans[0].style.letterSpacing, const ir.LetterSpacing.percent());
    });

    testWidgets('colour tracks match the oracle and only repaint', (
      tester,
    ) async {
      final colour = _track(
        'style.fills.ink.color',
        'paint',
        const ir.IrValue.color(_red),
        const ir.IrValue.color(_blue),
      );
      final spacing = _track(
        'style.letterSpacing',
        'layout',
        const ir.IrValue.letterSpacing(ir.LetterSpacing.percent(0)),
        const ir.IrValue.letterSpacing(ir.LetterSpacing.percent(20)),
      );
      final doc = _doc([colour, spacing]);
      await _pump(tester, doc, {'paint': 0, 'layout': 0});
      final title = _title(tester);
      expect(title.animatedChannelCount, 2);
      final width0 = title.size.width;

      RenderStageBox.debugLayoutCount = 0;
      RenderStageBox.debugPaintCount = 0;
      await _pump(tester, doc, {'paint': 0.5, 'layout': 0});
      expect(RenderStageBox.debugLayoutCount, 0, reason: 'colour: paint only');
      expect(RenderStageBox.debugPaintCount, greaterThan(0));
      final fill =
          title.renderedParagraphs.single.spans.first.style.fills.single
              as ir.SolidPaint;
      final oracle = (ir.evaluateTrack(colour, 0.5)! as ir.ColorValue).value;
      expect(fill.color.r, closeTo(oracle.r, 1e-9));
      expect(fill.color.g, closeTo(oracle.g, 1e-9));
      expect(fill.color.b, closeTo(oracle.b, 1e-9));
      // The painted span carries the colour.
      final painted =
          (title.textLayout.visiblePainters.single.text! as TextSpan)
                  .children!
                  .first
              as TextSpan;
      expect(painted.style!.color!.b, closeTo(oracle.b, 1e-6));

      RenderStageBox.debugLayoutCount = 0;
      await _pump(tester, doc, {'paint': 0.5, 'layout': 1});
      expect(
        RenderStageBox.debugLayoutCount,
        greaterThan(0),
        reason: 'letter spacing relayouts',
      );
      expect(title.size.width, greaterThan(width0));
    });

    testWidgets('unchanged paragraphs keep their painters', (tester) async {
      final doc =
          _doc([
            ir.Track(
              id: 'p1',
              target: 'title',
              property: 'content.1.spans.0.style.fontSize',
              clockId: 'layout',
              keyframes: [
                _kf(0, const ir.IrValue.number(10)),
                _kf(1, const ir.IrValue.number(30)),
              ],
            ),
          ]).let((d) {
            final scene = d.scenes.single;
            final root = scene.root;
            final title = root.children.single as ir.TextNode;
            return d.copyWith(
              scenes: [
                scene.copyWith(
                  root: root.copyWith(
                    children: [
                      title.copyWith(
                        content: [
                          ...title.content,
                          const ir.Paragraph(spans: [ir.Span(text: 'second')]),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          });
      await _pump(tester, doc, {'layout': 0});
      final title = _title(tester);
      final first = title.textLayout.visiblePainters.first;
      final second = title.textLayout.visiblePainters.last;
      await _pump(tester, doc, {'layout': 1});
      expect(identical(title.textLayout.visiblePainters.first, first), isTrue);
      expect(identical(title.textLayout.visiblePainters.last, second), isFalse);
      expect(title.renderedParagraphs.last.spans.single.style.fontSize, 30);
    });

    testWidgets('discrete tracks apply through the registry', (tester) async {
      final doc = _doc([
        ir.Track(
          id: 'case',
          target: 'title',
          property: 'style.textCase',
          clockId: 'layout',
          keyframes: [
            _kf(0, const ir.IrValue.enumValue('none')),
            _kf(1, const ir.IrValue.enumValue('upper')),
          ],
        ),
      ]);
      await _pump(tester, doc, {'layout': 1});
      expect(
        _title(tester).textLayout.visiblePainters.single.plainText,
        'HELLO WORLD',
      );
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
