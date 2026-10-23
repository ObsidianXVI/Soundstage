import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

const kBps = [
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
];

ir.ShapeNode rect(
  String id,
  double x,
  double y,
  double w,
  double h, {
  double rotation = 0,
  ir.LayoutChild layoutChild = const ir.LayoutChild(),
  bool locked = false,
}) => ir.ShapeNode(
  common: ir.NodeCommon(
    id: id,
    name: id,
    x: x,
    y: y,
    width: w,
    height: h,
    rotation: rotation,
    layoutChild: layoutChild,
    locked: locked,
  ),
);

/// root (pinned 1000×800) [
///   a (100,100 100×100), b (400,100 100×100), c (700,100 100×100),
///   row (100,400 340×120, horizontal auto layout, padding 10, gap 10) [
///     i1, i2, i3 (100×100 fixed) ],
///   box (600,400 300×300, free frame) [ inner (20,20 50×50) ],
///   pinR (850,650 100×50, right/bottom constraints),
///   txt (100,650 auto-width text),
///   rot (450,250 100×50, rotated 90°),
/// ]
ir.StageDocument interactionDoc() => ir.StageDocument(
  id: 'doc',
  breakpoints: kBps,
  scenes: [
    ir.Scene(
      id: 's1',
      name: 'One',
      kind: ir.SceneKind.pinned,
      scrollLength: 1,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root', width: 1000, height: 800),
        children: [
          rect('a', 100, 100, 100, 100),
          rect(
            'b',
            400,
            100,
            100,
            100,
            layoutChild: const ir.LayoutChild(maxWidth: 120),
          ),
          rect('c', 700, 100, 100, 100),
          ir.FrameNode(
            common: const ir.NodeCommon(
              id: 'row',
              name: 'row',
              x: 100,
              y: 400,
              width: 340,
              height: 120,
            ),
            autoLayout: const ir.AutoLayout(
              gap: ir.Gap.fixed(10),
              padding: ir.EdgeInsetsValue(
                left: 10,
                top: 10,
                right: 10,
                bottom: 10,
              ),
            ),
            children: [
              rect('i1', 0, 0, 100, 100),
              rect('i2', 0, 0, 100, 100),
              rect('i3', 0, 0, 100, 100),
            ],
          ),
          ir.FrameNode(
            common: const ir.NodeCommon(
              id: 'box',
              name: 'box',
              x: 600,
              y: 400,
              width: 300,
              height: 200,
            ),
            children: [rect('inner', 20, 20, 50, 50)],
          ),
          rect(
            'pinR',
            850,
            650,
            100,
            50,
            layoutChild: const ir.LayoutChild(
              constraints: ir.Constraints(
                horizontal: ir.HorizontalConstraint.right,
                vertical: ir.VerticalConstraint.bottom,
              ),
            ),
          ),
          const ir.TextNode(
            common: ir.NodeCommon(
              id: 'txt',
              name: 'txt',
              x: 100,
              y: 650,
              width: 50,
              height: 20,
            ),
            style: ir.TextStyleOverride(fontSize: 16),
            content: [
              ir.Paragraph(spans: [ir.Span(text: 'Hello')]),
            ],
          ),
          rect('rot', 450, 250, 100, 50, rotation: 90),
        ],
      ),
    ),
  ],
);

class Harness {
  Harness(this.tester, this.container);

  final WidgetTester tester;
  final ProviderContainer container;

  CanvasController get canvas => container.read(canvasControllerProvider);
  EditorController get ctl => container.read(editorControllerProvider.notifier);
  EditorState get st => container.read(editorControllerProvider);
  ir.StageDocument get doc => st.document;
  ir.Node node(String id) => ir.DocumentIndex.of(doc).node(id)!;
  ir.NodeCommon common(String id) => node(id).common;

  Future<void> camera(CanvasCamera c) async {
    canvas.setCamera(c);
    await tester.pump();
  }

  /// World point [w] on the screen.
  Offset screen(Offset w) => canvas.camera.value.toScreen(w);

  /// World point of the desktop artboard's design point [p].
  Offset desk(double x, double y) => screen(Offset(x, y));

  /// The same for the mobile artboard (its world x offset).
  Offset mob(double x, double y) =>
      screen(canvas.artboards['mobile']!.worldRect.topLeft + Offset(x, y));

  Rect? worldRect(String id, [String bp = 'desktop']) =>
      canvas.overlay.worldRectFor(id, bp);

  /// Event time: advances so presses are double-clicks only when meant.
  Duration now = const Duration(seconds: 10);

  /// A mouse press at [at] (timestamped).
  Future<TestGesture> press(Offset at) async {
    now += const Duration(seconds: 1);
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.down(at, timeStamp: now);
    await tester.pump();
    return g;
  }

  Future<void> click(Offset at) async {
    final g = await press(at);
    await g.up(timeStamp: now);
    await tester.pump();
  }

  Future<void> doubleClick(Offset at) async {
    final g = await press(at);
    await g.up(timeStamp: now);
    await tester.pump(const Duration(milliseconds: 50));
    now += const Duration(milliseconds: 150);
    await g.down(at, timeStamp: now);
    await g.up(timeStamp: now);
    await tester.pump();
  }

  /// A drag in [steps] moves; [beforeUp] runs before the release.
  Future<void> drag(
    Offset from,
    Offset to, {
    int steps = 4,
    Future<void> Function()? beforeUp,
  }) async {
    final g = await press(from);
    for (var i = 1; i <= steps; i++) {
      await g.moveTo(Offset.lerp(from, to, i / steps)!, timeStamp: now);
      await tester.pump();
    }
    if (beforeUp != null) await beforeUp();
    await g.up(timeStamp: now);
    await tester.pump();
  }

  Future<TestGesture> hoverAt(Offset at) async {
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: at);
    await g.moveTo(at);
    await tester.pump();
    return g;
  }

  Future<void> withKeys(
    List<LogicalKeyboardKey> keys,
    Future<void> Function() body,
  ) async {
    for (final k in keys) {
      await tester.sendKeyDownEvent(k);
    }
    await body();
    for (final k in keys.reversed) {
      await tester.sendKeyUpEvent(k);
    }
    await tester.pump();
  }
}

Future<Harness> pumpCanvas(
  WidgetTester tester, {
  ir.StageDocument? doc,
  Size size = const Size(1800, 1000),
  CanvasCamera camera = const CanvasCamera(panX: 40, panY: 60),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        initialDocumentProvider.overrideWithValue(doc ?? interactionDoc()),
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
  final h = Harness(tester, container);
  await h.camera(camera);
  return h;
}

Matcher rectNear(Rect r, [double eps = 1e-6]) => isA<Rect>()
    .having((p) => p.left, 'left', closeTo(r.left, eps))
    .having((p) => p.top, 'top', closeTo(r.top, eps))
    .having((p) => p.width, 'width', closeTo(r.width, eps))
    .having((p) => p.height, 'height', closeTo(r.height, eps));
