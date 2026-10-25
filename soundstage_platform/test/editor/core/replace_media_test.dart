import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

// Content mode's media replace (DECISIONS 24/10/26 "T1.13 content mode"):
// an image goes into the layer that supplies the visible paint; a sound
// repoints one track at a new asset.

Asset _asset(String id, [AssetKind kind = AssetKind.image]) => Asset(
  id: id,
  kind: kind,
  uri: 'local://$id',
  name: '$id.png',
  mime: kind == AssetKind.image ? 'image/png' : 'audio/mpeg',
);

const _focal = StagePoint(x: 0.25, y: 0.75);
const _filters = ImageFilters(exposure: 0.3);
const _crop = StageRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5);

const _paint = Paint.image(
  id: 'p1',
  assetId: 'img1',
  scaleMode: ImageScaleMode.fit,
  focalPoint: _focal,
  cropRect: _crop,
  filters: _filters,
);

/// Node `b` of the editor fixture with [fills] and [patches].
StageDocument _doc({
  List<Paint> fills = const [],
  Map<String, Map<String, IrValue>> patches = const {},
}) {
  final doc = fixtureDoc().copyWith(
    assets: {
      for (final id in ['img1', 'img2', 'img3', 'new']) id: _asset(id),
    },
  );
  return updateNode(
    doc,
    'b',
    (n) => (n as FrameNode).copyWith(
      appearance: n.appearance.copyWith(fills: fills),
      common: n.common.copyWith(breakpointOverrides: patches),
    ),
  ).document;
}

ReplaceVisibleImage _replace(String bp, [String node = 'b']) =>
    ReplaceVisibleImage(node, 'new', breakpointId: bp);

List<Paint> _baseFills(ProviderContainer c) =>
    (c.node('b') as FrameNode).appearance.fills;

ImagePaint _imageAt(ProviderContainer c, String bp) =>
    (c.resolved('b', bp).node as FrameNode).appearance.fills
        .whereType<ImagePaint>()
        .single;

void _expectKept(ImagePaint p) {
  expect(p.id, 'p1');
  expect(p.scaleMode, ImageScaleMode.fit);
  expect(p.focalPoint, _focal);
  expect(p.cropRect, _crop);
  expect(p.filters, _filters);
}

