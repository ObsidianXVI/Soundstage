import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/artboard.dart';
import 'package:soundstage_platform/editor/canvas/artboard_canvas.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/overlay/canvas_overlay.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

const _bps = [
  ir.Breakpoint(
    id: 'desktop',
    name: 'Desktop',
    minWidth: 1024,
    designSize: ir.StageSize(width: 1000, height: 800),
    primary: true,
  ),
  ir.Breakpoint(
    id: 'mobile',
    name: 'Mobile',
    minWidth: 0,
    designSize: ir.StageSize(width: 400, height: 800),
    primary: true,
  ),
  ir.Breakpoint(
    id: 'tablet',
    name: 'Tablet',
    minWidth: 600,
    designSize: ir.StageSize(width: 700, height: 800),
    inheritsFrom: 'desktop',
  ),
];

ir.ShapeNode _shape(
  String id,
  double x,
  double y,
  double w,
  double h, {
  double rotation = 0,
  ir.MotionTransform motion = const ir.MotionTransform(),
  bool visible = true,
  bool locked = false,
}) => ir.ShapeNode(
  common: ir.NodeCommon(
    id: id,
    name: id.toUpperCase(),
    x: x,
    y: y,
    width: w,
    height: h,
    rotation: rotation,
    motion: motion,
    visible: visible,
    locked: locked,
  ),
);

/// s1 (pinned 1000×800): root [
///   under (690,590 100×100),
///   a (100,50 300×300, clips) [ a1 (10,20 10×10, opacity track),
///     aOut (290,0 40×40: overflows a), a2 (40,100 100×100, no clip) [
///       a21 (150,0 20×20: overflows a2) ] ],
///   top (105,20 50×50... see below),
///   rot (500,100 100×50, rotated 90°), mot (600,400 100×100, motion +50 x),
///   locked (700,600 50×50), hidden (700,600 50×50),
/// ]
/// s2 (flow): root2 1000×2400 [ tall (0,1900 100×500) ]
ir.StageDocument canvasDoc({List<ir.Breakpoint> breakpoints = _bps}) =>
    ir.StageDocument(
      id: 'doc',
      breakpoints: breakpoints,
      scenes: [
        ir.Scene(
          id: 's1',
          name: 'One',
          kind: ir.SceneKind.pinned,
          scrollLength: 1,
          root: ir.FrameNode(
            common: const ir.NodeCommon(id: 'root', width: 1000, height: 800),
            children: [
              _shape('under', 690, 590, 100, 100),
              ir.FrameNode(
                common: const ir.NodeCommon(
                  id: 'a',
                  name: 'Card',
                  x: 100,
                  y: 50,
                  width: 300,
                  height: 300,
                ),
                clipContent: true,
                children: [
                  _shape('a1', 10, 20, 10, 10),
                  _shape('aOut', 290, 0, 40, 40),
                  ir.FrameNode(
                    common: const ir.NodeCommon(
                      id: 'a2',
                      x: 40,
                      y: 100,
                      width: 100,
                      height: 100,
                    ),
                    children: [_shape('a21', 150, 0, 20, 20)],
                  ),
                ],
              ),
              _shape('top', 105, 60, 50, 50),
              _shape('rot', 500, 100, 100, 50, rotation: 90),
              _shape(
                'mot',
                600,
                400,
                100,
                100,
                motion: const ir.MotionTransform(translateX: 50),
              ),
              _shape('locked', 700, 600, 50, 50, locked: true),
              _shape('hidden', 700, 600, 50, 50, visible: false),
            ],
          ),
          clocks: const [ir.Clock.sceneScroll(id: 'clk1', sceneId: 's1')],
          tracks: const [
            ir.Track(
              id: 'tr',
              target: 'a1',
              property: 'opacity',
              clockId: 'clk1',
              keyframes: [
                ir.Keyframe(id: 'k0', t: 0, value: ir.IrValue.number(0.25)),
                ir.Keyframe(id: 'k1', t: 1, value: ir.IrValue.number(1)),
              ],
            ),
          ],
        ),
        ir.Scene(
          id: 's2',
          name: 'Two',
          root: ir.FrameNode(
            common: const ir.NodeCommon(id: 'root2', width: 1000, height: 2400),
            children: [_shape('tall', 0, 1900, 100, 500)],
          ),
        ),
      ],
    );

