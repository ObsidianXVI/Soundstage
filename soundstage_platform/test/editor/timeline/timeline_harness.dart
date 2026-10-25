import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Easing;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/shell/editor_layout.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/editor/timeline/timeline_math.dart';
import 'package:soundstage_platform/editor/timeline/timeline_model.dart';
import 'package:soundstage_platform/editor/timeline/timeline_panel.dart';
import 'package:soundstage_platform/ir/ir.dart';

import '../core/fixtures.dart';

Keyframe kf(
  String id,
  double t,
  double v, [
  Easing e = const Easing.linear(),
]) => Keyframe(id: id, t: t, value: IrValue.number(v), easing: e);

/// [fixtureDoc] with motion on scene s1:
///
/// - scroll clock `clk1`: `op` (a1 opacity: o0 @0 = 0.2, o1 @1 = 1) and
///   `bx` (b1 x: x0 @0.25 = 0, x1 @0.75 = 100);
/// - timeline clock `tl` (4 s): `tw` (b1 width: w0 @0 = 10, w1 @2 = 50).
///
/// Lanes on clk1, top to bottom: group a1, Opacity, group b1, X.
StageDocument timelineDoc({List<Track> extra = const []}) {
  final doc = fixtureDoc();
  final s1 = doc.scenes.first;
  return doc.copyWith(
    scenes: [
      s1.copyWith(
        clocks: [
          ...s1.clocks,
          const Clock.timeline(id: 'tl', duration: 4),
        ],
        tracks: [
          Track(
            id: 'op',
            target: 'a1',
            property: 'opacity',
            clockId: 'clk1',
            keyframes: [kf('o0', 0, 0.2), kf('o1', 1, 1)],
          ),
          Track(
            id: 'bx',
            target: 'b1',
            property: 'x',
            clockId: 'clk1',
            keyframes: [kf('x0', 0.25, 0), kf('x1', 0.75, 100)],
          ),
          Track(
            id: 'tw',
            target: 'b1',
            property: 'width',
            clockId: 'tl',
            keyframes: [kf('w0', 0, 10), kf('w1', 2, 50)],
          ),
          ...extra,
        ],
      ),
      doc.scenes[1],
    ],
  );
}

/// The docked editor on [doc] at 1440 × 900 with the timeline open.
Future<TimelineRig> pumpTimeline(
  WidgetTester tester, {
  StageDocument? doc,
  Size size = const Size(1440, 900),
  List<Override> overrides = const [],
  EditorAssetService? assetService,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final root = ProviderContainer(overrides: overrides);
  addTearDown(root.dispose);
  root.read(editorLayoutProvider.notifier).toggleTimeline();
  final d = doc ?? timelineDoc();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: root,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: Scaffold(
          body: EditorShell(
            document: d,
            onBack: () {},
            onPreview: () {},
            assetService: assetService,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return TimelineRig(tester, root);
}

class TimelineRig {
  TimelineRig(this.tester, this.root);

  final WidgetTester tester;

  /// The app's root container (layout state).
  final ProviderContainer root;

  /// The editor's own (scoped) container.
  ProviderContainer get c =>
      ProviderScope.containerOf(tester.element(find.byType(TimelinePanel)));

  EditorController get ctl => c.read(editorControllerProvider.notifier);
  EditorState get st => c.read(editorControllerProvider);
  TimelineController get tl => c.read(timelineControllerProvider);
  Scene get scene => st.activeScene!;

  Track track(String id) => scene.tracks.singleWhere((t) => t.id == id);
  List<double> times(String id) => [for (final k in track(id).keyframes) k.t];

  Set<KeyframeRef> get selection => tl.selection.value;

  TimelineView get view =>
      tl.views.value[TimelineController.viewKey(
        st.activeSceneId!,
        st.activeClockId!,
      )]!;

  Offset get lanesTopLeft =>
      tester.getTopLeft(find.byKey(const ValueKey<String>('timeline-lanes')));

  /// The global position of time [t] in lane row [row].
  Offset at(int row, double t) =>
      lanesTopLeft +
      Offset(view.xOf(t), row * kTimelineRowHeight + kTimelineRowHeight / 2);

  /// The global position of time [t] on the ruler.
  Offset onRuler(double t) {
    final r = tester.getTopLeft(
      find.byKey(const ValueKey<String>('timeline-ruler')),
    );
    return r + Offset(view.xOf(t), kTimelineRulerHeight / 2);
  }

  Future<void> click(Offset p) async {
    final g = await tester.startGesture(
      p,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await g.up();
    await tester.pump();
  }

  /// A mouse drag from [from] to [to] in [steps] moves.
  Future<void> drag(Offset from, Offset to, {int steps = 5}) async {
    final g = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    for (var i = 1; i <= steps; i++) {
      await g.moveTo(Offset.lerp(from, to, i / steps)!);
      await tester.pump();
    }
    await g.up();
    await tester.pump();
  }

  /// Runs [body] with [key] held.
  Future<void> holding(
    LogicalKeyboardKey key,
    Future<void> Function() body,
  ) async {
    await tester.sendKeyDownEvent(key);
    await body();
    await tester.sendKeyUpEvent(key);
  }

  Future<void> wheel(Offset at, Offset delta) async {
    final p = TestPointer(7, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(p.hover(at));
    await tester.sendEventToBinding(p.scroll(delta));
    await tester.pump();
  }
}
