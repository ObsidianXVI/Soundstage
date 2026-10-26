import 'package:flutter/material.dart' hide Easing;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'inspector_harness.dart';

// m2.md "Inspector": keyframe toggles (◇ / ◆ / half) with ‹ › on every
// animatable row, values at the playhead, the "Animated" badge, and the
// Motion section.

ir.StageDocument _doc({List<ir.Track> tracks = const []}) {
  final d = inspectorDoc([rect('r', x: 10, y: 20)]);
  final s = d.scenes.single;
  return d.copyWith(scenes: [s.copyWith(tracks: tracks)]);
}

ir.Track _xTrack() => const ir.Track(
  id: 'tx',
  target: 'r',
  property: 'x',
  clockId: 'clk1',
  keyframes: [
    ir.Keyframe(id: 'k0', t: 0, value: ir.IrValue.number(0)),
    ir.Keyframe(id: 'k1', t: 1, value: ir.IrValue.number(100)),
  ],
);

EditorState _st(ProviderContainer c) => c.read(editorControllerProvider);
List<ir.Track> _tracks(ProviderContainer c) =>
    _st(c).document.scenes.single.tracks;

Finder _key(String k) => find.byKey(ValueKey<String>(k));

void main() {
  testWidgets('◇ adds a keyframe at the playhead (a new track), ◆ removes '
      'it with the track', (tester) async {
    final c = await pumpInspector(tester, _doc(), select: {'r'});
    c.read(editorControllerProvider.notifier).setActivePlayhead(0.3);
    await tester.pump();
    expect(_key('kf-toggle:x'), findsOneWidget);
    expect(_key('kf-prev:x'), findsNothing); // not animated: no ‹ ›
    await tester.tap(_key('kf-toggle:x'));
    await tester.pump();
    final t = _tracks(c).single;
    expect(
      (t.target, t.property, t.clockId, t.breakpoints),
      ('r', 'x', 'clk1', null),
    );
    expect(t.keyframes.single.t, 0.3);
    expect(t.keyframes.single.value, const ir.IrValue.number(10));
    expect(keyframeNavFor(_st(c), ['r'], 'x').mark, KeyframeMark.atPlayhead);
    expect(find.bySemanticsLabel('Remove keyframe'), findsOneWidget);
    // The badge names the layer.
    expect(find.byKey(const ValueKey('value-source-dot')), findsWidgets);
    await tester.tap(_key('kf-toggle:x'));
    await tester.pump();
    expect(_tracks(c), isEmpty);
    expect(_st(c).history.undoLabel, 'Delete keyframe');
  });

  testWidgets('This breakpoint: a new track is for the edited breakpoint', (
    tester,
  ) async {
    final c = await pumpInspector(tester, _doc(), select: {'r'});
    c
        .read(editorControllerProvider.notifier)
        .setEditScope(EditScope.thisBreakpoint);
    await tester.pump();
    await tester.tap(_key('kf-toggle:y'));
    await tester.pump();
    expect(_tracks(c).single.breakpoints, ['desktop']);
  });

  testWidgets('half-filled between keyframes; ‹ › jump; the field shows the '
      'value at the playhead', (tester) async {
    final c = await pumpInspector(
      tester,
      _doc(tracks: [_xTrack()]),
      select: {'r'},
    );
    final ctl = c.read(editorControllerProvider.notifier);
    ctl.setActivePlayhead(0.5);
    await tester.pump();
    expect(keyframeNavFor(_st(c), ['r'], 'x').mark, KeyframeMark.elsewhere);
    expect(
      find.bySemanticsLabel('Add keyframe at the playhead'),
      findsOneWidget,
    );
    // The X field shows the animated value, 50.
    expect(tester.widget<EditableText>(fieldText('x')).controller.text, '50');
    await tester.tap(_key('kf-next:x'));
    await tester.pump();
    expect(_st(c).playhead, 1);
    expect(keyframeNavFor(_st(c), ['r'], 'x').mark, KeyframeMark.atPlayhead);
    await tester.tap(_key('kf-prev:x'));
    await tester.pump();
    expect(_st(c).playhead, 0);
    // Back between keyframes, the toggle keys the value shown.
    ctl.setActivePlayhead(0.25);
    await tester.pump();
    await tester.tap(_key('kf-toggle:x'));
    await tester.pump();
    expect(_tracks(c).single.keyframes.map((k) => (k.t, k.value)), [
      (0.0, const ir.IrValue.number(0)),
      (0.25, const ir.IrValue.number(25)),
      (1.0, const ir.IrValue.number(100)),
    ]);
  });

  testWidgets('step-valued rows have no keyframe toggle', (tester) async {
    await pumpInspector(tester, _doc(), select: {'r'});
    expect(_key('kf-toggle:x'), findsOneWidget);
    expect(_key('kf-toggle:visible'), findsNothing);
    expect(_key('kf-toggle:flipX'), findsNothing);
  });

  testWidgets('Motion section: tracks with clock, count and easing; delete; '
      'Add preset is stubbed', (tester) async {
    final eased = _xTrack().copyWith(
      keyframes: [
        _xTrack().keyframes.first.copyWith(
          easing: const ir.Easing.preset(ir.EasingPreset.easeOut),
        ),
        _xTrack().keyframes.last,
      ],
    );
    final c = await pumpInspector(
      tester,
      _doc(tracks: [eased]),
      select: {'r'},
      height: 2400,
    );
    expect(_key('motion-section'), findsOneWidget);
    expect(_key('motion-track:tx'), findsOneWidget);
    expect(
      find.descendant(of: _key('motion-track:tx'), matching: find.text('X')),
      findsOneWidget,
    );
    expect(find.text('Scene scroll · 2 keyframes · Ease out'), findsOneWidget);
    expect(_key('motion-add-preset'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Delete track X'));
    await tester.pump();
    expect(_tracks(c), isEmpty);
    expect(_key('motion-track:tx'), findsNothing);
    expect(find.textContaining('Not animated'), findsOneWidget);
  });
}
