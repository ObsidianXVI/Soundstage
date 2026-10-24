import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/clipboard/clipboard_actions.dart';
import 'package:soundstage_platform/editor/clipboard/clipboard_envelope.dart';
import 'package:soundstage_platform/editor/clipboard/content_hash.dart';
import 'package:soundstage_platform/editor/clipboard/system_clipboard.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/insert/editor_notices.dart';
import 'package:soundstage_platform/editor/shortcuts/shortcut_map.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/fixtures.dart' as fx;
import '../insert/fakes.dart';

typedef Env = ({
  ProviderContainer c,
  FakeAssetService service,
  FakeClipboard clip,
});

Env _env({
  ir.StageDocument? doc,
  FakeAssetService? service,
  FakeClipboard? clip,
}) {
  final s = service ?? FakeAssetService();
  final cl = clip ?? FakeClipboard();
  final c = ProviderContainer(
    overrides: [
      initialDocumentProvider.overrideWithValue(doc ?? fx.fixtureDoc()),
      editorAssetServiceProvider.overrideWithValue(s),
      systemClipboardProvider.overrideWithValue(cl),
    ],
  );
  addTearDown(c.dispose);
  return (c: c, service: s, clip: cl);
}

ClipboardActions _act(Env e) => e.c.read(clipboardActionsProvider);

List<String> _kids(Env e, String id) => [
  for (final k in (e.c.node(id) as ir.FrameNode).children) k.id,
];

/// `b` gets an image fill (asset `img`), a font-styled text child and a
/// named paint style.
Future<Env> _rich({FakeClipboard? clip, Uint8List? bytes}) async {
  final service = FakeAssetService();
  final e = _env(service: service, clip: clip);
  final img = await service.add(
    bytes ?? FakeAssetService.png(40, 20, 1),
    'image/png',
    name: 'pic.png',
  );
  final font = await service.add(Uint8List.fromList([1, 2, 3]), 'font/ttf');
  final doc = e.c.doc.copyWith(
    assets: {
      img.id: img.copyWith(alt: 'A pic'),
      font.id: font,
    },
    fonts: {
      'fam': ir.FontFamily(
        id: 'fam',
        name: 'Test Sans',
        faces: [ir.FontFace(assetId: font.id)],
      ),
    },
    tokens: const ir.TokenSystem(
      paintStyles: {
        'ps': ir.PaintStyleDef(
          name: 'Brand',
          paints: [ir.Paint.solid(id: 'x', color: ir.StageColor.black)],
        ),
      },
    ),
  );
  e.c.ctl.openDocument(doc);
  e.c.ctl.execute(SetImageFill(['b'], img.id));
  e.c.ctl.execute(
    SetProperty(['b'], 'fillStyleId', const ir.IrValue.string('ps')),
  );
  e.c.ctl.execute(
    SetProperty(['t1'], 'style.fontFamilyId', const ir.IrValue.string('fam')),
  );
  return e;
}