class _Harness {
  _Harness(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;

  CanvasController get canvas => container.read(canvasControllerProvider);
  EditorController get ctl => container.read(editorControllerProvider.notifier);

  Future<void> camera(CanvasCamera c) async {
    canvas.setCamera(c);
    await tester.pump();
  }

  RenderArtboardCanvas get render =>
      tester.renderObject<RenderArtboardCanvas>(find.byType(ArtboardCanvas));

  /// The canvas's top-left in global coordinates.
  Offset get origin => tester.getTopLeft(find.byType(ArtboardCanvas));
}

Future<_Harness> _pump(
  WidgetTester tester, {
  ir.StageDocument? doc,
  Size size = const Size(1200, 800),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        initialDocumentProvider.overrideWithValue(doc ?? canvasDoc()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: const Scaffold(body: EditorCanvas()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(EditorCanvas)),
  );
  return _Harness(tester, container);
}

Matcher _near(Offset o, [double eps = 1e-6]) => isA<Offset>()
    .having((p) => p.dx, 'dx', closeTo(o.dx, eps))
    .having((p) => p.dy, 'dy', closeTo(o.dy, eps));

Matcher _rect(Rect r, [double eps = 1e-6]) => isA<Rect>()
    .having((p) => p.left, 'left', closeTo(r.left, eps))
    .having((p) => p.top, 'top', closeTo(r.top, eps))
    .having((p) => p.width, 'width', closeTo(r.width, eps))
    .having((p) => p.height, 'height', closeTo(r.height, eps));

void main() {
  group('artboards', () {
    testWidgets('one artboard per primary breakpoint, side by side, framed '
        'at most 100%', (tester) async {
      final h = await _pump(tester);
      expect(find.byType(Artboard), findsNWidgets(2));
      final a = h.canvas.artboards;
      expect(a.keys, ['desktop', 'mobile']);
      expect(a['desktop']!.worldRect, const Rect.fromLTWH(0, 0, 1000, 800));
      expect(
        a['mobile']!.worldRect,
        const Rect.fromLTWH(1000 + kArtboardGap, 0, 400, 800),
      );
      // The initial fit frames both, centred.
      final cam = h.canvas.camera.value;
      expect(cam.zoom, lessThanOrEqualTo(1));
      expect(
        cam.toScreen(h.canvas.contentBounds!.center),
        _near(const Offset(600, 400)),
      );
      expect(tester.takeException(), isNull);
    });

    for (final n in [1, 3]) {
      testWidgets('$n primary breakpoint(s)', (tester) async {
        final bps = [
          for (final (i, b) in _bps.indexed) b.copyWith(primary: i < n),
        ];
        final h = await _pump(tester, doc: canvasDoc(breakpoints: bps));
        expect(find.byType(Artboard), findsNWidgets(n));
        final xs = [
          for (final a in h.canvas.artboards.values) a.worldRect.left,
        ];
        expect(xs, artboardOffsets(<double>[1000, 400, 700].take(n).toList()));
      });
    }

    testWidgets('a flow scene shows its full height; pinned the viewport', (
      tester,
    ) async {
      final h = await _pump(tester);
      expect(h.canvas.artboards['desktop']!.worldRect.height, 800);
      h.ctl.setActiveScene('s2');
      await tester.pump();
      expect(h.canvas.artboards['desktop']!.worldRect.height, 2400);
      expect(h.canvas.artboards['mobile']!.worldRect.height, 2400);
      expect(h.canvas.overlay.worldRectFor('tall', 'mobile'), isNotNull);
    });

    testWidgets('clocks are frozen at the playhead', (tester) async {
      final h = await _pump(tester);
      RenderStageBox a1(String bp) => h.canvas.artboards[bp]!.registry['a1']!;
      expect(a1('desktop').effectiveOpacity, closeTo(0.25, 1e-9));
      expect(a1('mobile').effectiveOpacity, closeTo(0.25, 1e-9));
      h.ctl.setPlayhead('s1', 1);
      await tester.pump();
      expect(a1('desktop').effectiveOpacity, closeTo(1, 1e-9));
      expect(a1('mobile').effectiveOpacity, closeTo(1, 1e-9));
    });

    testWidgets('edit mode: render objects carry the edit environment', (
      tester,
    ) async {
      final h = await _pump(tester);
      final box = h.canvas.artboards['desktop']!.registry['a']!;
      expect(box.environment.mode, StageRenderMode.edit);
      expect(
        identical(
          box.environment.nodes,
          h.canvas.artboards['desktop']!.registry,
        ),
        isTrue,
      );
    });
  });

  group('free width', () {
    testWidgets('the resolved breakpoint follows the width; reset', (
      tester,
    ) async {
      final h = await _pump(tester);
      final desk = h.canvas.artboards['desktop']!;
      expect(desk.effectiveBreakpointId, 'desktop');
      expect(find.byKey(const ValueKey('width-badge')), findsNothing);

      h.canvas.setPreviewWidth('desktop', 700, designWidth: 1000);
      await tester.pump();
      expect(desk.effectiveBreakpointId, 'tablet');
      expect(desk.worldRect.width, 700);
      // The next artboard moves over.
      expect(h.canvas.artboards['mobile']!.worldRect.left, 700 + kArtboardGap);
      expect(find.text('700 px'), findsOneWidget);
      expect(find.textContaining('Tablet'), findsOneWidget);

      h.canvas.setPreviewWidth('desktop', 500, designWidth: 1000);
      await tester.pump();
      expect(desk.effectiveBreakpointId, 'mobile');

      h.canvas.setPreviewWidth('desktop', 1300, designWidth: 1000);
      await tester.pump();
      expect(desk.effectiveBreakpointId, 'desktop');
      expect(desk.worldRect.width, 1300);

      await tester.tap(find.bySemanticsLabel('Reset Desktop width'));
      await tester.pump();
      expect(h.canvas.previewWidthOf('desktop'), isNull);
      expect(desk.worldRect.width, 1000);
      expect(desk.effectiveBreakpointId, 'desktop');
    });

    testWidgets('dragging the edge handle sets the width in design pixels', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.camera(const CanvasCamera(zoom: 0.5, panX: 20, panY: 40));
      await tester.drag(
        find.byKey(const ValueKey('width-handle-desktop')),
        const Offset(-150, 0),
      );
      await tester.pump();
      // 150 screen px at 50% = 300 design px.
      expect(h.canvas.previewWidthOf('desktop'), closeTo(700, 1e-9));
      expect(h.canvas.artboards['desktop']!.effectiveBreakpointId, 'tablet');
      // Double-click resets.
      final handle = find.byKey(const ValueKey('width-handle-desktop'));
      await tester.tap(handle);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(h.canvas.previewWidthOf('desktop'), isNull);
    });
  });

  group('OverlayGeometry', () {
    const cam = CanvasCamera(zoom: 2, panX: 10, panY: 20);

    testWidgets('nested rects under zoom and pan, on every artboard', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.camera(cam);
      final g = h.canvas.overlay;
      // a21: root → a (100,50) → a2 (40,100) → (150,0) = world (290,150).
      final d = g.rectFor('a21', 'desktop')!;
      expect(d.size, const Size(20, 20));
      expect(
        d.bounds,
        _rect(cam.rectToScreen(const Rect.fromLTWH(290, 150, 20, 20))),
      );
      expect(
        g.worldRectFor('a21', 'desktop'),
        _rect(const Rect.fromLTWH(290, 150, 20, 20)),
      );
      // Mirrored on the mobile artboard, shifted by its world x.
      const mx = 1000 + kArtboardGap;
      expect(
        g.worldRectFor('a21', 'mobile'),
        _rect(const Rect.fromLTWH(mx + 290, 150, 20, 20)),
      );
      expect(g.rectFor('nope', 'desktop'), isNull);
      expect(g.rectFor('a21', 'tablet'), isNull, reason: 'no such artboard');

      // Pan and zoom again: same world rect, new screen rect.
      const cam2 = CanvasCamera(zoom: 0.25, panX: -30, panY: 5);
      await h.camera(cam2);
      expect(
        g.rectFor('a21', 'desktop')!.bounds,
        _rect(cam2.rectToScreen(const Rect.fromLTWH(290, 150, 20, 20))),
      );
    });

    testWidgets('rotated and motion-transformed nodes', (tester) async {
      final h = await _pump(tester);
      await h.camera(cam);
      final g = h.canvas.overlay;
      // 100×50 rotated 90° clockwise about its centre (550,125).
      final r = g.rectFor('rot', 'desktop')!;
      expect(r.size, const Size(100, 50));
      expect(r.corners[0], _near(cam.toScreen(const Offset(575, 75))));
      expect(r.corners[2], _near(cam.toScreen(const Offset(525, 175))));
      expect(
        g.worldRectFor('rot', 'desktop'),
        _rect(const Rect.fromLTWH(525, 75, 50, 100)),
      );
      // motion.translateX 50.
      expect(
        g.worldRectFor('mot', 'desktop'),
        _rect(const Rect.fromLTWH(650, 400, 100, 100)),
      );
      // The outline is the parallelogram.
      expect(r.outline.contains(cam.toScreen(const Offset(550, 160))), isTrue);
      expect(r.outline.contains(cam.toScreen(const Offset(510, 110))), isFalse);
    });
  });

