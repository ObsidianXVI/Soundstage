import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart';

import 'fixtures.dart';

// The T2.0 follow-ups decided on 26/10/26 (DECISIONS "T2.0 open points
// answered") and the registry's display names.

Keyframe _kf(String id, double t, IrValue v) => Keyframe(id: id, t: t, value: v);

const _red = StageColor(r: 1, g: 0, b: 0);
const _green = StageColor(r: 0, g: 1, b: 0);
const _blue = StageColor(r: 0, g: 0, b: 1);
const _yellow = StageColor(r: 1, g: 1, b: 0);

/// [fixtureDoc] with frame `a` filled by two solids (`p1` red, `p2` blue),
/// a pointer clock `px` over `a`, and [tracks] on s1.
StageDocument _doc({List<Track> tracks = const []}) {
  final doc = fixtureDoc();
  final filled = updateNode(doc, 'a', (n) {
    final f = n as FrameNode;
    return f.copyWith(
      appearance: f.appearance.copyWith(
        fills: const [
          Paint.solid(id: 'p1', color: _red),
          Paint.solid(id: 'p2', color: _blue),
        ],
      ),
    );
  }).document;
  final s1 = filled.scenes.first;
  return filled.copyWith(
    scenes: [
      s1.copyWith(
        clocks: [
          ...s1.clocks,
          const Clock.pointer(id: 'px', frameId: 'a'),
        ],
        tracks: tracks,
      ),
      filled.scenes[1],
    ],
  );
}

Track _track(EditorState s, String target, String property) => s
    .document
    .scenes
    .first
    .tracks
    .singleWhere((t) => t.target == target && t.property == property);

void main() {
  test('T2.0-1: auto-key on a pointer clock writes the start keyframe at 0', () {
    final c = editorContainer(_doc());
    c.ctl
      ..setActiveClock('s1', 'px')
      ..setActivePlayhead(0.5)
      ..setAutoKey(true);
    expectRoundTrip(c, SetProperty(['b1'], 'x', const IrValue.number(40)));
    final t = _track(c.st, 'b1', 'x');
    expect(t.clockId, 'px');
    expect(t.keyframes.map((k) => (k.t, k.value)), [
      (0.0, const IrValue.number(1)),
      (0.5, const IrValue.number(40)),
    ]);
  });

  group('T2.0-2: a whole-stack write over an animated sub-path is split', () {
    final colorTrack = Track(
      id: 'fc',
      target: 'a',
      property: 'fills.p1.color',
      clockId: 'clk1',
      keyframes: [_kf('c0', 0, const IrValue.color(_red))],
    );

    test('the animated colour gets a keyframe, the rest goes static', () {
      final c = editorContainer(_doc(tracks: [colorTrack]));
      c.ctl.setActivePlayhead(0.5);
      expectRoundTrip(
        c,
        SetProperty(
          ['a'],
          'fills',
          const IrValue.paints([
            Paint.solid(id: 'p1', color: _green),
            Paint.solid(id: 'p2', color: _yellow, opacity: 0.5),
          ]),
        ),
      );
      final t = _track(c.st, 'a', 'fills.p1.color');
      expect(t.keyframes.map((k) => (k.t, k.value)), [
        (0.0, const IrValue.color(_red)),
        (0.5, const IrValue.color(_green)),
      ]);
      final fills = (c.node('a') as FrameNode).appearance.fills;
      // p1's static colour stays as it was (hidden under its track); p2
      // takes the new static values.
      expect(fills, const [
        Paint.solid(id: 'p1', color: _red),
        Paint.solid(id: 'p2', color: _yellow, opacity: 0.5),
      ]);
    });

    test('a removed paint leaves its track alone', () {
      final c = editorContainer(_doc(tracks: [colorTrack]));
      c.ctl.execute(
        SetProperty(
          ['a'],
          'fills',
          const IrValue.paints([Paint.solid(id: 'p2', color: _yellow)]),
        ),
      );
      expect(_track(c.st, 'a', 'fills.p1.color').keyframes, hasLength(1));
      expect((c.node('a') as FrameNode).appearance.fills, const [
        Paint.solid(id: 'p2', color: _yellow),
      ]);
    });

    test('auto-key creates no whole-stack track beside sub-path tracks', () {
      final c = editorContainer(_doc(tracks: [colorTrack]));
      c.ctl
        ..setAutoKey(true)
        ..setActivePlayhead(0.5);
      c.ctl.execute(
        SetProperty(
          ['a'],
          'fills',
          const IrValue.paints([
            Paint.solid(id: 'p1', color: _green),
            Paint.solid(id: 'p2', color: _yellow),
          ]),
        ),
      );
      expect(c.doc.scenes.first.tracks.map((t) => t.property), [
        'fills.p1.color',
      ]);
    });
  });

  test('T2.0-3: a nudge of an animated position starts from the playhead', () {
    final c = editorContainer(
      _doc(
        tracks: [
          Track(
            id: 'bx',
            target: 'b1',
            property: 'x',
            clockId: 'clk1',
            keyframes: [
              _kf('x0', 0, const IrValue.number(0)),
              _kf('x1', 1, const IrValue.number(100)),
            ],
          ),
        ],
      ),
    );
    c.ctl.setActivePlayhead(0.5);
    c.ctl.execute(const NudgeNodes(['b1'], 1, 0));
    final t = _track(c.st, 'b1', 'x');
    expect(t.keyframes.map((k) => (k.t, k.value)), [
      (0.0, const IrValue.number(0)),
      (0.5, const IrValue.number(51)),
      (1.0, const IrValue.number(100)),
    ]);
    // The static x is untouched.
    expect(c.node('b1').common.x, 1);
  });

  test('registry display names', () {
    String name(String path) =>
        PropertyRegistry.standard.lookup(path)!.displayName;
    expect(name('x'), 'X');
    expect(name('opacity'), 'Opacity');
    expect(name('motion.translateX'), 'Translate X');
    expect(name('fills.p1.color'), 'Fill color');
    expect(name('strokes.paints.p1.opacity'), 'Stroke opacity');
    expect(name('effects.e1.blur'), 'Effect blur');
    expect(name('cornerRadius.tl'), 'Corner radius top left');
    expect(name('style.fontSize'), 'Font size');
    expect(name('content.0.spans.1.style.fontSize'), 'Span font size');
    expect(name('style.openType.liga'), 'OpenType feature');
    expect(name('layoutChild.minWidth'), 'Min width');
    for (final d in PropertyRegistry.standard.descriptors) {
      expect(d.displayName, isNotEmpty, reason: d.pathPattern);
      expect(d.displayName, isNot(contains('<')), reason: d.pathPattern);
    }
  });
}