void main() {
  group('copy', () {
    test('writes a versioned envelope with the marker first', () async {
      final e = await _rich();
      e.c.ctl.select({'b', 'a'});
      expect(await _act(e).copy(), isTrue);
      final text = e.clip.text!;
      expect(text.startsWith('{"soundstage-clipboard":1'), isTrue);
      final env = ClipboardEnvelope.tryDecode(text)!;
      // Document order, top-level only.
      expect(
        [for (final n in env.nodes) (n['common'] as Map)['id']],
        ['a', 'b'],
      );
      expect(env.parentId, 'root');
      final img = env.assets.values.singleWhere(
        (a) => a.asset.kind == ir.AssetKind.image,
      );
      expect(env.assets, hasLength(2)); // the image and the font file
      expect(img.data, isNotNull);
      expect(img.asset.alt, 'A pic');
      expect(env.paintStyles.keys, ['ps']);
      expect(env.fonts.keys, ['fam']);
    });

    test('a node under a selected node is covered by it', () async {
      final e = _env();
      e.c.ctl.select({'a', 'a1'});
      await _act(e).copy();
      final env = ClipboardEnvelope.tryDecode(e.clip.text!)!;
      expect(env.nodes, hasLength(1));
    });

    test('nothing selected copies nothing', () async {
      final e = _env();
      expect(await _act(e).copy(), isFalse);
      expect(e.clip.text, isNull);
    });

    test('assets past the size cap travel by reference', () async {
      final e = await _rich(bytes: Uint8List(kClipboardInlineAssetBytes + 1));
      e.c.ctl.select({'b'});
      await _act(e).copy();
      final env = ClipboardEnvelope.tryDecode(e.clip.text!)!;
      final a = env.assets.values.firstWhere(
        (a) => a.asset.kind == ir.AssetKind.image,
      );
      expect(a.data, isNull);
      expect(a.hash, isNotEmpty);
    });

    test('envelope text that is not ours or not this version is ignored', () {
      expect(ClipboardEnvelope.tryDecode('hello'), isNull);
      expect(
        ClipboardEnvelope.tryDecode('{"soundstage-clipboard":2,"nodes":[]}'),
        isNull,
      );
      expect(ClipboardEnvelope.tryDecode('{"soundstage-clipboard":1,'), isNull);
    });

    test('a denied write is reported and nothing is lost', () async {
      final e = _env();
      e.clip.denyWrite = true;
      e.c.ctl.select({'a'});
      expect(await _act(e).copy(), isFalse);
      expect(e.c.read(editorNoticesProvider).log, isNotEmpty);
    });
  });

  group('paste', () {
    test('round trip: new ids, +10/+10 in the same place, selected', () async {
      final e = _env();
      e.c.ctl.select({'a'});
      await _act(e).copy();
      await _act(e).paste();
      final kids = _kids(e, 'root');
      final id = kids.last;
      expect(id, isNot('a'));
      final copy = e.c.node(id);
      expect([copy.common.x, copy.common.y], [110, 60]);
      expect(e.c.st.selection, {id});
      // Children got fresh ids too.
      final orig = (e.c.node('a') as ir.FrameNode).children.map((c) => c.id);
      final fresh = (copy as ir.FrameNode).children.map((c) => c.id);
      expect(fresh.toSet().intersection(orig.toSet()), isEmpty);
      expect(fresh, hasLength(orig.length));
      // One undo step.
      e.c.ctl.undo();
      expect(_kids(e, 'root'), isNot(contains(id)));
    });

    test('pasting again steps the offset', () async {
      final e = _env();
      e.c.ctl.select({'a'});
      await _act(e).copy();
      await _act(e).paste();
      await _act(e).paste();
      final id = _kids(e, 'root').last;
      expect([e.c.node(id).common.x, e.c.node(id).common.y], [120, 70]);
    });

    test('into a selected frame: its space, no offset', () async {
      final e = _env();
      e.c.ctl.select({'a'});
      await _act(e).copy();
      e.c.ctl.select({'b'});
      await _act(e).paste();
      final id = _kids(e, 'b').last;
      expect([e.c.node(id).common.x, e.c.node(id).common.y], [100, 50]);
      expect(e.c.st.selectionContext, 'b');
    });

    test('into the context when a non-frame is selected', () async {
      final e = _env();
      e.c.ctl.select({'a'});
      await _act(e).copy();
      e.c.ctl.select({'b1'}); // lives in b
      await _act(e).paste();
      expect(_kids(e, 'b').length, 2);
    });

    test('pasting an auto-layout child joins the flow', () async {
      final e = _env();
      e.c.ctl.select({'r1'});
      await _act(e).copy();
      await _act(e).paste();
      expect(_kids(e, 'row'), hasLength(3));
      expect(e.c.node(_kids(e, 'row').last).common.x, 0); // no offset in flow
    });

    test('into another story: assets, fonts and styles come along and '
        'dedupe', () async {
      final src = await _rich();
      src.c.ctl.select({'b', 't1'});
      await _act(src).copy();

      final dst = _env(
        doc: const ir.StageDocument(
          id: 'other',
          breakpoints: fx.kBreakpoints,
          scenes: [
            ir.Scene(
              id: 's',
              name: 'S',
              kind: ir.SceneKind.pinned,
              scrollLength: 1,
              root: ir.FrameNode(
                common: ir.NodeCommon(id: 'r', width: 500, height: 500),
              ),
            ),
          ],
        ),
        clip: src.clip,
      );
      await _act(dst).paste();
      expect(
        dst.c.doc.assets.values.where((a) => a.kind == ir.AssetKind.image),
        hasLength(1),
      );
      expect(dst.c.doc.fonts.values.single.name, 'Test Sans');
      expect(dst.c.doc.tokens.paintStyles.values.single.name, 'Brand');
      final kids = dst.c.doc.scenes.first.root.children;
      final b = kids.whereType<ir.FrameNode>().single;
      final fill = b.appearance.fills.whereType<ir.ImagePaint>().single;
      expect(dst.c.doc.assets.containsKey(fill.assetId), isTrue);
      expect(dst.c.doc.assets[fill.assetId]!.alt, 'A pic');
      expect(
        b.appearance.fillStyleId,
        dst.c.doc.tokens.paintStyles.keys.single,
      );
      // Ids are new; the text uses the new family id.
      expect(b.id, isNot('b'));
      final t = kids.whereType<ir.TextNode>().single;
      expect(t.style.fontFamilyId, dst.c.doc.fonts.keys.single);
      // Pasting again reuses the same asset, font and style.
      await _act(dst).paste();
      expect(
        dst.c.doc.assets.values.where((a) => a.kind == ir.AssetKind.image),
        hasLength(1),
      );
      expect(dst.c.doc.fonts, hasLength(1));
      expect(dst.c.doc.tokens.paintStyles, hasLength(1));
      // Two files stored once (image and font), not once per paste.
      expect(dst.service.addCount, 2);
    });

    test('an identical file already in the story is reused by hash', () async {
      final src = await _rich();
      src.c.ctl.select({'b'});
      await _act(src).copy();
      final dstService = FakeAssetService();
      final existing = await dstService.add(
        FakeAssetService.png(40, 20, 1),
        'image/png',
        name: 'mine.png',
      );
      final dst = _env(
        doc: fx.fixtureDoc().copyWith(
          id: 'other',
          assets: {existing.id: existing},
        ),
        service: dstService,
        clip: src.clip,
      );
      await _act(dst).paste();
      expect(dst.c.doc.assets.keys, [existing.id]);
      expect(dstService.addCount, 1);
      final pasted = dst.c.node(_kids(dst, 'root').last) as ir.FrameNode;
      expect(
        (pasted.appearance.fills.whereType<ir.ImagePaint>().single).assetId,
        existing.id,
      );
    });

    test('a file that did not travel is found in the same browser '
        'profile, else reported', () async {
      final src = await _rich(bytes: Uint8List(kClipboardInlineAssetBytes + 1));
      src.c.ctl.select({'b'});
      await _act(src).copy();
      // Same profile: the store has it.
      final same = _env(
        doc: fx.fixtureDoc().copyWith(id: 'other'),
        service: src.service,
        clip: src.clip,
      );
      await _act(same).paste();
      expect(same.c.doc.assets.values.any((a) => a.name == 'pic.png'), isTrue);
      expect(same.c.read(editorNoticesProvider).log, isEmpty);
      // Another profile: no file, a message.
      final other = _env(
        doc: fx.fixtureDoc().copyWith(id: 'other2'),
        clip: src.clip,
      );
      await _act(other).paste();
      expect(
        other.c.read(editorNoticesProvider).log.single,
        contains('could not be pasted'),
      );
    });

    test('plain text becomes a text node, a line per paragraph', () async {
      final e = _env();
      e.clip.text = 'First line\r\nSecond line\n\nFourth';
      await _act(e).paste();
      final n = e.c.node(_kids(e, 'root').last) as ir.TextNode;
      expect(n.common.role, ir.NodeRole.paragraph);
      expect(
        [for (final p in n.content) p.spans.single.text],
        ['First line', 'Second line', '', 'Fourth'],
      );
      expect(n.common.name, 'First line');
      expect(e.c.st.selection, {n.id});
    });

    test('an image on the clipboard becomes an image frame', () async {
      final e = _env();
      e.clip.image = (
        name: 'Pasted image',
        bytes: FakeAssetService.png(300, 200),
        mime: 'image/png',
      );
      await _act(e).paste();
      final f = e.c.node(_kids(e, 'root').last) as ir.FrameNode;
      expect(f.common.role, ir.NodeRole.figure);
      expect([f.common.width, f.common.height], [300, 200]);
      expect(e.c.doc.assets, hasLength(1));
    });

    test('the envelope wins over an image and plain text', () async {
      final e = _env();
      e.c.ctl.select({'a'});
      await _act(e).copy();
      e.clip.image = (
        name: 'x',
        bytes: FakeAssetService.png(3, 3),
        mime: 'image/png',
      );
      await _act(e).paste();
      expect(e.c.doc.assets, isEmpty);
      expect(e.c.node(_kids(e, 'root').last), isA<ir.FrameNode>());
    });

    test('a denied read is reported and changes nothing', () async {
      final e = _env();
      e.clip.text = 'hi';
      e.clip.denyRead = true;
      final before = e.c.doc;
      await _act(e).paste();
      expect(identical(e.c.doc, before), isTrue);
      expect(
        e.c.read(editorNoticesProvider).log.single,
        contains('blocked reading the clipboard'),
      );
    });

    test('an empty clipboard says so', () async {
      final e = _env();
      await _act(e).paste();
      expect(e.c.read(editorNoticesProvider).log.single, contains('nothing'));
    });
  });

  group('cut and paste to replace', () {
    test('cut copies and deletes in one undo step', () async {
      final e = _env();
      e.c.ctl.select({'a', 'b'});
      await _act(e).cut();
      expect(_kids(e, 'root'), isNot(contains('a')));
      expect(_kids(e, 'root'), isNot(contains('b')));
      expect(ClipboardEnvelope.tryDecode(e.clip.text!)!.nodes, hasLength(2));
      e.c.ctl.undo();
      expect(_kids(e, 'root'), containsAll(['a', 'b']));
      // Pasting after a cut puts them back (no offset: the original is gone).
    });

    test('paste to replace swaps the selection, centred, one step', () async {
      final e = _env();
      e.c.ctl.select({'b1'});
      await _act(e).copy();
      e.c.ctl.select({'a2'}); // 100x100 at (40,100) in a; b1 is 10x10
      await _act(e).paste(replace: true);
      expect(_kids(e, 'a'), isNot(contains('a2')));
      final id = _kids(e, 'a').last;
      final n = e.c.node(id);
      // Centre of a2 is (90,150); a 10x10 node centred there.
      expect([n.common.x, n.common.y], [85, 145]);
      expect(e.c.st.selection, {id});
      e.c.ctl.undo();
      expect(_kids(e, 'a'), contains('a2'));
      expect(_kids(e, 'a'), isNot(contains(id)));
    });

    test('paste to replace refuses plain text', () async {
      final e = _env();
      e.clip.text = 'hello';
      e.c.ctl.select({'a'});
      await _act(e).paste(replace: true);
      expect(_kids(e, 'root'), contains('a'));
      expect(e.c.read(editorNoticesProvider).log, isNotEmpty);
    });
  });

  group('shortcuts and hashing', () {
    test('Cmd+C, X, V and Shift+Cmd+V are in the one table', () {
      final ids = {for (final d in kEditorShortcuts) d.id};
      expect(ids, containsAll(['copy', 'cut', 'paste', 'pasteReplace']));
      expect(shortcutLabel('paste', mac: true), '⌘V');
      expect(shortcutLabel('pasteReplace', mac: false), 'Ctrl+Shift+V');
    });

    test('contentHash tells content apart and is stable', () {
      final a = Uint8List.fromList(utf8.encode('hello'));
      final b = Uint8List.fromList(utf8.encode('hellp'));
      expect(contentHash(a), contentHash(Uint8List.fromList(a)));
      expect(contentHash(a), isNot(contentHash(b)));
      expect(contentHash(a), endsWith('-5'));
    });
  });
}