  group('hitTest', () {
    List<String> ids(_Harness h, Offset world, {String bp = 'desktop'}) {
      final off = bp == 'mobile' ? 1000 + kArtboardGap : 0.0;
      final hits = h.canvas.overlay.hitTest(
        h.canvas.camera.value.toScreen(world + Offset(off, 0)),
      );
      for (final x in hits) {
        expect(x.breakpointId, bp);
      }
      return [for (final x in hits) x.nodeId];
    }

    testWidgets('topmost first, children before parents', (tester) async {
      final h = await _pump(tester);
      await h.camera(const CanvasCamera(zoom: 1.5, panX: -40, panY: 12));
      expect(ids(h, const Offset(112, 72)), ['top', 'a1', 'a', 'root']);
      expect(ids(h, const Offset(112, 72), bp: 'mobile'), [
        'top',
        'a1',
        'a',
        'root',
      ]);
      expect(ids(h, const Offset(5, 5)), ['root']);
      // Between the artboards: nothing.
      expect(ids(h, const Offset(1050, 100)), isEmpty);
    });

    testWidgets('clipping: a clipping frame hides overflow, others do not', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.camera(const CanvasCamera(zoom: 0.8, panX: 3, panY: 4));
      // aOut overflows `a` (which clips at x 400).
      expect(ids(h, const Offset(395, 60)), ['aOut', 'a', 'root']);
      expect(ids(h, const Offset(410, 60)), ['root']);
      // a21 overflows a2 (which does not clip) but is inside a.
      expect(ids(h, const Offset(300, 160)), ['a21', 'a', 'root']);
    });

    testWidgets('locked and hidden nodes are skipped', (tester) async {
      final h = await _pump(tester);
      await h.camera(const CanvasCamera(zoom: 0.7));
      expect(ids(h, const Offset(720, 620)), ['under', 'root']);
    });

    testWidgets('rotation and motion are respected', (tester) async {
      final h = await _pump(tester);
      await h.camera(const CanvasCamera(zoom: 1.1, panX: -100));
      expect(ids(h, const Offset(550, 160)), ['rot', 'root']);
      expect(ids(h, const Offset(510, 110)), ['root']);
      expect(ids(h, const Offset(740, 450)), ['mot', 'root']);
      expect(ids(h, const Offset(610, 450)), ['root']);
    });

    testWidgets('the hit list drives the selection rules', (tester) async {
      final h = await _pump(tester);
      final hits = ids(h, const Offset(112, 72));
      h.ctl.click(hits, const SelectionModifiers());
      expect(h.container.read(editorControllerProvider).selection, {'top'});
    });
  });

  group('performance', () {
    testWidgets('pan and zoom never rebuild, relayout or repaint artboards', (
      tester,
    ) async {
      final h = await _pump(tester);
      h.ctl.select({'a', 'rot'});
      await tester.pump();
      final builds = Artboard.debugBuildCount;
      final layouts = RenderStageBox.debugLayoutCount;
      final paints = RenderStageBox.debugPaintCount;
      final canvasPaints = h.render.debugPaintCount;
      final overlayPaints = OverlayPainter.debugPaintCount;

      for (var i = 0; i < 10; i++) {
        h.canvas.panBy(const Offset(7, -3));
        await tester.pump();
        h.canvas.zoomAbout(const Offset(300, 200), 1.1);
        await tester.pump();
      }
      // Pointer input too: wheel pans, Ctrl+wheel and pinch zoom.
      final at = h.origin + const Offset(400, 300);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: const Offset(30, 20)),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: const Offset(0, -50)),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.sendEventToBinding(
        PointerScaleEvent(position: at, scale: 1.2),
      );
      await tester.pump();

      expect(Artboard.debugBuildCount, builds, reason: 'artboard rebuilds');
      expect(RenderStageBox.debugLayoutCount, layouts, reason: 'relayouts');
      expect(RenderStageBox.debugPaintCount, paints, reason: 'stage repaints');
      expect(h.render.debugPaintCount, greaterThan(canvasPaints));
      expect(OverlayPainter.debugPaintCount, greaterThan(overlayPaints));
    });

    testWidgets('only artboards in the viewport paint', (tester) async {
      final h = await _pump(tester);
      await h.camera(const CanvasCamera(panX: 200));
      expect(h.render.debugPaintedChildren, {0});
      await h.camera(const CanvasCamera(panX: -1100));
      expect(h.render.debugPaintedChildren, {1});
      await h.camera(const CanvasCamera(zoom: 0.5));
      expect(h.render.debugPaintedChildren, {0, 1});
    });
  });

  group('camera input', () {
    testWidgets('wheel pans; Cmd/Ctrl+wheel and pinch zoom about the pointer', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.camera(const CanvasCamera(zoom: 0.5));
      final at = h.origin + const Offset(300, 200);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: const Offset(10, 40)),
      );
      await tester.pump();
      expect(
        h.canvas.camera.value,
        const CanvasCamera(zoom: 0.5, panX: -10, panY: -40),
      );

      final before = h.canvas.camera.value;
      final world = before.toWorld(const Offset(300, 200));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(position: at, scrollDelta: const Offset(0, -120)),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      final zoomed = h.canvas.camera.value;
      expect(zoomed.zoom, greaterThan(0.5));
      expect(zoomed.toScreen(world), _near(const Offset(300, 200)));

      await tester.sendEventToBinding(
        PointerScaleEvent(position: at, scale: 0.5),
      );
      await tester.pump();
      expect(h.canvas.camera.value.zoom, closeTo(zoomed.zoom / 2, 1e-9));
      expect(
        h.canvas.camera.value.toScreen(world),
        _near(const Offset(300, 200)),
      );
    });

    testWidgets('Space-drag, middle-drag and the hand tool pan', (
      tester,
    ) async {
      final h = await _pump(tester);
      await h.camera(const CanvasCamera());
      final at = h.origin + const Offset(500, 500);

      // Middle button.
      final mid = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
        buttons: kMiddleMouseButton,
      );
      await mid.moveBy(const Offset(30, 10));
      await mid.up();
      await tester.pump();
      expect(h.canvas.camera.value.pan, const Offset(30, 10));

      // Space held + primary drag.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
      await tester.pump();
      final sp = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await sp.moveBy(const Offset(-10, 5));
      await sp.up();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(h.canvas.camera.value.pan, const Offset(20, 15));

      // A plain primary drag with the move tool does not pan.
      final plain = await tester.startGesture(
        at,
        kind: PointerDeviceKind.mouse,
      );
      await plain.moveBy(const Offset(50, 50));
      await plain.up();
      await tester.pump();
      expect(h.canvas.camera.value.pan, const Offset(20, 15));

      // The hand tool.
      h.ctl.setTool(EditorTool.hand);
      await tester.pump();
      final hand = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
      await hand.moveBy(const Offset(5, 5));
      await hand.up();
      await tester.pump();
      expect(h.canvas.camera.value.pan, const Offset(25, 20));
    });

    testWidgets('fit, selection and 100% (animated)', (tester) async {
      final h = await _pump(tester);
      final c = h.canvas;
      c.zoomTo100();
      await tester.pump(const Duration(milliseconds: 50));
      expect(c.camera.value.zoom, isNot(1), reason: 'animating');
      await tester.pumpAndSettle();
      expect(c.camera.value.zoom, 1);

      expect(c.zoomToNodes(['a2'], breakpointId: 'mobile'), isTrue);
      await tester.pumpAndSettle();
      final r = c.overlay.rectFor('a2', 'mobile')!.bounds;
      expect(r.center, _near(const Offset(600, 400), 1e-3));
      expect(r.height, closeTo(800 - 96, 1e-3));

      c.zoomToFit();
      await tester.pumpAndSettle();
      final b = c.camera.value.rectToScreen(c.contentBounds!);
      expect(b.left, closeTo(48, 1e-6));
      expect(b.right, closeTo(1200 - 48, 1e-6));

      c.zoomIn();
      await tester.pumpAndSettle();
      final z = c.camera.value.zoom;
      c.zoomOut();
      await tester.pumpAndSettle();
      expect(c.camera.value.zoom, closeTo(z / kZoomStep, 1e-9));
      expect(c.zoomToNodes(['nope']), isFalse);
    });
  });
}
