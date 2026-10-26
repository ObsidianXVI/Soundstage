import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/export/export.dart';

LinearStory _story() => const LinearStory(
  title: "Night's walk",
  scenes: [
    LinearScene(
      id: 's1',
      name: 'One',
      blocks: [
        HeadingBlock(1, [InlineRun('Arrival')]),
        HeadingBlock(4, [InlineRun('Small')]),
        ParagraphBlock([InlineRun(r'Plain $5 \ text')]),
        ParagraphBlock([
          InlineRun('Mixed '),
          InlineRun('bold', bold: true),
          InlineRun(' and '),
          InlineRun('a link', href: 'https://x.test/'),
          InlineRun(' and '),
          InlineRun('a scene', href: '#scene-s2'),
        ]),
        ParagraphBlock([InlineRun('first')], list: ListKind.unordered),
        ParagraphBlock([InlineRun('second')], list: ListKind.unordered),
        ParagraphBlock([InlineRun('one')], list: ListKind.ordered),
        QuoteBlock([
          [InlineRun('To be')],
          [InlineRun('or not')],
        ]),
        FigureBlock(
          nodeId: 'n',
          sceneId: 's1',
          assetId: 'img',
          caption: [InlineRun('A caption')],
          width: 1200,
          height: 600,
        ),
        TranscriptBlock(['la', 'la la']),
        AudioBlock(assetId: 'snd', name: 'Theme'),
      ],
    ),
    LinearScene(
      id: 's2',
      name: 'Two',
      isPoster: true,
      blocks: [PosterBlock(sceneId: 's2', clock: 0.5, alt: 'Two')],
    ),
  ],
);

void main() {
  test('class names and Dart strings', () {
    expect(letterpressClassName('My first story!'), 'MyFirstStory');
    expect(letterpressClassName('2 cities'), 'Story2Cities');
    expect(letterpressClassName('???'), 'SoundstageStory');
    expect(dartString("it's \$5 \\ \n"), r"'it\'s \$5 \\ \n'");
  });

  test('a story as an LPModule', () {
    final src = toLetterpressModule(
      _story(),
      className: 'NightsWalk',
      projectName: 'soundstage',
      date: DateTime(2026, 10, 26),
      assetPathOf: (key) => switch (key) {
        'img' => 'assets/images/soundstage/n/img.png',
        'scene-s2' => 'assets/images/soundstage/n/scene-s2.png',
        _ => null,
      },
      sizeOf: (key) => key == 'scene-s2' ? (width: 1600, height: 900) : null,
    );
    expect(src, startsWith('part of letterpress.store;'));
    expect(src, contains('class NightsWalk extends LPModule'));
    expect(src, contains("title: 'Night\\'s walk'"));
    expect(src, contains('lastUpdate: DateTime(2026, 10, 26)'));
    expect(src, contains("projectName: 'soundstage'"));
    expect(src, contains("LPText.header1(content: 'Arrival')"));
    expect(src, contains("LPText.header3(content: 'Small')"));
    expect(src, contains(r"LPText.plainBody(content: 'Plain \$5 \\ text')"));
    expect(src, contains('LPTextSpan('));
    expect(src, contains("LPText.plainBody(content: 'bold', isBold: true)"));
    expect(
      src,
      contains("LPText.hyperlink(content: 'a link', url: 'https://x.test/')"),
    );
    // Without a backlink a scene link is plain text.
    expect(src, contains("LPText.plainBody(content: 'a scene')"));
    expect(src, contains('listType: LPListType.bullet'));
    expect(src, contains('listType: LPListType.numbered'));
    expect(src, contains(r"LPPullQuote(content: 'To be\nor not')"));
    // Wide figures are scaled to 600 px, keeping their ratio.
    expect(
      src,
      contains(
        "LPImage.asset(assetPath: 'assets/images/soundstage/n/img.png', "
        'width: 600, height: 300)',
      ),
    );
    expect(
      src,
      contains("LPText.plainBody(content: 'A caption', isItalic: true)"),
    );
    expect(src, contains('width: 600, height: 337.5'));
    expect(src, contains(r"LPPullQuote(content: 'la\nla la')"));
    expect(src, contains("'Audio: Theme', isItalic: true"));
    expect(src, isNot(contains('View interactive article')));
  });

  test('with a backlink, scene links and posters point at the story', () {
    final src = toLetterpressModule(
      _story(),
      className: 'N',
      projectName: 'soundstage',
      date: DateTime(2026),
      backlink: const Backlink('https://site/s/n'),
    );
    expect(
      src,
      contains(
        "LPText.hyperlink(content: 'a scene', url: 'https://site/s/n#scene-s2')",
      ),
    );
    expect(
      src,
      contains(
        "LPText.hyperlink(content: 'View interactive article on Soundstage', "
        "url: 'https://site/s/n')",
      ),
    );
  });

  test('paste HTML is a bare fragment', () {
    final html = toPasteHtml(
      _story(),
      pathOf: (k) => k == 'img' ? 'https://cdn/img.png' : null,
    );
    expect(html, startsWith("<h1>Night's walk</h1>"));
    expect(html, isNot(contains('<style')));
    expect(html, isNot(contains('<section')));
    expect(html, isNot(contains('<audio')));
    expect(html, contains('<p><em>Audio: Theme</em></p>'));
    expect(html, contains('<img src="https://cdn/img.png"'));
    expect(html, contains('<strong>bold</strong>'));
  });

  group('image sizes', () {
    test('PNG', () {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
      );
      expect(imageSizeOf(png), (width: 1, height: 1));
    });

    test('GIF', () {
      final gif = Uint8List.fromList([
        ...'GIF89a'.codeUnits,
        0x40, 0x01, 0xF0, 0x00, // 320 × 240
      ]);
      expect(imageSizeOf(gif), (width: 320, height: 240));
    });

    test('JPEG start of frame after an APP0 segment', () {
      final jpeg = Uint8List.fromList([
        0xFF, 0xD8, //
        0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00, // APP0, length 4
        0xFF, 0xC0, 0x00, 0x11, 0x08, // SOF0, length, precision
        0x01, 0xE0, // height 480
        0x02, 0x80, // width 640
        0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]);
      expect(imageSizeOf(jpeg), (width: 640, height: 480));
    });

    test('WebP VP8X', () {
      final webp = Uint8List(30);
      webp.setAll(0, 'RIFF'.codeUnits);
      webp.setAll(8, 'WEBPVP8X'.codeUnits);
      webp.setAll(24, [0x7F, 0x02, 0x00]); // width - 1 = 639
      webp.setAll(27, [0xDF, 0x01, 0x00]); // height - 1 = 479
      expect(imageSizeOf(webp), (width: 640, height: 480));
    });

    test('unknown bytes', () {
      expect(imageSizeOf(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });
}
