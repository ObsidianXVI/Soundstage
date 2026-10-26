import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/export/pdf_export.dart';
import 'package:soundstage_platform/app/export/static_export.dart';
import 'package:soundstage_platform/export/export.dart';
import 'package:soundstage_platform/ir/ir.dart';

/// A 1×1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

StageDocument _doc() => const StageDocument(
  id: 'd',
  meta: StageMeta(title: 'Zipped story'),
  breakpoints: [
    Breakpoint(
      id: 'bp',
      name: 'Desktop',
      minWidth: 0,
      designSize: StageSize(width: 1000, height: 800),
      primary: true,
    ),
  ],
  assets: {
    'photo': Asset(
      id: 'photo',
      kind: AssetKind.image,
      uri: 'local://photo',
      mime: 'image/png',
      name: 'Harbour at dusk.png',
    ),
  },
  scenes: [
    Scene(
      id: 's1',
      name: 'One',
      root: FrameNode(
        common: NodeCommon(id: 'r1', width: 1000, height: 800),
        children: [
          TextNode(
            common: NodeCommon(
              id: 'h',
              width: 400,
              height: 40,
              role: NodeRole.heading1,
            ),
            content: [
              Paragraph(spans: [Span(text: 'Arrival')]),
            ],
          ),
          FrameNode(
            common: NodeCommon(
              id: 'fig',
              y: 100,
              width: 300,
              height: 200,
              role: NodeRole.figure,
              altText: 'The harbour',
            ),
            appearance: Appearance(
              fills: [Paint.image(id: 'p', assetId: 'photo')],
            ),
          ),
          FrameNode(
            common: NodeCommon(
              id: 'chart',
              y: 400,
              width: 300,
              height: 200,
              role: NodeRole.figure,
              altText: 'A chart',
            ),
          ),
        ],
      ),
    ),
    Scene(
      id: 's2',
      name: 'Two',
      root: FrameNode(common: NodeCommon(id: 'r2', width: 1000, height: 800)),
    ),
  ],
);

void main() {
  final posters = <String>[];
  Future<Uint8List?> poster({
    required String sceneId,
    double? clock,
    String? nodeId,
  }) async {
    posters.add(nodeId ?? 'scene:$sceneId@$clock');
    return _png;
  }

  Future<Uint8List?> bytesOf(Asset a) async => a.id == 'photo' ? _png : null;

  setUp(posters.clear);

  test('Markdown zip: story.md and the files it references', () async {
    final zip = await exportStaticZip(
      _doc(),
      StaticExportFormat.markdown,
      bytesOf: bytesOf,
      poster: poster,
    );
    final archive = ZipDecoder().decodeBytes(zip);
    final names = [for (final f in archive) f.name]..sort();
    expect(names, [
      'assets/Harbour-at-dusk.png',
      'assets/figure-chart.png',
      'assets/scene-s2.png',
      'story.md',
    ]);
    final md = utf8.decode(archive.findFile('story.md')!.readBytes()!);
    expect(md, contains('![The harbour](assets/Harbour-at-dusk.png)'));
    expect(md, contains('![A chart](assets/figure-chart.png)'));
    expect(md, contains('![Two](assets/scene-s2.png)'));
    // The image figure used its file; the chart and scene two were drawn.
    expect(posters, ['chart', 'scene:s2@0.5']);
  });

  test('HTML zip has index.html', () async {
    final zip = await exportStaticZip(
      _doc(),
      StaticExportFormat.html,
      bytesOf: bytesOf,
      poster: poster,
      backlink: const Backlink('https://soundstage.app/s/z'),
    );
    final archive = ZipDecoder().decodeBytes(zip);
    final html = utf8.decode(archive.findFile('index.html')!.readBytes()!);
    expect(html, contains('<img src="assets/Harbour-at-dusk.png"'));
    expect(html, contains('https://soundstage.app/s/z#scene-s2'));
  });

  test('PDF', () async {
    final pdf = await exportStoryPdf(
      _doc(),
      bytesOf: bytesOf,
      poster: poster,
      backlink: const Backlink('https://soundstage.app/s/z'),
    );
    expect(ascii.decode(pdf.sublist(0, 5)), '%PDF-');
    expect(pdf.length, greaterThan(1000));
    // Images were embedded: the poster source was asked for both.
    expect(posters, ['chart', 'scene:s2@0.5']);
  });
}
