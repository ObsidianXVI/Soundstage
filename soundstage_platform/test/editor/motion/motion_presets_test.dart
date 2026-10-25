import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/motion/motion_presets.dart';
import 'package:soundstage_platform/ir/ir.dart';

import '../core/fixtures.dart';

// m2.md "Motion presets": each preset writes ordinary tracks and keyframes
// as one undo step, relative to the node's static values, over a clock
// range, honouring the edit scope, merging into existing tracks inside the
// range only.

StageDocument _doc() {
  final d = fixtureDoc();
  final s1 = d.scenes.first;
  return d.copyWith(
    scenes: [
      s1.copyWith(
        clocks: [
          ...s1.clocks,
          const Clock.timeline(id: 'tl', duration: 4),
        ],
      ),
      d.scenes[1],
    ],
  );
}

const _linear = Easing.linear();

MotionPresetSpec _spec(
  MotionPresetKind kind,
  PresetDirection direction,
  String clock, {
  double? amount,
  Easing easing = const Easing.preset(EasingPreset.easeOut),
}) {
  final scroll = clock == 'clk1';
  final c = scroll
      ? const Clock.sceneScroll(id: 'clk1', sceneId: 's1')
      : const Clock.timeline(id: 'tl', duration: 4);
  final span = scroll ? (0.0, 1.0) : (0.0, 4.0);
  return defaultPresetSpec(
    kind,
    c,
    span,
    direction: direction,
  ).copyWith(amount: amount ?? kind.defaultAmount, easing: easing);
}

List<Track> _tracks(ProviderContainer c) => c.st.document.scenes.first.tracks;

Track _track(ProviderContainer c, String target, String property) =>
    _tracks(c).singleWhere((t) => t.target == target && t.property == property);

List<Effect> _effects(ProviderContainer c) =>
    (PropertyRegistry.standard.get(c.node('a1'), 'effects') as EffectsValue)
        .value;

List<double> _times(Track t) => [for (final k in t.keyframes) k.t];
List<double> _values(Track t) => [
  for (final k in t.keyframes) (k.value as NumberValue).value,
];

/// The properties each preset animates, with the node's rest value and the
/// offset value at distance/amount `a`.
Map<String, (double rest, double away)> _channels(
  MotionPresetKind kind,
  double a,
) => switch (kind) {
  MotionPresetKind.fade => {'opacity': (1, 0)},
  MotionPresetKind.rise => {'motion.translateY': (0, a)},
  MotionPresetKind.fall => {'motion.translateY': (0, -a)},
  MotionPresetKind.slideLeft => {'motion.translateX': (0, a)},
  MotionPresetKind.slideRight => {'motion.translateX': (0, -a)},
  MotionPresetKind.scaleIn => {
    'motion.scaleX': (1, a),
    'motion.scaleY': (1, a),
  },
  MotionPresetKind.blurIn => {'effects.fx.blur': (0, a)},
  MotionPresetKind.parallax => {'motion.translateY': (a, -a)},
};

