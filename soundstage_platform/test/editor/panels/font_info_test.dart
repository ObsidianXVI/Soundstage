import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/panels/font_info.dart';

import 'font_fixtures.dart';

void main() {
  group('parseFontInfo', () {
    test('reads family, style, weight and slant from name and OS/2', () {
      final r = parseFontInfo(
        buildFont(
          family: 'Test Sans',
          style: 'Bold Italic',
          weight: 700,
          italic: true,
        ),
      );
      expect(r.problem, isNull);
      final f = r.info!;
      expect(f.familyName, 'Test Sans');
      expect(f.styleName, 'Bold Italic');
      expect(f.weight, 700);
      expect(f.italic, isTrue);
      expect(f.variable, isFalse);
      expect(f.format, FontFormat.ttf);
      expect(f.mime, 'font/ttf');
    });

    test('prefers the typographic family (ID 16) so weights group', () {
      final r = parseFontInfo(
        buildFont(
          family: 'Test Sans Light',
          typographicFamily: 'Test Sans',
          style: 'Light',
          weight: 300,
        ),
      );
      expect(r.info!.familyName, 'Test Sans');
      expect(r.info!.weight, 300);
    });

    test('lists the axes of a variable font and takes wght as the weight', () {
      final r = parseFontInfo(
        buildFont(
          family: 'Var Sans',
          weight: 400,
          axes: [
            (tag: 'wght', min: 100, def: 350, max: 900),
            (tag: 'wdth', min: 75, def: 100, max: 125),
          ],
        ),
      );
      final f = r.info!;
      expect(f.variable, isTrue);
      expect([for (final a in f.axes) a.tag], ['wght', 'wdth']);
      expect(f.axes.first.min, 100);
      expect(f.axes.first.max, 900);
      expect(f.axes.first.defaultValue, 350);
      expect(f.weight, 350);
      expect(f.face('asset1').variable, isTrue);
    });

    test('a CFF font is OTF', () {
      final r = parseFontInfo(buildFont(cff: true));
      expect(r.info!.cff, isTrue);
      expect(r.info!.mime, 'font/otf');
    });

    test('unpacks WOFF to the same font', () {
      final ttf = buildFont(family: 'Wof Sans', weight: 600);
      final r = parseFontInfo(toWoff(ttf));
      expect(r.problem, isNull);
      expect(r.info!.format, FontFormat.woff);
      expect(r.info!.familyName, 'Wof Sans');
      expect(r.info!.weight, 600);
      // The stored bytes are plain sfnt that parses on their own.
      expect(sniffFontFormat(r.info!.sfnt), FontFormat.ttf);
      expect(parseFontInfo(r.info!.sfnt).info!.familyName, 'Wof Sans');
    });

    test('rejects WOFF2 with a way forward', () {
      final b = Uint8List(64)..buffer.asByteData().setUint32(0, 0x774F4632);
      final r = parseFontInfo(b);
      expect(r.info, isNull);
      expect(r.problem, contains('WOFF2'));
      expect(r.problem, contains('Convert'));
    });

    test('rejects collections, non-fonts and damaged files', () {
      final ttc = Uint8List(64)..buffer.asByteData().setUint32(0, 0x74746366);
      expect(parseFontInfo(ttc).problem, contains('collections'));
      expect(
        parseFontInfo(Uint8List.fromList(List.filled(40, 7))).problem,
        contains('not a font'),
      );
      final cut = buildFont().sublist(0, 60);
      expect(parseFontInfo(cut).info, isNull);
      expect(parseFontInfo(Uint8List(3)).info, isNull);
    });
  });
}
