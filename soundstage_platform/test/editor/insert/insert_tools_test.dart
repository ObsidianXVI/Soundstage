import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/insert/insert_actions.dart';
import 'package:soundstage_platform/editor/insert/insert_nodes.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../interaction/interaction_harness.dart';
import 'fakes.dart';

Future<Harness> pump(
  WidgetTester tester, {
  List<Override> overrides = const [],
}) => pumpCanvas(tester, overrides: overrides);

Future<void> useTool(Harness h, EditorTool t) async {
  h.ctl.setTool(t);
  await h.tester.pump();
}

String lastChildOf(Harness h, String parent) =>
    (h.node(parent) as ir.FrameNode).children.last.id;

void main() {
  setUp(() => StageAssetResolver.defaultLocal = _StubLoader());
  tearDown(() => StageAssetResolver.defaultLocal = null);

  group('click', () {
    testWidgets('places a default-size node, selects it, returns to Move', (
      tester,
    ) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.click(h.desk(850, 250));
      final id = lastChildOf(h, 'root');
      final n = h.node(id);
      expect(n, isA<ir.ShapeNode>());
      expect(n.common.name, 'Rectangle');
      expect(
        [n.common.x, n.common.y, n.common.width, n.common.height],
        [850, 250, 100, 100],
      );
      expect(h.st.selection, {id});
      expect(h.st.tool, EditorTool.move);
      // One undo step.
      h.ctl.undo();
      expect(h.doc.scenes.first.root.children.any((c) => c.id == id), isFalse);
    });

    testWidgets('each tool makes its node kind', (tester) async {
      final h = await pump(tester);
      final kinds = <EditorTool, bool Function(ir.Node)>{
        EditorTool.frame: (n) => n is ir.FrameNode,
        EditorTool.ellipse: (n) =>
            n is ir.ShapeNode && n.geometry is ir.EllipseGeometry,
        EditorTool.line: (n) =>
            n is ir.ShapeNode && n.geometry is ir.LineGeometry,
        EditorTool.text: (n) => n is ir.TextNode,
      };
      var y = 150.0;
      for (final e in kinds.entries) {
        await useTool(h, e.key);
        await h.click(h.desk(920, y)); // clear ground, clear of the last one
        y += 120;
        expect(
          e.value(h.node(lastChildOf(h, 'root'))),
          isTrue,
          reason: '${e.key}',
        );
      }
    });

    testWidgets('Alt centres the node on the pointer', (tester) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.withKeys([LogicalKeyboardKey.altLeft], () async {
        await h.click(h.desk(850, 250));
      });
      final c = h.common(lastChildOf(h, 'root'));
      expect([c.x, c.y], [800, 200]);
    });
  });

  group('drag', () {
    testWidgets('draws the box between press and release', (tester) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.drag(h.desk(250, 250), h.desk(330, 340));
      final c = h.common(lastChildOf(h, 'root'));
      expect([c.x, c.y, c.width, c.height], [250, 250, 80, 90]);
      expect(h.st.tool, EditorTool.move);
    });

    testWidgets('dragging up and left draws from the far corner', (
      tester,
    ) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.ellipse);
      await h.drag(h.desk(330, 340), h.desk(250, 250));
      final c = h.common(lastChildOf(h, 'root'));
      expect([c.x, c.y, c.width, c.height], [250, 250, 80, 90]);
    });

    testWidgets('Shift makes a square', (tester) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.drag(
        h.desk(250, 250),
        h.desk(330, 300),
        beforeUp: () async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pump();
        },
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      final c = h.common(lastChildOf(h, 'root'));
      expect([c.x, c.y, c.width, c.height], [250, 250, 80, 80]);
    });

    testWidgets('Alt draws from the centre', (tester) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.drag(
        h.desk(300, 300),
        h.desk(340, 345),
        beforeUp: () async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
          await tester.pump();
        },
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      final c = h.common(lastChildOf(h, 'root'));
      expect([c.x, c.y, c.width, c.height], [260, 255, 80, 90]);
    });

    testWidgets('snaps to a sibling edge', (tester) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      // a's right edge is x=200: ending 2 px short snaps onto it.
      await h.drag(h.desk(120, 250), h.desk(198, 330));
      final c = h.common(lastChildOf(h, 'root'));
      expect(c.x + c.width, 200);
    });

    testWidgets('a line is a horizontal box rotated about its centre', (
      tester,
    ) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.line);
      await h.drag(h.desk(250, 250), h.desk(250, 350));
      final c = h.common(lastChildOf(h, 'root'));
      expect(c.height, 0);
      expect(c.width, closeTo(100, 0.6));
      expect(c.rotation, closeTo(90, 0.01));
      // Its centre is the middle of the drag.
      expect(c.x + c.width / 2, closeTo(250, 0.6));
      expect(c.y, closeTo(300, 0.6));
    });

    testWidgets('Esc cancels the drag', (tester) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      final before = h.doc;
      await h.drag(
        h.desk(250, 250),
        h.desk(330, 340),
        beforeUp: () async {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pump();
        },
      );
      expect(h.doc, before);
    });
  });

  group('parent', () {
    testWidgets('goes into the frame under the pointer, in its space', (
      tester,
    ) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.click(h.desk(700, 450)); // box is at (600,400)
      final c = h.common(lastChildOf(h, 'box'));
      expect([c.x, c.y], [100, 50]);
      expect(h.st.selectionContext, 'box');
    });

    testWidgets('joins an auto-layout flow at the pointer index', (
      tester,
    ) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.click(h.desk(215, 450)); // between i1 and i2
      final kids = (h.node('row') as ir.FrameNode).children;
      expect(kids.length, 4);
      expect(kids[1].common.name, 'Rectangle');
      expect(kids.map((k) => k.id).first, 'i1');
      expect(kids[1].common.layoutChild.positioning, ir.Positioning.auto);
    });

    testWidgets('at the end of a flow when past the last child', (
      tester,
    ) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.click(h.desk(436, 500));
      final kids = (h.node('row') as ir.FrameNode).children;
      expect(kids.last.common.name, 'Rectangle');
    });

    testWidgets('the artboard under the pointer becomes the edited one', (
      tester,
    ) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      await h.click(h.mob(100, 600));
      expect(h.st.editingBreakpointId, 'mobile');
      final c = h.common(lastChildOf(h, 'root'));
      expect([c.x, c.y], [100, 600]);
    });

    testWidgets('a press off every artboard inserts nothing', (tester) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.rectangle);
      final before = h.doc;
      await h.click(const Offset(5, 5));
      expect(h.doc, before);
      expect(h.st.tool, EditorTool.rectangle);
    });
  });

  group('text', () {
    testWidgets('click makes a paragraph and starts text editing', (
      tester,
    ) async {
      final h = await pump(tester);
      final requests = <TextEditRequest>[];
      final sub = h.ctl.events.textEditRequests.listen(requests.add);
      addTearDown(sub.cancel);
      await useTool(h, EditorTool.text);
      await h.click(h.desk(850, 250));
      final id = lastChildOf(h, 'root');
      final n = h.node(id) as ir.TextNode;
      expect(n.common.role, ir.NodeRole.paragraph);
      expect(n.autoResize, ir.TextAutoResize.widthAndHeight);
      expect(h.st.textEditId, id);
      expect(requests, [(nodeId: id, breakpointId: 'desktop')]);
    });

    testWidgets('drag makes wrapping text of the drawn width', (tester) async {
      final h = await pump(tester);
      await useTool(h, EditorTool.text);
      await h.drag(h.desk(250, 250), h.desk(450, 300));
      final n = h.node(lastChildOf(h, 'root')) as ir.TextNode;
      expect(n.autoResize, ir.TextAutoResize.height);
      expect(n.common.width, 200);
    });
  });

  group('images', () {
    test(
      'fitImageSize keeps the aspect ratio within 80% and never upscales',
      () {
        const board = Size(1000, 800);
        expect(fitImageSize(const Size(200, 100), board), const Size(200, 100));
        expect(
          fitImageSize(const Size(4000, 2000), board),
          const Size(800, 400),
        );
        expect(
          fitImageSize(const Size(1000, 4000), board),
          const Size(160, 640),
        );
        expect(fitImageSize(Size.zero, board), kDefaultInsertSize);
      },
    );

    testWidgets('the Image tool picks files and places them as figures', (
      tester,
    ) async {
      final service = FakeAssetService();
      final h = await pump(
        tester,
        overrides: [
          editorAssetServiceProvider.overrideWithValue(service),
          editorFilePickerProvider.overrideWithValue(
            ({String accept = '', bool multiple = false}) async => [
              (
                name: 'photo.jpg',
                bytes: FakeAssetService.png(4000, 2000),
                mime: 'image/jpeg',
              ),
            ],
          ),
        ],
      );
      h.ctl.setTool(EditorTool.image);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      final id = lastChildOf(h, 'root');
      final n = h.node(id) as ir.FrameNode;
      expect(n.common.name, 'photo');
      expect(n.common.role, ir.NodeRole.figure);
      expect(n.common.altText, '');
      expect([n.common.width, n.common.height], [800, 400]);
      final fill = n.appearance.fills.single as ir.ImagePaint;
      expect(fill.scaleMode, ir.ImageScaleMode.fill);
      expect(fill.focalPoint, const ir.StagePoint(x: 0.5, y: 0.5));
      expect(h.doc.assets[fill.assetId]!.name, 'photo.jpg');
      expect(h.st.tool, EditorTool.move);
      expect(h.st.selection, {id});
      // The asset and the frame arrive in two history entries only because
      // one is a library change; both undo cleanly.
      h.ctl
        ..undo()
        ..undo();
      expect(h.doc.assets, isEmpty);
    });

    testWidgets('a cancelled picker returns to Move', (tester) async {
      final h = await pump(
        tester,
        overrides: [
          editorAssetServiceProvider.overrideWithValue(FakeAssetService()),
          editorFilePickerProvider.overrideWithValue(
            ({String accept = '', bool multiple = false}) async => [],
          ),
        ],
      );
      h.ctl.setTool(EditorTool.image);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(h.st.tool, EditorTool.move);
    });

    testWidgets('images land in the selected frame, centred', (tester) async {
      final service = FakeAssetService();
      final h = await pump(
        tester,
        overrides: [editorAssetServiceProvider.overrideWithValue(service)],
      );
      final asset = await tester.runAsync(
        () => service.add(
          FakeAssetService.png(100, 50),
          'image/png',
          name: 'a.png',
        ),
      );
      h.ctl.execute(AddAssets([asset!]));
      h.ctl.select({'box'});
      final ids = h.container.read(insertActionsProvider).insertImages([asset]);
      expect(ids, hasLength(1));
      final c = h.common(ids.single);
      // box is 300 x 200: centred.
      expect([c.x, c.y, c.width, c.height], [100, 75, 100, 50]);
      expect(h.st.selectionContext, 'box');
    });
  });
}

/// Serves a 1 x 1 PNG for every `local://` image, so painting an inserted
/// image has something to decode.
class _StubLoader implements LocalAssetLoader {
  static final _png = Uint8List.fromList(
    base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/'
      'iZk9HQAAAABJRU5ErkJggg==',
    ),
  );

  @override
  Future<Uint8List?> loadBytes(String assetId) async => _png;

  @override
  Future<String?> acquireObjectUrl(String assetId) async => null;

  @override
  void releaseObjectUrl(String assetId) {}
}