void main() {
  const ids = {'clk1', 'tl'};
  final clockRanges = {
    'clk1': (inR: (0.0, 0.3), outR: (0.7, 1.0)),
    'tl': (inR: (0.0, 0.6), outR: (3.4, 4.0)),
  };

  group('every preset x direction x clock kind', () {
    for (final kind in MotionPresetKind.values) {
      for (final direction in PresetDirection.values) {
        for (final clock in ids) {
          if (kind.scrollOnly &&
              (clock != 'clk1' || direction != PresetDirection.inward)) {
            continue;
          }
          test('${kind.name} ${direction.name} on $clock', () {
            final c = editorContainer(_doc());
            final spec = _spec(kind, direction, clock);
            final r = expectRoundTrip(
              c,
              ApplyMotionPreset('s1', ['a1'], spec, ids: IdGenerator.seeded(1)),
            );
            expect(r.label, startsWith('Add '));
            final a = kind.defaultAmount;
            final channels = _channels(kind, a);
            expect(_tracks(c), hasLength(channels.length));
            final ranges = clockRanges[clock]!;
            expect({
              for (final t in _tracks(c))
                t.property.startsWith('effects.')
                    ? 'effects.fx.blur'
                    : t.property,
            }, channels.keys.toSet());
            for (final t in _tracks(c)) {
              final key = t.property.startsWith('effects.')
                  ? 'effects.fx.blur'
                  : t.property;
              final (rest, away) = channels[key]!;
              expect(t.target, 'a1');
              expect(t.clockId, clock);
              expect(t.breakpoints, isNull);
              final inKeys = <(double, double)>[
                (ranges.inR.$1, away),
                (ranges.inR.$2, rest),
              ];
              final outKeys = <(double, double)>[
                (ranges.outR.$1, rest),
                (ranges.outR.$2, away),
              ];
              final want = kind.scrollOnly
                  ? [(0.0, away), (1.0, rest)]
                  : [
                      if (direction.hasIn) ...inKeys,
                      if (direction.hasOut) ...outKeys,
                    ];
              expect(_times(t), [for (final k in want) k.$1]);
              expect(_values(t), [for (final k in want) closeTo(k.$2, 1e-9)]);
              // The easing starts each move; the rest key is linear.
              expect(t.keyframes.first.easing, spec.easing);
              expect(t.keyframes[1].easing, _linear);
              if (direction == PresetDirection.inOut && !kind.scrollOnly) {
                expect(t.keyframes[2].easing, spec.easing);
              }
            }
          });
        }
      }
    }
  });

  test('values are relative to the static values', () {
    final c = editorContainer(_doc());
    c.ctl.execute(
      SetProperty(['a1'], 'motion.translateY', const IrValue.number(10)),
    );
    c.ctl.execute(SetProperty(['a1'], 'opacity', const IrValue.number(0.5)));
    c.ctl.execute(
      SetProperty(['a1'], 'motion.scaleX', const IrValue.number(2)),
    );
    c.ctl.execute(
      ApplyMotionPreset('s1', [
        'a1',
      ], _spec(MotionPresetKind.rise, PresetDirection.inward, 'clk1')),
    );
    expect(_values(_track(c, 'a1', 'motion.translateY')), [50, 10]);
    c.ctl.execute(
      ApplyMotionPreset('s1', [
        'a1',
      ], _spec(MotionPresetKind.fade, PresetDirection.inward, 'clk1')),
    );
    expect(_values(_track(c, 'a1', 'opacity')), [0, 0.5]);
    c.ctl.execute(
      ApplyMotionPreset('s1', [
        'a1',
      ], _spec(MotionPresetKind.scaleIn, PresetDirection.inward, 'clk1')),
    );
    expect(_values(_track(c, 'a1', 'motion.scaleX')), [1.6, 2]);
    // The static values themselves are untouched.
    expect(
      (c.node('a1').common.motion.translateY, c.node('a1').common.opacity),
      (10, 0.5),
    );
  });

  test('a custom amount and range', () {
    final c = editorContainer(_doc());
    final spec = _spec(
      MotionPresetKind.slideLeft,
      PresetDirection.inward,
      'tl',
      amount: 120,
    ).copyWith(inRange: (0.5, 1.5));
    c.ctl.execute(ApplyMotionPreset('s1', ['a1'], spec));
    final t = _track(c, 'a1', 'motion.translateX');
    expect(_times(t), [0.5, 1.5]);
    expect(_values(t), [120, 0]);
  });

  group('merging into an existing track', () {
    Track existing() => const Track(
      id: 'op',
      target: 'a1',
      property: 'opacity',
      clockId: 'clk1',
      keyframes: [
        Keyframe(id: 'o0', t: 0, value: IrValue.number(0.2)),
        Keyframe(id: 'o1', t: 0.1, value: IrValue.number(0.4)),
        Keyframe(id: 'o2', t: 0.5, value: IrValue.number(0.9)),
        Keyframe(id: 'o3', t: 0.8, value: IrValue.number(0.7)),
        Keyframe(id: 'o4', t: 1, value: IrValue.number(1)),
      ],
    );

    ProviderContainer withTrack() {
      final d = _doc();
      final s1 = d.scenes.first;
      return editorContainer(
        d.copyWith(
          scenes: [
            s1.copyWith(tracks: [existing()]),
            d.scenes[1],
          ],
        ),
      );
    }

    test('In replaces only the keyframes inside its range', () {
      final c = withTrack();
      expectRoundTrip(
        c,
        ApplyMotionPreset('s1', [
          'a1',
        ], _spec(MotionPresetKind.fade, PresetDirection.inward, 'clk1')),
      );
      final t = _track(c, 'a1', 'opacity');
      expect(t.id, 'op');
      // o0 and o1 (inside 0..0.3) are replaced by the preset's two keys.
      expect(_times(t), [0, 0.3, 0.5, 0.8, 1]);
      expect(_values(t), [0, 1, 0.9, 0.7, 1]);
      expect(t.keyframes.map((k) => k.id), containsAll(['o2', 'o3', 'o4']));
      expect(_tracks(c), hasLength(1));
    });

    test('Out replaces only the last range; In-out replaces both', () {
      final c = withTrack();
      c.ctl.execute(
        ApplyMotionPreset('s1', [
          'a1',
        ], _spec(MotionPresetKind.fade, PresetDirection.outward, 'clk1')),
      );
      var t = _track(c, 'a1', 'opacity');
      expect(_times(t), [0, 0.1, 0.5, 0.7, 1]);
      expect(_values(t), [0.2, 0.4, 0.9, 1, 0]);
      c.ctl.undo();
      c.ctl.execute(
        ApplyMotionPreset('s1', [
          'a1',
        ], _spec(MotionPresetKind.fade, PresetDirection.inOut, 'clk1')),
      );
      t = _track(c, 'a1', 'opacity');
      expect(_times(t), [0, 0.3, 0.5, 0.7, 1]);
      expect(_values(t), [0, 1, 0.9, 1, 0]);
    });

    test('a track on another clock is left alone', () {
      final c = withTrack();
      c.ctl.execute(
        ApplyMotionPreset('s1', [
          'a1',
        ], _spec(MotionPresetKind.fade, PresetDirection.inward, 'tl')),
      );
      expect(_tracks(c), hasLength(2));
      expect(_times(_tracks(c).first), [0, 0.1, 0.5, 0.8, 1]);
    });
  });

  group('edit scope', () {
    test('This breakpoint writes breakpoint-specific tracks', () {
      final c = editorContainer(_doc());
      c.ctl.setEditScope(EditScope.thisBreakpoint);
      c.ctl.execute(
        ApplyMotionPreset('s1', [
          'a1',
        ], _spec(MotionPresetKind.fade, PresetDirection.inward, 'clk1')),
      );
      expect(_track(c, 'a1', 'opacity').breakpoints, [c.st.breakpointId]);
    });

    test('This breakpoint ignores an all-breakpoints track and adds its own; '
        'a second run merges into it', () {
      final d = _doc();
      final s1 = d.scenes.first;
      final c = editorContainer(
        d.copyWith(
          scenes: [
            s1.copyWith(
              tracks: [
                const Track(
                  id: 'all',
                  target: 'a1',
                  property: 'opacity',
                  clockId: 'clk1',
                  keyframes: [
                    Keyframe(id: 'k0', t: 0, value: IrValue.number(0.5)),
                    Keyframe(id: 'k1', t: 1, value: IrValue.number(1)),
                  ],
                ),
              ],
            ),
            d.scenes[1],
          ],
        ),
      );
      c.ctl.setEditScope(EditScope.thisBreakpoint);
      final spec = _spec(MotionPresetKind.fade, PresetDirection.inward, 'clk1');
      c.ctl.execute(ApplyMotionPreset('s1', ['a1'], spec));
      expect(_tracks(c), hasLength(2));
      expect(_tracks(c).first.id, 'all');
      expect(_tracks(c).first.keyframes, hasLength(2));
      c.ctl.execute(ApplyMotionPreset('s1', ['a1'], spec));
      expect(_tracks(c), hasLength(2));
      expect(_tracks(c).last.keyframes, hasLength(2));
    });
  });

  group('selection and failures', () {
    test('several nodes get a track each, in one undo step', () {
      final c = editorContainer(_doc());
      final spec = _spec(MotionPresetKind.scaleIn, PresetDirection.inOut, 'tl');
      expectRoundTrip(c, ApplyMotionPreset('s1', ['a1', 'b1'], spec));
      expect(_tracks(c), hasLength(4));
      expect(c.st.history.undoLabel, isNot('Delete track'));
      expect(c.ctl.undo(), isTrue);
      expect(_tracks(c), isEmpty);
    });

    test(
      'blur-in animates the first layer blur, adding one at 0 if needed',
      () {
        final c = editorContainer(_doc());
        final spec = _spec(
          MotionPresetKind.blurIn,
          PresetDirection.inward,
          'clk1',
        );
        c.ctl.execute(ApplyMotionPreset('s1', ['a1'], spec));
        final effects = _effects(c);
        expect(effects.whereType<LayerBlur>(), hasLength(1));
        final blur = effects.whereType<LayerBlur>().single;
        expect(blur.radius, 0);
        final t = _tracks(c).single;
        expect(t.property, 'effects.${blur.id}.blur');
        expect(_values(t), [12, 0]);
        // Applying again reuses that blur.
        c.ctl.execute(ApplyMotionPreset('s1', ['a1'], spec));
        expect((_effects(c)).whereType<LayerBlur>(), hasLength(1));
        expect(_tracks(c), hasLength(1));
      },
    );

    test('a bad scene or clock fails without recording', () {
      final c = editorContainer(_doc());
      final spec = _spec(MotionPresetKind.fade, PresetDirection.inward, 'clk1');
      expect(
        c.ctl.execute(ApplyMotionPreset('nope', ['a1'], spec)).ok,
        isFalse,
      );
      expect(
        c.ctl
            .execute(
              ApplyMotionPreset('s1', ['a1'], spec.copyWith(clockId: 'zz')),
            )
            .ok,
        isFalse,
      );
      expect(c.st.history.canUndo, isFalse);
    });

    test('a node outside the scene fails and the preset is not stored', () {
      final c = editorContainer(_doc());
      final spec = _spec(MotionPresetKind.fade, PresetDirection.inward, 'clk1');
      expect(c.ctl.execute(ApplyMotionPreset('s1', ['c'], spec)).ok, isFalse);
      c.ctl.execute(ApplyMotionPreset('s1', ['a1'], spec));
      // The document holds tracks only: no preset id anywhere.
      expect(c.doc.toJson().toString(), isNot(contains('fade')));
    });
  });

  group('spec helpers', () {
    test('default ranges: 30 % of scroll, 0.6 s of a timeline', () {
      final (i, o) = defaultPresetRanges(
        const Clock.sceneScroll(id: 'c', sceneId: 's'),
        (0, 1),
      );
      expect(i.$1, 0);
      expect(i.$2, closeTo(0.3, 1e-9));
      expect(o.$1, closeTo(0.7, 1e-9));
      expect(o.$2, 1);
      final (ti, to) = defaultPresetRanges(
        const Clock.timeline(id: 't', duration: 5),
        (0, 5),
      );
      expect(ti, (0, 0.6));
      expect(to.$1, closeTo(4.4, 1e-9));
      expect(to.$2, 5);
      // A short timeline keeps the two ranges apart.
      final (si, so) = defaultPresetRanges(
        const Clock.timeline(id: 't', duration: 1),
        (0, 1),
      );
      expect(si, (0, 0.5));
      expect(so, (0.5, 1));
    });

    test('validation', () {
      final base = _spec(MotionPresetKind.fade, PresetDirection.inOut, 'clk1');
      expect(validatePresetSpec(base, (0, 1)), isNull);
      expect(
        validatePresetSpec(base.copyWith(inRange: (0.4, 0.2)), (0, 1)),
        contains('In'),
      );
      expect(
        validatePresetSpec(base.copyWith(outRange: (0.2, 0.9)), (0, 1)),
        contains('Out must start after In ends'),
      );
    });
  });
}
