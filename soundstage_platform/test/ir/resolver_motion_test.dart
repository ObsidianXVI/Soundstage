import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart';

const _bps = [
  Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 1024,
    designSize: StageSize(width: 1000, height: 800),
    primary: true,
  ),
  Breakpoint(
    id: 'mobile',
    name: 'Mobile',
    minWidth: 0,
    designSize: StageSize(width: 400, height: 800),
    primary: true,
  ),
];

Track _track(
  String id,
  String property,
  double a,
  double b, {
  String target = 'f1',
  List<String>? breakpoints,
}) => Track(
  id: id,
  target: target,
  property: property,
  clockId: 'scroll',
  breakpoints: breakpoints,
  keyframes: [
    Keyframe(id: '${id}a', t: 0, value: IrValue.number(a)),
    Keyframe(id: '${id}b', t: 1, value: IrValue.number(b)),
  ],
);

StageDocument _doc(List<Track> tracks) => StageDocument(
  id: 'doc',
  breakpoints: _bps,
  scenes: [
    Scene(
      id: 's1',
      kind: SceneKind.pinned,
      root: const FrameNode(
        common: NodeCommon(id: 'root', width: 1000, height: 800),
        children: [
          FrameNode(
            common: NodeCommon(id: 'f1', x: 5, width: 100, height: 100),
          ),
          FrameNode(common: NodeCommon(id: 'f2', width: 100, height: 100)),
        ],
      ),
      clocks: const [Clock.sceneScroll(id: 'scroll', sceneId: 's1')],
      tracks: tracks,
    ),
  ],
);

List<String> _ids(ResolvedDocument d) => [
  for (final t in d.scenes.single.tracks) t.id,
];