void main() {
  group('ReplaceVisibleImage', () {
    test('a shared image is replaced in the base; one undo step', () {
      final c = editorContainer(_doc(fills: const [_paint]));
      final r = expectRoundTrip(c, _replace('mobile'));
      expect(r.label, 'Replace image');
      final p = _baseFills(c).single as ImagePaint;
      expect(p.assetId, 'new');
      _expectKept(p);
      expect(c.node('b').common.breakpointOverrides, isEmpty);
      expect(_imageAt(c, 'desktop').assetId, 'new');
      expect(c.st.history.undoLabel, 'Replace image');
    });

    test('a mobile-only image is replaced in the mobile patch, not '
        'duplicated into the base', () {
      // The base has no image; mobile's patch adds the whole stack.
      final c = editorContainer(
        _doc(
          patches: {
            'mobile': {
              'fills': const IrValue.paints([_paint]),
            },
          },
        ),
      );
      expectRoundTrip(c, _replace('mobile'));
      expect(_baseFills(c), isEmpty);
      final patch = c.node('b').common.breakpointOverrides['mobile']!;
      expect(patch.keys, ['fills']);
      final p = (patch['fills']! as PaintsValue).value.single as ImagePaint;
      expect(p.assetId, 'new');
      _expectKept(p);
      expect(_imageAt(c, 'mobile').assetId, 'new');
      expect(
        (c.resolved('b', 'desktop').node as FrameNode).appearance.fills,
        isEmpty,
      );
    });

    test('different images per breakpoint: only the one shown changes', () {
      final c = editorContainer(
        _doc(
          fills: const [_paint],
          patches: {
            'mobile': {'fills.p1.assetId': const IrValue.string('img2')},
          },
        ),
      );
      expectRoundTrip(c, _replace('mobile'));
      final patch = c.node('b').common.breakpointOverrides['mobile']!;
      expect(patch, {'fills.p1.assetId': const IrValue.string('new')});
      expect((_baseFills(c).single as ImagePaint).assetId, 'img1');
      expect(_imageAt(c, 'desktop').assetId, 'img1');
      expect(_imageAt(c, 'mobile').assetId, 'new');
      _expectKept(_imageAt(c, 'mobile'));

      // And the other way round: replacing on desktop leaves mobile's.
      final d = editorContainer(c.doc);
      d.ctl.execute(
        const ReplaceVisibleImage('b', 'img3', breakpointId: 'desktop'),
      );
      expect(_imageAt(d, 'desktop').assetId, 'img3');
      expect(_imageAt(d, 'mobile').assetId, 'new');
    });

    test('an inherited patch (tablet inherits desktop) is rewritten where '
        'it is defined; the other paints in it survive', () {
      final c = editorContainer(
        _doc(
          fills: const [
            Paint.solid(id: 's0', color: StageColor(r: 1, g: 0, b: 0)),
          ],
          patches: {
            'desktop': {
              'fills': const IrValue.paints([
                Paint.solid(id: 's1', color: StageColor(r: 0, g: 1, b: 0)),
                _paint,
              ]),
            },
          },
        ),
      );
      expectRoundTrip(c, _replace('tablet'));
      final overrides = c.node('b').common.breakpointOverrides;
      expect(overrides.keys, ['desktop']);
      final stack = (overrides['desktop']!['fills']! as PaintsValue).value;
      expect(stack.first.id, 's1');
      expect((stack.last as ImagePaint).assetId, 'new');
      _expectKept(stack.last as ImagePaint);
      expect(_imageAt(c, 'tablet').assetId, 'new');
      expect(_imageAt(c, 'desktop').assetId, 'new');
      expect(
        (c.resolved('b', 'mobile').node as FrameNode).appearance.fills.single,
        isA<SolidPaint>(),
      );
    });

    test('the edit scope is ignored', () {
      final c = editorContainer(_doc(fills: const [_paint]));
      c.ctl.setEditScope(EditScope.thisBreakpoint);
      c.ctl.execute(_replace('mobile'));
      expect((_baseFills(c).single as ImagePaint).assetId, 'new');
      expect(c.node('b').common.breakpointOverrides, isEmpty);
    });

    test('inside an instance: an override on the instance, never the '
        'component', () {
      var doc = _doc();
      doc = doc.copyWith(
        components: {
          'cmp': doc.components['cmp']!.copyWith(
            root: (doc.components['cmp']!.root).copyWith(
              children: [
                shape(
                  'cmpI',
                ).copyWith(appearance: const Appearance(fills: [_paint])),
                ...doc.components['cmp']!.root.children.skip(1),
              ],
            ),
          ),
        },
      );
      final c = editorContainer(doc);
      expectRoundTrip(c, _replace('mobile', 'inst/cmpI'));
      final inst = c.node('inst') as InstanceNode;
      expect(inst.overrides['cmpI'], {
        'fills.p1.assetId': const IrValue.string('new'),
      });
      final cmpFill =
          (c.doc.components['cmp']!.root.children.first as ShapeNode)
                  .appearance
                  .fills
                  .single
              as ImagePaint;
      expect(cmpFill.assetId, 'img1');

      // A second replace rewrites the existing override key in place.
      final again = c.ctl.execute(
        const ReplaceVisibleImage('inst/cmpI', 'img3', breakpointId: 'mobile'),
      );
      expect(again.ok, isTrue);
      expect((c.node('inst') as InstanceNode).overrides['cmpI']!.keys, [
        'fills.p1.assetId',
      ]);
      expect(
        (c.node('inst') as InstanceNode).overrides['cmpI']!['fills.p1.assetId'],
        const IrValue.string('img3'),
      );
    });

    test('a node without an image is refused and nothing changes', () {
      final c = editorContainer(_doc());
      final before = c.doc;
      final r = c.ctl.execute(_replace('mobile'));
      expect(r.ok, isFalse);
      expect(identical(c.doc, before), isTrue);
    });
  });

  group('SetAudioTrackAsset', () {
    StageDocument tracks() => fixtureDoc().copyWith(
      assets: {
        'aud1': _asset('aud1', AssetKind.audio),
        'aud2': _asset('aud2', AssetKind.audio),
      },
      audioTracks: const [
        AudioTrack(id: 't1', assetId: 'aud1', volume: 0.5, loop: true),
        AudioTrack(id: 't2', assetId: 'aud1'),
      ],
    );

    test('repoints only this track; the old asset stays', () {
      final c = editorContainer(tracks());
      final r = expectRoundTrip(c, const SetAudioTrackAsset('t1', 'aud2'));
      expect(r.label, 'Replace sound');
      expect(c.doc.audioTracks[0].assetId, 'aud2');
      expect(c.doc.audioTracks[0].volume, 0.5);
      expect(c.doc.audioTracks[0].loop, isTrue);
      expect(c.doc.audioTracks[1].assetId, 'aud1');
      expect(c.doc.assets.keys, containsAll(['aud1', 'aud2']));
    });

    test('an unknown track or asset is refused', () {
      final c = editorContainer(tracks());
      expect(
        c.ctl.execute(const SetAudioTrackAsset('nope', 'aud2')).ok,
        isFalse,
      );
      expect(c.ctl.execute(const SetAudioTrackAsset('t1', 'nope')).ok, isFalse);
    });
  });
}
