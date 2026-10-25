import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/insert/editor_notices.dart';
import 'package:soundstage_platform/editor/panels/asset_actions.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/fixtures.dart' as fx;
import '../insert/fakes.dart';
import 'font_fixtures.dart';

({ProviderContainer c, FakeAssetService service}) _setup({
  List<EditorFile> picks = const [],
}) {
  final service = FakeAssetService();
  final c = ProviderContainer(
    overrides: [
      initialDocumentProvider.overrideWithValue(fx.fixtureDoc()),
      editorAssetServiceProvider.overrideWithValue(service),
      editorFilePickerProvider.overrideWithValue(
        ({String accept = '', bool multiple = false}) async => picks,
      ),
    ],
  );
  addTearDown(c.dispose);
  return (c: c, service: service);
}

EditorFile _img(String name, int w, int h, [int salt = 0]) =>
    (name: name, bytes: FakeAssetService.png(w, h, salt), mime: 'image/png');

EditorFile _font(String name, List<int> bytes) =>
    (name: name, bytes: Uint8List.fromList(bytes), mime: 'font/ttf');

AssetActions _actions(ProviderContainer c) => c.read(assetActionsProvider);

void main() {
  group('upload', () {
    test('files go to the store and the document, one undo step', () async {
      final s = _setup(picks: [_img('a.png', 10, 10), _img('b.png', 20, 10)]);
      final added = await _actions(s.c).uploadMedia();
      expect(added.map((a) => a.name), ['a.png', 'b.png']);
      expect(s.c.doc.assets.keys, hasLength(2));
      expect(s.service.files, hasLength(2));
      s.c.ctl.undo();
      expect(s.c.doc.assets, isEmpty);
    });

    test('the same file twice is stored once (R3): again later, or twice '
        'in one drop', () async {
      final s = _setup();
      await _actions(s.c).addFiles([_img('sea.png', 10, 10, 1)]);
      final first = s.c.doc.assets.keys.single;
      await _actions(s.c).addFiles([
        _img('sea copy.png', 10, 10, 1),
        _img('other.png', 10, 10, 2),
        _img('other again.png', 10, 10, 2),
      ]);
      expect(s.c.doc.assets, hasLength(2));
      expect(s.c.doc.assets.containsKey(first), isTrue);
      expect(s.service.addCount, 2);
    });

    test('a failing file is reported and the others still land', () async {
      final s = _setup();
      await _actions(s.c).addFiles([
        _img('a.png', 10, 10),
        (name: 'notes.txt', bytes: Uint8List(3), mime: 'text/plain'),
      ]);
      expect(s.c.doc.assets.values.single.name, 'a.png');
      final said = s.c.read(editorNoticesProvider).log.join();
      expect(said, contains('notes.txt'));
    });

    test('blocked storage says so and changes nothing', () async {
      final s = _setup();
      s.service.available = false;
      await _actions(s.c).addFiles([_img('a.png', 10, 10)]);
      expect(s.c.doc.assets, isEmpty);
      expect(
        s.c.read(editorNoticesProvider).log.join(),
        contains('Browser storage is blocked'),
      );
    });

    test('audio and video go to the library', () async {
      final s = _setup();
      await _actions(s.c).addFiles([
        (name: 'a.mp3', bytes: Uint8List(8), mime: 'audio/mpeg'),
        (name: 'v.mp4', bytes: Uint8List(8), mime: ''),
      ]);
      expect(s.c.doc.assets.values.map((a) => a.kind), [
        ir.AssetKind.audio,
        ir.AssetKind.video,
      ]);
    });
  });

  group('fonts', () {
    test('files group into families by name, weight and style', () async {
      final s = _setup();
      await _actions(s.c).importFonts([
        _font('r.ttf', buildFont(family: 'Test Sans')),
        _font(
          'b.ttf',
          buildFont(family: 'Test Sans', style: 'Bold', weight: 700),
        ),
        _font(
          'i.ttf',
          buildFont(family: 'Test Sans', style: 'Italic', italic: true),
        ),
        _font('o.ttf', buildFont(family: 'Other Serif')),
      ]);
      final fams = s.c.doc.fonts.values.toList();
      expect(fams.map((f) => f.name), ['Test Sans', 'Other Serif']);
      expect(fams.first.faces.map((f) => (f.weight, f.italic)), [
        (400, false),
        (700, false),
        (400, true),
      ]);
      // The font files are assets of kind font.
      expect(
        s.c.doc.assets.values.where((a) => a.kind == ir.AssetKind.font),
        hasLength(4),
      );
    });

    test('a variable font keeps its axes', () async {
      final s = _setup();
      await _actions(s.c).importFonts([
        _font(
          'v.ttf',
          buildFont(
            family: 'Var Sans',
            axes: [(tag: 'wght', min: 100, def: 400, max: 900)],
          ),
        ),
      ]);
      final face = s.c.doc.fonts.values.single.faces.single;
      expect(face.variable, isTrue);
      expect(face.axes.single.tag, 'wght');
      expect(face.axes.single.max, 900);
    });

    test('WOFF is unpacked; the stored file is plain sfnt', () async {
      final s = _setup();
      await _actions(
        s.c,
      ).importFonts([_font('w.woff', toWoff(buildFont(family: 'Wof Sans')))]);
      final asset = s.c.doc.assets.values.single;
      expect(asset.mime, 'font/ttf');
      expect(s.service.files[asset.id]!.sublist(0, 4), [0, 1, 0, 0]);
    });

    test('unsupported formats are refused with the reason', () async {
      final s = _setup();
      final woff2 = Uint8List(80)..buffer.asByteData().setUint32(0, 0x774F4632);
      await _actions(s.c).importFonts([
        _font('a.woff2', woff2),
        _font('b.ttf', List.filled(50, 1)),
      ]);
      expect(s.c.doc.fonts, isEmpty);
      expect(s.service.addCount, 0);
      final said = s.c.read(editorNoticesProvider).log.join('\n');
      expect(said, contains('a.woff2: WOFF2 fonts are not supported'));
      expect(said, contains('b.ttf: This is not a font file'));
    });

    test('a style the family already has is refused before storing', () async {
      final s = _setup();
      await _actions(s.c).importFonts([_font('r.ttf', buildFont())]);
      await _actions(s.c).importFonts([_font('r2.ttf', buildFont())]);
      expect(s.service.addCount, 1);
      expect(
        s.c.read(editorNoticesProvider).log.last,
        contains('already has a 400 face'),
      );
    });

    test('dropped font files are routed to the font table', () async {
      final s = _setup();
      await _actions(
        s.c,
      ).addFiles([_font('r.ttf', buildFont()), _img('a.png', 4, 4)]);
      expect(s.c.doc.fonts, hasLength(1));
      expect(s.c.doc.assets, hasLength(2));
    });

    test('default font, and remove only while unused', () async {
      final s = _setup();
      await _actions(s.c).importFonts([_font('r.ttf', buildFont())]);
      final id = s.c.doc.fonts.keys.single;
      _actions(s.c).setDefaultFont(id);
      expect(s.c.doc.defaultTextStyle.fontFamilyId, id);
      expect(_actions(s.c).removeFont(id), isFalse);
      expect(s.c.doc.fonts, isNotEmpty);
      _actions(s.c).setDefaultFont(null);
      expect(_actions(s.c).removeFont(id), isTrue);
      expect(s.c.doc.fonts, isEmpty);
    });
  });

  group('asset edits', () {
    Future<String> addImage(
      ({ProviderContainer c, FakeAssetService service}) s,
    ) async {
      await _actions(s.c).addFiles([_img('a.png', 40, 20)]);
      return s.c.doc.assets.keys.single;
    }

    test('rename and alt text', () async {
      final s = _setup();
      final id = await addImage(s);
      _actions(s.c)
        ..rename(id, 'hero.png')
        ..setAlt(id, 'A hero');
      expect(s.c.doc.assets[id]!.name, 'hero.png');
      expect(s.c.doc.assets[id]!.alt, 'A hero');
    });

    test(
      'replacing the file keeps the id, name and alt; uses follow',
      () async {
        final s = _setup();
        final id = await addImage(s);
        _actions(s.c).setAlt(id, 'A hero');
        s.c.ctl.execute(SetImageFill(['b'], id));
        final ok = await _actions(
          s.c,
        ).replaceFile(id, _img('new.png', 400, 300, 9));
        expect(ok, isTrue);
        final a = s.c.doc.assets[id]!;
        expect([a.width, a.height], [400, 300]);
        expect(a.name, 'a.png');
        expect(a.alt, 'A hero');
        expect(s.service.files[id]![4], 9);
        expect(s.c.doc.assets.keys, [id]);
        final fill = (s.c.node('b') as ir.FrameNode).appearance.fills.single;
        expect((fill as ir.ImagePaint).assetId, id);
      },
    );

    test('replacing with another kind of file is refused', () async {
      final s = _setup();
      final id = await addImage(s);
      final ok = await _actions(s.c).replaceFile(id, (
        name: 'a.mp3',
        bytes: Uint8List(4),
        mime: 'audio/mpeg',
      ));
      expect(ok, isFalse);
      expect(s.service.files[id]!.length, 5);
    });

    test('delete: unused goes, used reports where', () async {
      final s = _setup();
      final id = await addImage(s);
      s.c.ctl.execute(SetImageFill(['b'], id));
      final uses = _actions(s.c).delete(id);
      expect(uses, isNotEmpty);
      expect(s.c.doc.assets, isNotEmpty);
      s.c.ctl.execute(SetImageFill(['b'], id)); // idempotent
      await _actions(s.c).addFiles([_img('spare.png', 5, 5)]);
      final spare = s.c.doc.assets.values.last.id;
      expect(_actions(s.c).delete(spare), isEmpty);
      expect(s.c.doc.assets.keys, [id]);
    });

    test('replace everywhere moves every use, then drops the old', () async {
      final s = _setup();
      final id = await addImage(s);
      await _actions(s.c).addFiles([_img('b.png', 5, 5)]);
      final other = s.c.doc.assets.keys.last;
      s.c.ctl.execute(SetImageFill(['b', 'a'], id));
      expect(_actions(s.c).replaceEverywhere(id, other), isTrue);
      expect(s.c.doc.assets.keys, [other]);
      for (final n in ['a', 'b']) {
        final f = (s.c.node(n) as ir.FrameNode).appearance.fills.single;
        expect((f as ir.ImagePaint).assetId, other);
      }
    });

    test('applyAsFill needs a selection', () async {
      final s = _setup();
      final id = await addImage(s);
      expect(_actions(s.c).applyAsFill(id), isFalse);
      s.c.ctl.select({'b'});
      expect(_actions(s.c).applyAsFill(id), isTrue);
      expect((s.c.node('b') as ir.FrameNode).appearance.fills, hasLength(1));
    });
  });
}
