import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

// Reference values were read independently with fontTools 4.x
// (`TTFont(path)['OS/2']`, `['head'].unitsPerEm`) from the bundled files.
Uint8List _font(String name) =>
    File('assets/demo/fonts/$name').readAsBytesSync();

const ir.FontFamily _fraunces = ir.FontFamily(
  id: 'serif',
  name: 'Fraunces',
  fallback: ir.FontFallback.serif,
  faces: [
    ir.FontFace(
      assetId: 'fraunces',
      weight: 400,
      variable: true,
      axes: [
        ir.FontAxis(tag: 'opsz', min: 9, max: 144, defaultValue: 9),
        ir.FontAxis(tag: 'wght', min: 100, max: 900, defaultValue: 900),
      ],
    ),
  ],
);

const Map<String, ir.Asset> _assets = {
  'fraunces': ir.Asset(
    id: 'fraunces',
    kind: ir.AssetKind.font,
    uri: 'asset://assets/demo/fonts/Fraunces-Variable.ttf',
  ),
  'grotesk': ir.Asset(
    id: 'grotesk',
    kind: ir.AssetKind.font,
    uri: 'asset://assets/demo/fonts/SpaceGrotesk-Variable.ttf',
  ),
};

/// A table whose bytes come from disk and whose registration is recorded.
(StageFontTable, List<String>) _table(
  Map<String, ir.FontFamily> families, {
  bool realRegistrar = false,
}) {
  final registered = <String>[];
  final t = StageFontTable(
    families,
    _assets,
    (asset) async => _font(asset.uri.split('/').last),
    (name, bytes) async {
      registered.add(name);
      if (realRegistrar) await registerFontWithFontLoader(name, bytes);
    },
    // Widget tests load explicitly in runAsync (not in the fake-async zone).
    !realRegistrar,
  );
  return (t, registered);
}

