import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/insert/editor_notices.dart';
import 'package:soundstage_platform/editor/insert/file_drop.dart';
import 'package:soundstage_platform/editor/insert/insert_actions.dart';
import 'package:soundstage_platform/editor/panels/assets_panel.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../interaction/interaction_harness.dart';
import 'fakes.dart';

/// The Assets panel (264 wide) beside the canvas, on the interaction
/// document.
Future<(Harness, FakeAssetService, ProviderContainer)> _pumpBoth(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(2000, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final service = FakeAssetService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        initialDocumentProvider.overrideWithValue(interactionDoc()),
        editorAssetServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: const Scaffold(
          body: Row(
            children: [
              SizedBox(width: 264, child: AssetsPanel()),
              Expanded(child: EditorCanvas()),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(EditorCanvas)),
  );
  final h = Harness(tester, container);
  await h.camera(const CanvasCamera(panX: 300, panY: 60));
  return (h, service, container);
}

/// The canvas's top-left in the window (the panel is to its left).
Offset _origin(WidgetTester tester) =>
    tester.getTopLeft(find.byType(EditorCanvas));

void main() {
  setUp(() => StageAssetResolver.defaultLocal = StubPngLoader());
  tearDown(() => StageAssetResolver.defaultLocal = null);

  testWidgets('files dropped from the desktop become image frames at the '
      'drop point', (tester) async {
    final (h, service, c) = await _pumpBoth(tester);
    final drop = h.desk(500, 300) + _origin(tester);
    c.read(fileDropHubProvider).dispatch([
      (
        name: 'photo.png',
        bytes: FakeAssetService.png(200, 100),
        mime: 'image/png',
      ),
      (name: 'song.mp3', bytes: FakeAssetService.png(1, 1), mime: 'audio/mpeg'),
    ], drop);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(service.files, hasLength(2));
    // The image became a frame centred on the drop point; the audio file
    // only joined the library.
    final kids = (h.node('root') as ir.FrameNode).children;
    final frame = kids.last as ir.FrameNode;
    expect(frame.common.name, 'photo');
    expect(frame.common.role, ir.NodeRole.figure);
    expect(
      [frame.common.x, frame.common.y, frame.common.width, frame.common.height],
      [400, 250, 200, 100],
    );
    expect(h.doc.assets.values.map((a) => a.kind), [
      ir.AssetKind.image,
      ir.AssetKind.audio,
    ]);
    expect(
      c.read(editorNoticesProvider).log.any((m) => m.contains('audio/video')),
      isTrue,
    );
  });

  testWidgets(
    'a drop that lands on the Assets panel adds to the library only',
    (tester) async {
      final (h, service, c) = await _pumpBoth(tester);
      c.read(fileDropHubProvider).dispatch([
        (
          name: 'photo.png',
          bytes: FakeAssetService.png(20, 10),
          mime: 'image/png',
        ),
      ], const Offset(100, 400));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(service.files, hasLength(1));
      expect(h.doc.assets, hasLength(1));
      expect((h.node('root') as ir.FrameNode).children.last.id, 'rot');
    },
  );

  Future<ir.Asset> addAsset(
    WidgetTester tester,
    Harness h,
    FakeAssetService service,
  ) async {
    final a = (await tester.runAsync(
      () =>
          service.add(FakeAssetService.png(60, 30), 'image/png', name: 'x.png'),
    ))!;
    h.ctl.execute(AddAssets([a]));
    await tester.pump();
    return a;
  }

  testWidgets('dragging an asset onto bare artboard makes an image frame', (
    tester,
  ) async {
    final (h, service, _) = await _pumpBoth(tester);
    final a = await addAsset(tester, h, service);
    final tile = find.byKey(ValueKey('asset-tile:${a.id}'));
    final g = await tester.startGesture(
      tester.getCenter(tile),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    final to = h.desk(850, 150);
    await g.moveTo(tester.getCenter(tile) + const Offset(30, 0));
    await tester.pump();
    await g.moveTo(to + _origin(tester));
    await tester.pump();
    await g.up();
    await tester.pump();
    final f = (h.node('root') as ir.FrameNode).children.last as ir.FrameNode;
    expect(f.appearance.fills.single, isA<ir.ImagePaint>());
    // Centred on the pointer.
    expect(
      [f.common.x, f.common.y, f.common.width, f.common.height],
      [820, 135, 60, 30],
    );
  });

  testWidgets('dragging an asset onto a frame sets its image fill', (
    tester,
  ) async {
    final (h, service, _) = await _pumpBoth(tester);
    final a = await addAsset(tester, h, service);
    final tile = find.byKey(ValueKey('asset-tile:${a.id}'));
    final g = await tester.startGesture(
      tester.getCenter(tile),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await g.moveTo(tester.getCenter(tile) + const Offset(30, 0));
    await tester.pump();
    await g.moveTo(
      h.desk(700, 500) + _origin(tester),
    ); // inside `box`, away from `inner`
    await tester.pump();
    await g.up();
    await tester.pump();
    final fills = (h.node('box') as ir.FrameNode).appearance.fills;
    expect((fills.single as ir.ImagePaint).assetId, a.id);
    // No new frame was made.
    expect((h.node('root') as ir.FrameNode).children.last.id, 'rot');
  });

  testWidgets('dropping on a shape fills it', (tester) async {
    final (h, service, c) = await _pumpBoth(tester);
    final a = await addAsset(tester, h, service);
    final canvas = c.read(canvasControllerProvider);
    c.read(insertActionsProvider).dropAsset(a.id, h.desk(150, 150), canvas);
    final fills = (h.node('a') as ir.ShapeNode).appearance.fills;
    expect((fills.single as ir.ImagePaint).assetId, a.id);
  });
}
