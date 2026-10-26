import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/cloud/chunks.dart';
import 'package:soundstage_platform/ir/ir.dart';

void main() {
  for (final name in ['spike', 'motion', 'sound', 'static', 'paint_gallery']) {
    test('$name: split then reassembled is the same document', () {
      final doc = loadDocument(
        File('assets/demo/$name.stage.json').readAsStringSync(),
      ).document!;
      // Through JSON, as published chunks travel.
      Map<String, Object?> wire(Object? o) =>
          jsonDecode(jsonEncode(o)) as Map<String, Object?>;
      final chunks = splitDocument(doc);
      final chunked = ChunkedDocument.open(
        wire(chunks.manifest),
        wire(chunks.library),
      );
      expect(chunked.document.scenes.map((s) => s.id), [
        for (final s in doc.scenes) s.id,
      ]);
      for (final (i, s) in chunked.document.scenes.indexed) {
        expect(s.root.children, isEmpty);
        expect(s.tracks, isEmpty);
        expect(s.root.common, doc.scenes[i].root.common);
        expect(s.clocks, doc.scenes[i].clocks);
      }
      for (final s in doc.scenes.reversed) {
        expect(chunked.addScene(wire(chunks.scenes[s.id])), isTrue);
      }
      expect(chunked.complete, isTrue);
      expect(jsonEncode(chunked.document.toJson()), jsonEncode(doc.toJson()));
    });
  }

  test('the manifest is small and holds no library', () {
    final doc = loadDocument(
      File('assets/demo/spike.stage.json').readAsStringSync(),
    ).document!;
    final chunks = splitDocument(doc);
    expect(chunks.manifest['format'], kChunkedFormat);
    for (final k in ['assets', 'fonts', 'tokens', 'components', 'scenes']) {
      expect(chunks.manifest.containsKey(k), isFalse, reason: k);
    }
    expect(
      jsonEncode(chunks.manifest).length,
      lessThan(jsonEncode(doc.toJson()).length),
    );
  });

  test('a foreign chunk or manifest is refused', () {
    final doc = StageDocument.empty(ids: IdGenerator.seeded(1));
    final chunks = splitDocument(doc);
    final chunked = ChunkedDocument.open(chunks.manifest, chunks.library);
    expect(
      chunked.addScene({'id': 'nope', 'root': <String, Object?>{}}),
      isFalse,
    );
    expect(
      () => ChunkedDocument.open({'id': 'x'}, const {}),
      throwsFormatException,
    );
  });
}