void main() {
  group('OS/2 metrics', () {
    test('Fraunces (variable serif)', () {
      final r = parseFontMetrics(_font('Fraunces-Variable.ttf'));
      expect(r.problem, isNull);
      final m = r.metrics!;
      expect(m.unitsPerEm, 2000);
      expect(m.os2Version, 4);
      expect(m.capHeight, 1400);
      expect(m.xHeight, 964);
      expect((m.typoAscender, m.typoDescender), (1956, -510));
      expect((m.winAscent, m.winDescent), (2340, 609));
      expect(m.capHeightEm, 0.7);
    });

    test('Space Grotesk (variable sans)', () {
      final m = parseFontMetrics(_font('SpaceGrotesk-Variable.ttf')).metrics!;
      expect(m.unitsPerEm, 1000);
      expect(m.os2Version, 4);
      expect(m.capHeight, 700);
      expect(m.xHeight, 486);
      expect((m.typoAscender, m.typoDescender), (984, -292));
      expect((m.winAscent, m.winDescent), (1150, 292));
    });

    test('OS/2 before v2 has no cap height', () {
      final bytes = Uint8List.fromList(_font('SpaceGrotesk-Variable.ttf'));
      final d = ByteData.sublistView(bytes);
      for (var i = 0; i < d.getUint16(4); i++) {
        final r = 12 + i * 16;
        if (d.getUint32(r) == 0x4F532F32) {
          d.setUint16(d.getUint32(r + 8), 1);
        }
      }
      final r = parseFontMetrics(bytes);
      expect(r.metrics!.capHeight, isNull);
      expect(r.metrics!.capHeightEm, isNull);
      expect(r.problem, contains('v2+'));
    });

    test('unsupported and malformed input never throws', () {
      expect(parseFontMetrics(Uint8List(3)).problem, isNotNull);
      expect(
        parseFontMetrics(
          Uint8List.fromList('wOF2xxxxxxxxxxxx'.codeUnits),
        ).problem,
        contains('WOFF'),
      );
      final cut = _font('Fraunces-Variable.ttf').sublist(0, 300);
      final r = parseFontMetrics(cut);
      expect(r.metrics, isNull);
      expect(r.problem, isNotNull);
    });
  });

  group('font table', () {
    test('faces register under stable, collision-free names', () async {
      final (a, regA) = _table({'serif': _fraunces});
      expect(a.faceFor('serif', 400, false), isNull, reason: 'not loaded');
      expect(a.familyName('serif'), 'serif', reason: 'generic fallback');
      await a.ensureLoaded(['serif']);
      final face = a.faceFor('serif', 400, false)!;
      expect(face.name, matches(RegExp(r'^ss-serif-[0-9a-f]{8}-0$')));
      expect(face.metrics!.capHeight, 1400);
      expect(regA, [face.name]);

      // The same family in another table: the same name, not re-registered.
      final (b, regB) = _table({'serif': _fraunces});
      await b.ensureLoaded(['serif']);
      expect(b.faceFor('serif', 400, false)!.name, face.name);
      expect(regB, isEmpty);

      // Same id, other files: another name.
      final other = _fraunces.copyWith(
        faces: [const ir.FontFace(assetId: 'grotesk')],
      );
      final (c, _) = _table({'serif': other});
      await c.ensureLoaded(['serif']);
      expect(c.faceFor('serif', 400, false)!.name, isNot(face.name));
    });

    test('missing assets are diagnostics, and the fallback stays', () async {
      final (t, _) = _table({
        'x': const ir.FontFamily(
          id: 'x',
          name: 'X',
          faces: [ir.FontFace(assetId: 'nope')],
        ),
      });
      await t.ensureLoaded(['x', 'unknown']);
      expect(t.isLoaded('x'), isFalse);
      expect(t.faceFor('x', 400, false), isNull);
      expect(t.diagnostics.single.message, contains('nope'));
    });

    test('CSS weight and style matching across faces', () {
      StageFontFace f(int w, {bool italic = false, (double, double)? range}) =>
          StageFontFace(
            name: '$w${italic ? 'i' : ''}',
            face: ir.FontFace(
              assetId: 'a',
              weight: w,
              italic: italic,
              variable: range != null,
              axes: range == null
                  ? const []
                  : [
                      ir.FontAxis(
                        tag: 'wght',
                        min: range.$1,
                        max: range.$2,
                        defaultValue: w.toDouble(),
                      ),
                    ],
            ),
          );
      final faces = [f(300), f(400), f(600), f(800), f(400, italic: true)];
      String pick(int w, [bool i = false]) => pickFace(faces, w, i)!.name;
      expect(pick(400), '400');
      expect(
        pick(500),
        '400',
        reason: '400–500: heavier up to 500, then lighter, then heavier',
      );
      expect(pickFace([f(300), f(500), f(600)], 450, false)!.name, '500');
      expect(pick(450), '400');
      expect(pick(350), '300', reason: 'below 400 looks lighter first');
      expect(pick(200), '300', reason: 'then heavier');
      expect(pick(700), '800', reason: 'above 500 looks heavier first');
      expect(pick(900), '800', reason: 'then lighter');
      expect(pick(700, true), '400i', reason: 'style wins over weight');
      final variable = [f(400, range: (100, 900)), f(700)];
      expect(pickFace(variable, 650, false)!.name, '400');
    });

    test('variable faces get wght, opsz and slant automatically', () {
      final face = StageFontFace(name: 'v', face: _fraunces.faces.single);
      expect(
        fontVariationsFor(
          const ir.TextStyle(fontWeight: 350, fontSize: 200),
          face,
        ),
        [const FontVariation('wght', 350), const FontVariation('opsz', 144)],
      );
      expect(
        fontVariationsFor(
          const ir.TextStyle(fontVariations: {'wght': 600}, fontSize: 12),
          face,
        ),
        [const FontVariation('wght', 600), const FontVariation('opsz', 12)],
        reason: 'explicit axes win',
      );
      expect(fontVariationsFor(const ir.TextStyle(), null), isEmpty);
    });
  });

  group('render', () {
    ir.ResolvedDocument resolvedOf(ir.StageDocument doc) =>
        ir.resolveDocument(doc, const ir.ResolveContext(viewportWidth: 1440));

    ir.StageDocument doc({ir.LeadingTrim trim = ir.LeadingTrim.none}) =>
        docWithRoot(
          frame(
            'root',
            common('root', w: 1440, h: 900),
            children: [
              ir.TextNode(
                common: common('serifText'),
                leadingTrim: trim,
                style: const ir.TextStyleOverride(
                  fontFamilyId: 'display',
                  fontSize: 100,
                  lineHeight: ir.LineHeight.percent(150),
                ),
                content: const [
                  ir.Paragraph(spans: [ir.Span(text: 'HHxx')]),
                ],
              ),
              textNode('plain', text: 'plain', fontSize: 20),
            ],
          ),
        ).copyWith(
          // Its own id: the font-table tests registered 'serif' with a fake.
          fonts: {'display': _fraunces.copyWith(id: 'display')},
          assets: _assets,
        );

    Future<StageFontTable> pump(WidgetTester tester, ir.StageDocument d) async {
      final (fonts, _) = _table(d.fonts, realRegistrar: true);
      final resolved = resolvedOf(d);
      setViewport(tester, const Size(1440, 900));
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StageScope(
            environment: StageEnvironment(fonts: fonts),
            child: StageSceneView(
              scene: resolved.scenes.first,
              viewportSize: const Size(1440, 900),
              breakpoint: resolved.breakpoint,
            ),
          ),
        ),
      );
      return fonts;
    }

    testWidgets('text renders in the fallback, then relayouts on load', (
      tester,
    ) async {
      final fonts = await pump(tester, doc());
      final serif = stageBox(tester, 'serifText') as RenderStageText;
      final plain = stageBox(tester, 'plain') as RenderStageText;
      final before = serif.size;
      TextStyle firstStyle() =>
          ((serif.textLayout.visiblePainters.first.text! as TextSpan)
                      .children!
                      .first
                  as TextSpan)
              .style!;
      expect(firstStyle().fontFamily, 'serif');
      final plainLayout = plain.textLayout;

      await tester.runAsync(() => fonts.ensureLoaded(['display']));
      await tester.pump();
      expect(firstStyle().fontFamily, startsWith('ss-display-'));
      expect(
        firstStyle().fontVariations,
        contains(const FontVariation('wght', 400)),
      );
      expect(serif.size, isNot(before), reason: 'relaid out in Fraunces');
      expect(
        identical(plain.textLayout, plainLayout),
        isTrue,
        reason: 'text that does not use the family keeps its layout',
      );
    });

    testWidgets('leadingTrim: capHeight trims to cap height and baseline', (
      tester,
    ) async {
      final fonts = await pump(tester, doc(trim: ir.LeadingTrim.capHeight));
      final serif = stageBox(tester, 'serifText') as RenderStageText;
      // Before load: no metrics, no trim.
      expect(serif.textLayout.leadingTrimTop, 0);
      await tester.runAsync(() => fonts.ensureLoaded(['display']));
      await tester.pump();
      // The first baseline sits exactly one cap height (0.7 em) below the
      // top, and the box ends at the last baseline.
      expect(serif.firstBaseline, closeTo(70, 0.01));
      expect(serif.size.height, closeTo(70, 0.01));
      expect(fonts.diagnostics, isEmpty);
    });

    testWidgets('leadingTrim without font metrics is a diagnostic', (
      tester,
    ) async {
      final d = doc(trim: ir.LeadingTrim.capHeight).copyWith(fonts: {});
      final fonts = await pump(tester, d);
      final serif = stageBox(tester, 'serifText') as RenderStageText;
      expect(serif.textLayout.leadingTrimTop, 0);
      expect(fonts.diagnostics.single.message, contains('leadingTrim'));
    });
  });
}
