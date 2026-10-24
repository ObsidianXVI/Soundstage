import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

const _img1 = Asset(
  id: 'img1',
  kind: AssetKind.image,
  uri: 'local://img1',
  name: 'one.png',
  mime: 'image/png',
  width: 40,
  height: 20,
);
const _img2 = Asset(
  id: 'img2',
  kind: AssetKind.image,
  uri: 'local://img2',
  name: 'two.png',
  mime: 'image/png',
);

StageDocument _withAssets([StageDocument? doc]) =>
    (doc ?? fixtureDoc()).copyWith(assets: {'img1': _img1, 'img2': _img2});

/// `b` filled with img1, in a breakpoint patch on `mobile` too.
StageDocument _used() {
  final doc = _withAssets();
  return updateNode(
    doc,
    'b',
    (n) => (n as FrameNode).copyWith(
      appearance: n.appearance.copyWith(
        fills: const [Paint.image(id: 'p1', assetId: 'img1')],
      ),
    ),
  ).document;
}

void main() {
  group('assets', () {
    test('AddAssets adds new entries once; undo removes them', () {
      final c = editorContainer();
      expectRoundTrip(c, const AddAssets([_img1]));
      expect(c.doc.assets.keys, ['img1']);
      final again = c.ctl.execute(const AddAssets([_img1]));
      expect(again.changed, isFalse);
      c.ctl.undo();
      expect(c.doc.assets, isEmpty);
    });

    test('UpdateAsset renames; the id and so every use stay', () {
      final c = editorContainer(_used());
      expectRoundTrip(c, UpdateAsset(_img1.copyWith(name: 'hero.png')));
      expect(c.doc.assets['img1']!.name, 'hero.png');
      final fills = (c.node('b') as FrameNode).appearance.fills;
      expect((fills.single as ImagePaint).assetId, 'img1');
    });

    test('UpdateAsset coalesces a typing burst into one undo step', () {
      final c = editorContainer(_withAssets());
      c.ctl.beginGesture();
      c.ctl.execute(UpdateAsset(_img1.copyWith(alt: 'A')));
      c.ctl.execute(UpdateAsset(_img1.copyWith(alt: 'A c')));
      c.ctl.execute(UpdateAsset(_img1.copyWith(alt: 'A cat')));
      c.ctl.endGesture();
      expect(c.doc.assets['img1']!.alt, 'A cat');
      c.ctl.undo();
      expect(c.doc.assets['img1']!.alt, '');
    });

    test('DeleteAssets deletes unused assets', () {
      final c = editorContainer(_withAssets());
      expectRoundTrip(c, const DeleteAssets(['img2']));
      expect(c.doc.assets.keys, ['img1']);
    });

    test('DeleteAssets refuses a used asset and says where', () {
      final c = editorContainer(_used());
      final r = c.ctl.execute(const DeleteAssets(['img1']));
      expect(r.ok, isFalse);
      expect(r.diagnostics.single.message, contains('one.png'));
      expect(r.diagnostics.single.message, contains('b'));
      expect(c.doc.assets.keys, containsAll(['img1', 'img2']));
    });

    test('a use in a breakpoint patch counts', () {
      final doc = updateNode(
        _withAssets(),
        'b1',
        (n) => n.copyWith(
          common: n.common.copyWith(
            breakpointOverrides: {
              'mobile': {
                'fills': const IrValue.paints([
                  Paint.image(id: 'p9', assetId: 'img2'),
                ]),
              },
            },
          ),
        ),
      ).document;
      expect(assetUsages(doc)['img2']!.single.id, 'b1');
    });

    test('ReplaceAssetEverywhere rewrites every use, then deletes the old', () {
      final c = editorContainer(_used());
      expectRoundTrip(c, const ReplaceAssetEverywhere('img1', 'img2'));
      expect(c.doc.assets.keys, ['img2']);
      final fills = (c.node('b') as FrameNode).appearance.fills;
      expect((fills.single as ImagePaint).assetId, 'img2');
      expect(assetUsages(c.doc)['img1'], isNull);
    });

    test('usages ignore names and alt text that equal an id', () {
      final doc = updateNode(
        _withAssets(),
        'b',
        (n) => n.copyWith(
          common: n.common.copyWith(name: 'img1', altText: 'img1'),
        ),
      ).document;
      expect(assetUsages(doc), isEmpty);
    });
  });

  group('SetImageFill', () {
    test('adds an image paint on top when there is none', () {
      final c = editorContainer(_withAssets());
      expectRoundTrip(c, SetImageFill(['b', 'a'], 'img1'));
      for (final id in ['a', 'b']) {
        final fills = (c.node(id) as FrameNode).appearance.fills;
        expect(fills.single, isA<ImagePaint>());
        expect((fills.single as ImagePaint).assetId, 'img1');
      }
    });

    test('replaces the first image paint, keeping its settings', () {
      final doc = updateNode(
        _withAssets(),
        'b',
        (n) => (n as FrameNode).copyWith(
          appearance: n.appearance.copyWith(
            fills: const [
              Paint.solid(id: 's', color: StageColor.black),
              Paint.image(
                id: 'p1',
                assetId: 'img1',
                scaleMode: ImageScaleMode.fit,
                focalPoint: StagePoint(x: 0.2, y: 0.8),
              ),
            ],
          ),
        ),
      ).document;
      final c = editorContainer(doc);
      expectRoundTrip(c, SetImageFill(['b'], 'img2'));
      final fills = (c.node('b') as FrameNode).appearance.fills;
      expect(fills, hasLength(2));
      final img = fills.last as ImagePaint;
      expect(img.assetId, 'img2');
      expect(img.id, 'p1');
      expect(img.scaleMode, ImageScaleMode.fit);
      expect(img.focalPoint, const StagePoint(x: 0.2, y: 0.8));
    });

    test('skips nodes that cannot take a fill (text) with a warning', () {
      final c = editorContainer(_withAssets());
      final r = c.ctl.execute(SetImageFill(['b', 't1'], 'img1'));
      expect(r.ok, isTrue);
      expect(r.diagnostics.single.severity, IrSeverity.warning);
      expect((c.node('b') as FrameNode).appearance.fills, hasLength(1));
    });

    test('follows the edit scope (a patch on this breakpoint)', () {
      final c = editorContainer(_withAssets());
      c.ctl
        ..setEditingBreakpoint('mobile')
        ..setEditScope(EditScope.thisBreakpoint);
      c.ctl.execute(SetImageFill(['b'], 'img1'));
      expect((c.node('b') as FrameNode).appearance.fills, isEmpty);
      expect(
        c.node('b').common.breakpointOverrides['mobile']!['fills'],
        isA<PaintsValue>(),
      );
    });
  });

  group('fonts', () {
    const file = Asset(
      id: 'f1',
      kind: AssetKind.font,
      uri: 'local://f1',
      name: 'a.ttf',
      mime: 'font/ttf',
    );
    const file2 = Asset(
      id: 'f2',
      kind: AssetKind.font,
      uri: 'local://f2',
      name: 'b.ttf',
      mime: 'font/ttf',
    );

    test('ImportFont creates a family; a second file joins it by name', () {
      final c = editorContainer();
      expectRoundTrip(
        c,
        ImportFont(
          asset: file,
          familyName: 'Test Sans',
          face: const FontFace(assetId: 'f1'),
        ),
      );
      expect(c.doc.fonts, hasLength(1));
      final id = c.doc.fonts.keys.single;
      expect(c.doc.assets.keys, ['f1']);
      expectRoundTrip(
        c,
        ImportFont(
          asset: file2,
          familyName: 'test sans',
          face: const FontFace(assetId: 'f2', weight: 700),
        ),
      );
      expect(c.doc.fonts, hasLength(1));
      expect(c.doc.fonts[id]!.faces.map((f) => f.weight), [400, 700]);
    });

    test('ImportFont refuses a style the family already has', () {
      final c = editorContainer();
      c.ctl.execute(
        ImportFont(
          asset: file,
          familyName: 'Test Sans',
          face: const FontFace(assetId: 'f1'),
        ),
      );
      final r = c.ctl.execute(
        ImportFont(
          asset: file2,
          familyName: 'Test Sans',
          face: const FontFace(assetId: 'f2'),
        ),
      );
      expect(r.ok, isFalse);
      expect(r.diagnostics.single.message, contains('already has'));
      expect(c.doc.assets.keys, ['f1']);
    });

    test('SetDefaultFontFamily sets and clears the default', () {
      final c = editorContainer();
      c.ctl.execute(
        ImportFont(
          asset: file,
          familyName: 'Test Sans',
          face: const FontFace(assetId: 'f1'),
        ),
      );
      final id = c.doc.fonts.keys.single;
      expectRoundTrip(c, SetDefaultFontFamily(id));
      expect(c.doc.defaultTextStyle.fontFamilyId, id);
      expect(c.ctl.execute(const SetDefaultFontFamily('nope')).ok, isFalse);
      c.ctl.execute(const SetDefaultFontFamily(null));
      expect(c.doc.defaultTextStyle.fontFamilyId, isNull);
    });

    test('RemoveFontFamily refuses a family text uses, else removes it', () {
      final c = editorContainer();
      c.ctl.execute(
        ImportFont(
          asset: file,
          familyName: 'Test Sans',
          face: const FontFace(assetId: 'f1'),
        ),
      );
      final id = c.doc.fonts.keys.single;
      c.ctl.execute(SetDefaultFontFamily(id));
      final blocked = c.ctl.execute(RemoveFontFamily(id));
      expect(blocked.ok, isFalse);
      expect(blocked.diagnostics.single.message, contains('Default text'));
      c.ctl.execute(const SetDefaultFontFamily(null));
      // A span that uses it also blocks.
      c.ctl.execute(
        SetProperty(['t1'], 'style.fontFamilyId', IrValue.string(id)),
      );
      expect(fontUsages(c.doc)[id], isNotNull);
      c.ctl.undo();
      expectRoundTrip(c, RemoveFontFamily(id));
      expect(c.doc.fonts, isEmpty);
      expect(c.doc.assets, isEmpty);
    });

    test('RemoveFontFace drops one file; the last takes the family', () {
      final c = editorContainer();
      c.ctl
        ..execute(
          ImportFont(
            asset: file,
            familyName: 'Test Sans',
            face: const FontFace(assetId: 'f1'),
          ),
        )
        ..execute(
          ImportFont(
            asset: file2,
            familyName: 'Test Sans',
            face: const FontFace(assetId: 'f2', weight: 700),
          ),
        );
      final id = c.doc.fonts.keys.single;
      c.ctl.execute(RemoveFontFace(id, 'f2'));
      expect(c.doc.fonts[id]!.faces.single.assetId, 'f1');
      expect(c.doc.assets.keys, ['f1']);
      c.ctl.execute(RemoveFontFace(id, 'f1'));
      expect(c.doc.fonts, isEmpty);
    });
  });
}
