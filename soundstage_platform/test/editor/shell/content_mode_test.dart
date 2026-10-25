import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/shell/content_mode_screen.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/editor/text/text_edit_controller.dart';
import 'package:soundstage_platform/editor/text/text_edit_layer.dart';
import 'package:soundstage_platform/editor/text/text_style_target.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import '../insert/fakes.dart';

const _focal = ir.StagePoint(x: 0.2, y: 0.7);

ir.TextNode _text(
  String id,
  double y,
  String text, {
  ir.NodeRole role = ir.NodeRole.none,
}) => ir.TextNode(
  common: ir.NodeCommon(
    id: id,
    name: id,
    x: 20,
    y: y,
    width: 300,
    height: 30,
    role: role,
  ),
  style: const ir.TextStyleOverride(fontSize: 16),
  content: [
    ir.Paragraph(spans: [ir.Span(text: text)]),
  ],
);

ir.StageDocument _doc() => ir.StageDocument(
  id: 'doc',
  meta: const ir.StageMeta(title: 'The Hour Between'),
  breakpoints: const [
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
  ],
  assets: {
    'img1': const ir.Asset(
      id: 'img1',
      kind: ir.AssetKind.image,
      uri: 'local://img1',
      name: 'old.png',
      mime: 'image/png',
    ),
    'aud1': const ir.Asset(
      id: 'aud1',
      kind: ir.AssetKind.audio,
      uri: 'local://aud1',
      name: 'rain.mp3',
      mime: 'audio/mpeg',
    ),
  },
  audioTracks: const [ir.AudioTrack(id: 't1', assetId: 'aud1')],
  scenes: [
    ir.Scene(
      id: 's1',
      name: 'First',
      kind: ir.SceneKind.pinned,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root1', width: 400, height: 800),
        children: [
          _text('h1', 40, 'Hello world', role: ir.NodeRole.heading1),
          _text('deco', 120, 'Ornament', role: ir.NodeRole.decorative),
          const ir.FrameNode(
            common: ir.NodeCommon(
              id: 'fig',
              name: 'Lighthouse photo',
              x: 20,
              y: 200,
              width: 200,
              height: 150,
              role: ir.NodeRole.figure,
            ),
            appearance: ir.Appearance(
              fills: [
                ir.Paint.image(
                  id: 'p1',
                  assetId: 'img1',
                  focalPoint: _focal,
                  scaleMode: ir.ImageScaleMode.fit,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    ir.Scene(
      id: 's2',
      name: 'Second',
      kind: ir.SceneKind.pinned,
      root: ir.FrameNode(
        common: const ir.NodeCommon(id: 'root2', width: 400, height: 800),
        children: [_text('p2', 40, 'Another page')],
      ),
    ),
  ],
);

class _Rig {
  _Rig(this.tester, this.container, this.service, this.docs, this.picked);

  final WidgetTester tester;
  final ProviderContainer container;
  final FakeAssetService service;
  final List<ir.StageDocument> docs;
  final List<String> picked;

  EditorController get ctl => container.read(editorControllerProvider.notifier);
  EditorState get st => container.read(editorControllerProvider);
  CanvasController get canvas => container.read(canvasControllerProvider);
  ir.Node node(String id) => ir.DocumentIndex.of(st.document).node(id)!;
  TextEditLayerState get layer =>
      tester.state<TextEditLayerState>(find.byType(TextEditLayer));

  String textOf(String id) => (node(id) as ir.TextNode).content
      .map((p) => p.spans.map((s) => s.text).join())
      .join('\n');

  /// The global centre of node [id] on the mobile artboard.
  Offset centre(String id) {
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey<String>('content-surface')),
    );
    return origin + canvas.overlay.rectFor(id, 'mobile')!.bounds.center;
  }

  Future<void> settle() async {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();
  }

  Future<void> tapNode(String id) async {
    await tester.tapAt(centre(id));
    await tester.pump();
    await tester.pump();
  }

  Future<void> typeDelta(String s) async {
    final session = layer.session!;
    for (final ch in s.split('')) {
      final sel = session.selection;
      session.updateEditingValueWithDeltas([
        TextEditingDeltaReplacement(
          oldText: session.text,
          replacementText: ch,
          replacedRange: TextRange(start: sel.start, end: sel.end),
          selection: TextSelection.collapsed(offset: sel.start + 1),
          composing: TextRange.empty,
        ),
      ]);
    }
    await tester.pump();
  }
}

Future<_Rig> _pump(
  WidgetTester tester,
  Size size, {
  ir.StageDocument? document,
  List<EditorFile> pick = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final service = FakeAssetService();
  service.entries['aud1'] = const ir.Asset(
    id: 'aud1',
    kind: ir.AssetKind.audio,
    uri: 'local://aud1',
    name: 'rain.mp3',
    mime: 'audio/mpeg',
  );
  final docs = <ir.StageDocument>[];
  final picked = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (c, child) => SsScope(theme: SsThemeData.dark(), child: child!),
      home: Scaffold(
        body: EditorShell(
          document: document ?? _doc(),
          assetService: service,
          filePicker: ({String accept = '', bool multiple = false}) async {
            picked.add(accept);
            return pick;
          },
          onBack: () {},
          onPreview: () => picked.add('preview'),
          onDocumentChanged: docs.add,
          saveStatus: const Text('Saved'),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  final container = ProviderScope.containerOf(
    tester.element(
      find.byType(ContentModeScreen).evaluate().isNotEmpty
          ? find.byType(ContentModeScreen)
          : find.byType(EditorCanvas),
    ),
  );
  return _Rig(tester, container, service, docs, picked);
}

Finder _label(String l) => find.bySemanticsLabel(l);

void main() {
  setUp(() => StageAssetResolver.defaultLocal = StubPngLoader());
  tearDown(() => StageAssetResolver.defaultLocal = null);

  group('the scene pager', () {
    testWidgets('prev/next, the keyboard and the active scene', (tester) async {
      final r = await _pump(tester, const Size(390, 844));
      expect(find.text('First'), findsOneWidget);
      expect(find.text('1 of 2  ·  Pinned'), findsOneWidget);
      expect(r.st.activeSceneId, 's1');
      expect(
        tester
            .widget<SsIconButton>(
              find.byWidgetPredicate(
                (w) => w is SsIconButton && w.icon == SsIcons.chevronLeft,
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is SsIconButton && w.icon == SsIcons.chevronRight,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('2 of 2  ·  Pinned'), findsOneWidget);
      expect(r.st.activeSceneId, 's2');
      // The runtime shows the new scene.
      expect(r.canvas.artboards['mobile']!.scene!.id, 's2');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      await tester.pump();
      expect(r.st.activeSceneId, 's1');
      // Only the narrowest primary breakpoint is drawn, width-fitted.
      expect(find.byType(EditorCanvas), findsNothing);
      expect(r.canvas.artboards.keys, ['mobile']);
      expect(r.canvas.camera.value.zoom, closeTo(390 / 400, 0.001));
    });
  });

  group('editing text', () {
    testWidgets('tapping text starts a content-only session; writes go to '
        'the base as one undo step', (tester) async {
      final r = await _pump(tester, const Size(390, 844));
      await r.tapNode('h1');
      expect(r.st.textEditId, 'h1');
      final s = r.layer.session!;
      expect(s.contentOnly, isTrue);
      expect(primaryFocusIsStageText(), isTrue);
      // A tap puts the caret; it does not select a word.
      expect(s.selection.isCollapsed, isTrue);
      await r.typeDelta('!!');
      expect(r.textOf('h1'), contains('!!'));
      // Base only: no breakpoint patch.
      expect(r.node('h1').common.breakpointOverrides, isEmpty);
      // The app's autosave hook saw it.
      expect(r.docs, isNotEmpty);
      expect(
        (r.docs.last.scenes.first.root.children.first as ir.TextNode)
            .content
            .first
            .spans
            .map((e) => e.text)
            .join(),
        contains('!!'),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(r.st.textEditId, isNull);
      expect(r.st.history.undoLabel, 'Edit text');
      final edited = r.textOf('h1');
      r.ctl.undo();
      await tester.pump();
      expect(r.textOf('h1'), 'Hello world');
      expect(edited, isNot('Hello world'));
      r.ctl.redo();
      await tester.pump();
      expect(r.textOf('h1'), edited);
    });

    testWidgets('style and link shortcuts do nothing', (tester) async {
      final r = await _pump(tester, const Size(390, 844));
      await r.tapNode('h1');
      final before = r.st.document;
      for (final key in [
        LogicalKeyboardKey.keyB,
        LogicalKeyboardKey.keyI,
        LogicalKeyboardKey.keyU,
        LogicalKeyboardKey.keyK,
      ]) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }
      final s = r.layer.session!;
      s
        ..toggle(TextToggle.bold)
        ..setRole(ir.NodeRole.heading3)
        ..applyLink('https://example.com');
      expect(s.pendingStyle, isEmpty);
      expect(identical(r.st.document, before), isTrue);
      expect(r.node('h1').common.role, ir.NodeRole.heading1);
    });

    testWidgets('decorative text is not editable', (tester) async {
      final r = await _pump(tester, const Size(390, 844));
      await r.tapNode('deco');
      expect(r.st.textEditId, isNull);
      expect(find.byType(TextEditLayer), findsOneWidget);
      expect(r.layer.session, isNull);
    });

    testWidgets('tapping elsewhere ends the session', (tester) async {
      final r = await _pump(tester, const Size(390, 844));
      await r.tapNode('h1');
      expect(r.st.textEditId, 'h1');
      await tester.tapAt(r.centre('root1') + const Offset(0, 300));
      await tester.pump();
      expect(r.st.textEditId, isNull);
    });

    testWidgets('the undo button steps back through the edit', (tester) async {
      final r = await _pump(tester, const Size(390, 844));
      await r.tapNode('h1');
      await r.typeDelta('Z');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is SsIconButton && w.icon == SsIcons.undo2,
        ),
      );
      await tester.pump();
      expect(r.textOf('h1'), 'Hello world');
    });
  });

  group('replacing media', () {
    testWidgets('Replace image swaps the asset, keeps the focal point and '
        'scale mode, in one undo step', (tester) async {
      final r = await _pump(
        tester,
        const Size(390, 844),
        pick: [
          (
            name: 'new.jpg',
            bytes: FakeAssetService.png(40, 20),
            mime: 'image/jpeg',
          ),
        ],
      );
      await r.tapNode('fig');
      expect(find.text('Replace image'), findsOneWidget);
      await tester.tap(find.text('Replace image'));
      await r.settle();
      await r.settle();
      final fill =
          (r.node('fig') as ir.FrameNode).appearance.fills.single
              as ir.ImagePaint;
      expect(fill.assetId, 'asset1');
      expect(fill.focalPoint, _focal);
      expect(fill.scaleMode, ir.ImageScaleMode.fit);
      expect(fill.id, 'p1');
      expect(r.picked, contains('image/*'));
      expect(r.st.history.undoLabel, 'Replace image');
      r.ctl.undo();
      await tester.pump();
      final back =
          (r.node('fig') as ir.FrameNode).appearance.fills.single
              as ir.ImagePaint;
      expect(back.assetId, 'img1');
      expect(r.docs, isNotEmpty);
    });

    testWidgets('Replace image writes the mobile patch when mobile shows '
        'its own image; desktop keeps its image', (tester) async {
      final doc = ir
          .updateNode(
            _doc(),
            'fig',
            (n) => n.copyWith(
              common: n.common.copyWith(
                breakpointOverrides: {
                  'mobile': {
                    'fills.p1.assetId': const ir.IrValue.string('img2'),
                  },
                },
              ),
            ),
          )
          .document;
      final withImg2 = doc.copyWith(
        assets: {
          ...doc.assets,
          'img2': doc.assets['img1']!.copyWith(id: 'img2', uri: 'local://img2'),
        },
      );
      final r = await _pump(
        tester,
        const Size(390, 844),
        document: withImg2,
        pick: [
          (
            name: 'new.jpg',
            bytes: FakeAssetService.png(40, 20),
            mime: 'image/jpeg',
          ),
        ],
      );
      await r.tapNode('fig');
      await tester.tap(find.text('Replace image'));
      await r.settle();
      await r.settle();
      final fig = r.node('fig') as ir.FrameNode;
      expect((fig.appearance.fills.single as ir.ImagePaint).assetId, 'img1');
      expect(fig.common.breakpointOverrides['mobile'], {
        'fills.p1.assetId': const ir.IrValue.string('asset1'),
      });
      expect(r.st.history.undoLabel, 'Replace image');
      r.ctl.undo();
      await tester.pump();
      expect(
        (r
            .node('fig')
            .common
            .breakpointOverrides['mobile']!['fills.p1.assetId']),
        const ir.IrValue.string('img2'),
      );
    });

    testWidgets('alt text is edited on the figure', (tester) async {
      final r = await _pump(tester, const Size(390, 844));
      await r.tapNode('fig');
      await tester.enterText(
        find.byKey(const ValueKey<String>('content-alt-field')),
        'A lighthouse at dusk',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(r.node('fig').common.altText, 'A lighthouse at dusk');
      expect(r.node('fig').common.breakpointOverrides, isEmpty);
    });

    testWidgets('the content list opens slots and replaces a sound', (
      tester,
    ) async {
      final r = await _pump(
        tester,
        const Size(390, 844),
        pick: [
          (
            name: 'storm.mp3',
            bytes: FakeAssetService.png(1, 1, 9),
            mime: 'audio/mpeg',
          ),
        ],
      );
      await tester.tap(_label('Show the scene content list'));
      await tester.pump();
      expect(_label('Edit text: Hello world'), findsOneWidget);
      expect(find.textContaining('Ornament'), findsNothing);
      expect(_label('Image options: Lighthouse photo'), findsOneWidget);
      await tester.tap(_label('Replace sound file: rain.mp3'));
      await r.settle();
      await r.settle();
      expect(r.picked, contains('audio/*'));
      // A new asset; only this track points at it; the old file stays.
      final track = r.st.document.audioTracks.single;
      expect(track.assetId, isNot('aud1'));
      expect(r.st.document.assets[track.assetId]!.name, 'storm.mp3');
      expect(r.st.document.assets['aud1']!.byteSize, isNot(5));
      expect(r.st.history.undoLabel, 'Replace sound');
      r.ctl.undo();
      await tester.pump();
      expect(r.st.document.audioTracks.single.assetId, 'aud1');
      await tester.tap(_label('Edit text: Hello world'));
      await tester.pump();
      await tester.pump();
      expect(r.st.textEditId, 'h1');
      // The caret is at the end, not a select-all (B11b).
      expect(
        r.layer.session!.selection,
        const TextSelection.collapsed(offset: 11),
      );
      await r.typeDelta('!');
      expect(r.textOf('h1'), 'Hello world!');
      expect(find.byKey(const ValueKey<String>('content-list')), findsNothing);
    });
  });

  group('taps on awkward stories (B3)', () {
    /// A text wider than the 400 px artboard, and an image frame nested in
    /// a frame filled with a radial gradient, low on a tall scene.
    ir.StageDocument awkward() => ir.updateScene(_doc(), 's1', (s) {
      final root = s.root;
      return s.copyWith(
        kind: ir.SceneKind.flow,
        root: root.copyWith(
          common: root.common.copyWith(height: 1600),
          children: [
            ...root.children,
            const ir.TextNode(
              common: ir.NodeCommon(
                id: 'wide',
                name: 'wide',
                x: 20,
                y: 420,
                width: 1318,
                height: 30,
              ),
              style: ir.TextStyleOverride(fontSize: 16),
              content: [
                ir.Paragraph(spans: [ir.Span(text: 'A very wide line')]),
              ],
            ),
            const ir.FrameNode(
              common: ir.NodeCommon(
                id: 'grad',
                name: 'grad',
                x: 20,
                y: 1200,
                width: 300,
                height: 220,
              ),
              appearance: ir.Appearance(
                fills: [
                  ir.Paint.gradient(
                    id: 'g',
                    kind: ir.GradientKind.radial,
                    stops: [
                      ir.ColorStop(
                        position: 0,
                        color: ir.StageColor(r: 1, g: 0, b: 0),
                      ),
                      ir.ColorStop(
                        position: 1,
                        color: ir.StageColor(r: 0, g: 0, b: 1),
                      ),
                    ],
                  ),
                ],
              ),
              children: [
                ir.FrameNode(
                  common: ir.NodeCommon(
                    id: 'pic',
                    name: 'pic',
                    x: 20,
                    y: 20,
                    width: 200,
                    height: 150,
                  ),
                  appearance: ir.Appearance(
                    fills: [ir.Paint.image(id: 'pi', assetId: 'img1')],
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }).document;

    /// A visible point of [id] on the surface (inside the artboard).
    Offset visible(_Rig r, String id) {
      final surface = r.tester.getRect(
        find.byKey(const ValueKey<String>('content-surface')),
      );
      final b = r.canvas.overlay
          .rectFor(id, 'mobile')!
          .bounds
          .shift(surface.topLeft);
      return b.intersect(surface).center;
    }

    Future<void> scroll(_Rig r, double dy) async {
      final surface = r.tester.getRect(
        find.byKey(const ValueKey<String>('content-surface')),
      );
      // From the left margin, clear of the texts.
      await r.tester.dragFrom(
        Offset(surface.left + 6, surface.center.dy),
        Offset(0, dy),
      );
      await r.tester.pump();
    }

    testWidgets('a nested image in a gradient frame opens its panel', (
      tester,
    ) async {
      final r = await _pump(tester, const Size(390, 844), document: awkward());
      await scroll(r, -700);
      expect(r.canvas.overlay.rectFor('pic', 'mobile'), isNotNull);
      await tester.tapAt(visible(r, 'pic'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Replace image'), findsOneWidget);
    });

    testWidgets('a text wider than the artboard starts editing; another '
        'slot can be tapped next', (tester) async {
      final r = await _pump(tester, const Size(390, 844), document: awkward());
      await tester.tapAt(visible(r, 'wide'));
      await tester.pump();
      await tester.pump();
      expect(r.st.textEditId, 'wide');
      await scroll(r, -700);
      await tester.tapAt(visible(r, 'pic'));
      await tester.pump();
      await tester.pump();
      expect(r.st.textEditId, isNull);
      expect(find.text('Replace image'), findsOneWidget);
      await scroll(r, 700);
      await tester.tapAt(visible(r, 'wide'));
      await tester.pump();
      await tester.pump();
      expect(r.st.textEditId, 'wide');
    });
  });

  testWidgets('after the full editor narrows to content mode, taps still '
      'reach text and images (B3)', (tester) async {
    final r = await _pump(tester, const Size(1600, 1000));
    expect(find.byType(EditorCanvas), findsOneWidget);
    expect(r.canvas.artboards.keys, containsAll(['desktop', 'mobile']));
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(ContentModeScreen), findsOneWidget);
    await r.tapNode('h1');
    expect(r.st.textEditId, 'h1');
    await r.tapNode('fig');
    expect(find.text('Replace image'), findsOneWidget);
    // And back to the full editor: its artboards have geometry again.
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.byType(EditorCanvas), findsOneWidget);
    expect(r.canvas.overlay.rectFor('h1', 'desktop'), isNotNull);
    expect(r.canvas.overlay.rectFor('h1', 'mobile'), isNotNull);
  });

  group('layout', () {
    for (final size in [
      const Size(320, 568),
      const Size(390, 844),
      const Size(800, 600),
      const Size(1023, 768),
    ]) {
      testWidgets('${size.width.round()} px: no overflow, 44 px targets, '
          'dismissible note', (tester) async {
        final r = await _pump(tester, size);
        await tester.tap(_label('Show the scene content list'));
        await tester.pump();
        await r.tapNode('fig');
        expect(tester.takeException(), isNull);
        for (final b in tester.widgetList<SsIconButton>(
          find.byType(SsIconButton),
        )) {
          expect(b.size, greaterThanOrEqualTo(44), reason: b.semanticLabel);
        }
        expect(find.text('Saved'), findsOneWidget);
        expect(find.textContaining('larger window'), findsOneWidget);
        await tester.tap(_label('Dismiss note'));
        await tester.pump();
        expect(find.textContaining('larger window'), findsNothing);
        // The preview link.
        await tester.tap(_label('Preview story'));
        expect(r.picked.last, 'preview');
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('at 1024 px the full editor is shown', (tester) async {
      tester.view.physicalSize = const Size(1024, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (c, child) =>
              SsScope(theme: SsThemeData.dark(), child: child!),
          home: Scaffold(
            body: EditorShell(
              document: _doc(),
              onBack: () {},
              onPreview: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ContentModeScreen), findsNothing);
      expect(find.byType(EditorCanvas), findsOneWidget);
    });
  });
}