void main() {
  group('breakpoint precedence', () {
    test('a breakpoint-specific track wins over an all-breakpoints track', () {
      final doc = _doc([
        _track('all', 'opacity', 0, 1),
        _track('mob', 'opacity', 1, 0, breakpoints: ['mobile']),
        _track('x', 'x', 0, 10),
      ]);
      final desktop = resolveDocument(
        doc,
        const ResolveContext(breakpointId: 'desktop'),
      );
      final mobile = resolveDocument(
        doc,
        const ResolveContext(breakpointId: 'mobile'),
      );
      expect(_ids(desktop), ['all', 'x']);
      expect(_ids(mobile), ['mob', 'x']);
    });

    test('the all-breakpoints track still applies to other nodes', () {
      final doc = _doc([
        _track('all', 'opacity', 0, 1, target: 'f2'),
        _track('mob', 'opacity', 1, 0, breakpoints: ['mobile']),
      ]);
      final mobile = resolveDocument(
        doc,
        const ResolveContext(breakpointId: 'mobile'),
      );
      expect(_ids(mobile), ['all', 'mob']);
    });
  });

  group('track memo', () {
    test('untouched tracks keep their resolved identity across passes', () {
      final doc = _doc([_track('a', 'opacity', 0, 1), _track('b', 'x', 0, 9)]);
      final resolver = Resolver();
      const ctx = ResolveContext(breakpointId: 'desktop');
      final first = resolver.resolve(doc, ctx);
      // Edit one track's keyframes.
      final edited = moveKeyframes(doc, 's1', {
        'b': {'bb': 0.5},
      }).document;
      final second = resolver.resolve(edited, ctx);
      final t1 = first.scenes.single.tracks, t2 = second.scenes.single.tracks;
      expect(identical(t1[0], t2[0]), isTrue);
      expect(identical(t1[1], t2[1]), isFalse);
      expect(t2[1].keyframes.last.t, 0.5);
    });

    test('a motion-only edit keeps the memo for the next tree edit', () {
      final doc = _doc([_track('a', 'opacity', 0, 1), _track('b', 'x', 0, 9)]);
      final resolver = Resolver();
      const ctx = ResolveContext(breakpointId: 'desktop');
      resolver.resolve(doc, ctx);
      // The scene root is untouched: the pass hits at the root.
      final keyed = moveKeyframes(doc, 's1', {
        'a': {'ab': 0.5},
      }).document;
      final mid = resolver.resolve(keyed, ctx);
      // A tree edit next must still reuse the untouched sibling and track.
      final moved = updateNode(
        keyed,
        'f1',
        (n) => n.copyWith(common: n.common.copyWith(y: 3)),
      ).document;
      final last = resolver.resolve(moved, ctx);
      expect(identical(mid.nodeIndex['f2'], last.nodeIndex['f2']), isTrue);
    });

    test('a target edit re-resolves its tracks', () {
      final doc = _doc([_track('a', 'opacity', 0, 1)]);
      final resolver = Resolver();
      const ctx = ResolveContext(breakpointId: 'desktop');
      final first = resolver.resolve(doc, ctx);
      final edited = updateNode(
        doc,
        'f1',
        (n) => n.copyWith(common: n.common.copyWith(x: 50)),
      ).document;
      final second = resolver.resolve(edited, ctx);
      expect(
        identical(
          first.scenes.single.tracks[0],
          second.scenes.single.tracks[0],
        ),
        isFalse,
      );
      expect(second.scenes.single.tracks[0], first.scenes.single.tracks[0]);
    });
  });

  group('explainAt', () {
    test('adds the animated layer at the playhead', () {
      final doc = _doc([_track('a', 'opacity', 0, 1)]);
      final r = Resolver();
      const ctx = ResolveContext(breakpointId: 'desktop');
      r.resolve(doc, ctx);
      final p = r.explainAt(doc, 'f1', const PropertyPath('opacity'), {
        'scroll': 0.25,
      }, ctx);
      expect(p.entries.last.source, const ProvenanceSource.animated('a'));
      expect(p.entries.last.value, const IrValue.number(0.25));
      expect(p.finalValue, const IrValue.number(0.25));
      // Without clock values, tracks are ignored.
      final plain = r.explain(doc, 'f1', const PropertyPath('opacity'), ctx);
      expect(plain.entries.any((e) => e.source is AnimatedSource), isFalse);
      expect(plain.finalValue, const IrValue.number(1));
    });

    test('absent clocks read 0; other properties are not animated', () {
      final doc = _doc([_track('a', 'opacity', 0.2, 1)]);
      final r = Resolver();
      final p = r.explainAt(doc, 'f1', const PropertyPath('opacity'), {});
      expect(p.finalValue, const IrValue.number(0.2));
      final x = r.explainAt(doc, 'f1', const PropertyPath('x'), {'scroll': 1});
      expect(x.entries.any((e) => e.source is AnimatedSource), isFalse);
      expect(x.finalValue, const IrValue.number(5));
    });

    test('only the track that applies at the breakpoint is shown', () {
      final doc = _doc([
        _track('all', 'opacity', 0, 1),
        _track('mob', 'opacity', 1, 0, breakpoints: ['mobile']),
      ]);
      final r = Resolver();
      final mobile = r.explainAt(
        doc,
        'f1',
        const PropertyPath('opacity'),
        {'scroll': 0.25},
        const ResolveContext(breakpointId: 'mobile'),
      );
      expect(
        [
          for (final e in mobile.entries)
            if (e.source case AnimatedSource(:final trackId)) trackId,
        ],
        ['mob'],
      );
      expect(mobile.finalValue, const IrValue.number(0.75));
    });

    test('a track on a field shows on its container path', () {
      final base = _doc(const []);
      final withFill = updateNode(
        base,
        'f1',
        (n) => (n as FrameNode).copyWith(
          appearance: const Appearance(
            fills: [Paint.solid(id: 'p', color: StageColor.white)],
          ),
        ),
      ).document;
      final doc = addTrack(
        withFill,
        's1',
        const Track(
          id: 'c',
          target: 'f1',
          property: 'fills.p.color',
          clockId: 'scroll',
          keyframes: [
            Keyframe(id: 'c0', t: 0, value: IrValue.color(StageColor.white)),
            Keyframe(id: 'c1', t: 1, value: IrValue.color(StageColor.black)),
          ],
        ),
      ).document;
      final p = Resolver().explainAt(doc, 'f1', const PropertyPath('fills'), {
        'scroll': 1,
      });
      expect(p.entries.last.source, const ProvenanceSource.animated('c'));
      expect(
        p.finalValue,
        const IrValue.paints([Paint.solid(id: 'p', color: StageColor.black)]),
      );
    });
  });
}
