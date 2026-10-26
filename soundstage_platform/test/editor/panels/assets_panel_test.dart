import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/insert/asset_service.dart';
import 'package:soundstage_platform/editor/panels/asset_actions.dart';
import 'package:soundstage_platform/editor/panels/assets_panel.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../insert/fakes.dart';
import 'font_fixtures.dart';
import 'panels_harness.dart';

Future<({ProviderContainer c, FakeAssetService service})> _pump(
  WidgetTester tester, {
  List<EditorFile> picks = const [],
}) async {
  final service = FakeAssetService();
  final c = await pumpPanel(
    tester,
    const AssetsPanel(),
    height: 700,
    overrides: [
      editorAssetServiceProvider.overrideWithValue(service),
      editorFilePickerProvider.overrideWithValue(
        ({String accept = '', bool multiple = false}) async => picks,
      ),
    ],
  );
  return (c: c, service: service);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

Future<ir.Asset> _add(
  WidgetTester tester,
  ({ProviderContainer c, FakeAssetService service}) s,
  String name, {
  int w = 40,
  int h = 20,
}) async {
  final a = await s.service.add(
    FakeAssetService.png(w, h),
    'image/png',
    name: name,
  );
  s.c.ctl.execute(AddAssets([a]));
  await tester.pump();
  return a;
}

void main() {
  testWidgets('empty library invites an upload', (tester) async {
    await _pump(tester);
    expect(find.text('No media yet'), findsOneWidget);
  });

  testWidgets('the upload button stores the picked files', (tester) async {
    final s = await _pump(
      tester,
      picks: [
        (name: 'a.png', bytes: FakeAssetService.png(30, 30), mime: 'image/png'),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('assets-upload')));
    await _settle(tester);
    await tester.tap(find.text('Files…'));
    await _settle(tester);
    expect(s.c.doc.assets.values.single.name, 'a.png');
    expect(find.text('a.png'), findsWidgets);
    expect(find.text('30 × 30 · 5 B'), findsOneWidget);
  });

  testWidgets('Image sequence… stores the picked frames in name order as '
      'one asset', (tester) async {
    final s = await _pump(
      tester,
      picks: [
        for (final n in ['walk_10.png', 'walk_2.png', 'walk_1.png'])
          (
            name: n,
            bytes: FakeAssetService.png(8, 8, n.length),
            mime: 'image/png',
          ),
      ],
    );
    await tester.tap(find.byKey(const ValueKey('assets-upload')));
    await _settle(tester);
    await tester.tap(find.text('Image sequence…'));
    await _settle(tester);
    final a = s.c.doc.assets.values.single;
    expect(a.kind, ir.AssetKind.imageSequence);
    expect(a.name, 'walk');
    expect(a.frameCount, 3);
  });

  testWidgets('tiles show name, dimensions and size', (tester) async {
    final s = await _pump(tester);
    await _add(tester, s, 'photo.jpg', w: 1200, h: 800);
    expect(find.text('photo.jpg'), findsOneWidget);
    expect(find.textContaining('1200 × 800'), findsOneWidget);
  });

  testWidgets('clicking an image applies it as the fill of the selection', (
    tester,
  ) async {
    final s = await _pump(tester);
    final a = await _add(tester, s, 'photo.jpg');
    // Nothing selected: only selects the tile.
    await tester.tap(find.byKey(ValueKey('asset-tile:${a.id}')));
    await tester.pump();
    expect(find.byKey(const ValueKey('asset-name')), findsOneWidget);
    expect(s.c.st.history.canUndo, isTrue); // the add
    final before = s.c.doc;
    s.c.ctl.select({'A'});
    await tester.tap(find.byKey(ValueKey('asset-tile:${a.id}')));
    await tester.pump();
    expect(identical(s.c.doc, before), isFalse);
    final fills =
        (s.c.ctl.state.document.scenes.first.root.children.first
                as ir.FrameNode)
            .appearance
            .fills;
    expect((fills.single as ir.ImagePaint).assetId, a.id);
  });

  testWidgets('renaming and alt text commit on Enter', (tester) async {
    final s = await _pump(tester);
    final a = await _add(tester, s, 'photo.jpg');
    await tester.tap(find.byKey(ValueKey('asset-tile:${a.id}')));
    await tester.pump();
    Future<void> type(String key, String text) async {
      final f = find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(EditableText),
      );
      await tester.tap(f);
      await tester.pump();
      await tester.enterText(f, text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    await type('asset-name', 'hero.jpg');
    await type('asset-alt', 'A hero image');
    final stored = s.c.doc.assets[a.id]!;
    expect(stored.name, 'hero.jpg');
    expect(stored.alt, 'A hero image');
  });

  testWidgets('deleting an unused asset removes it', (tester) async {
    final s = await _pump(tester);
    final a = await _add(tester, s, 'photo.jpg');
    await tester.tap(find.byKey(ValueKey('asset-tile:${a.id}')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('asset-delete')));
    await tester.pump();
    expect(s.c.doc.assets, isEmpty);
    expect(find.text('No media yet'), findsOneWidget);
  });

  testWidgets('a used asset lists where, and Replace everywhere swaps it', (
    tester,
  ) async {
    final s = await _pump(tester);
    tester.view.physicalSize = const Size(900, 800); // room for the dialog
    final a = await _add(tester, s, 'photo.jpg');
    final b = await _add(tester, s, 'other.jpg');
    s.c.ctl.execute(SetImageFill(['A'], a.id));
    await tester.tap(find.byKey(ValueKey('asset-tile:${a.id}')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('asset-delete')));
    await tester.pumpAndSettle();
    expect(find.text('Asset in use'), findsOneWidget);
    expect(s.c.doc.assets.keys, contains(a.id));
    expect(find.text('A'), findsWidgets); // the frame that uses it
    // Choose the replacement.
    await tester.tap(find.byType(SsDropdown<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('other.jpg').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('asset-replace-everywhere')));
    await tester.pumpAndSettle();
    expect(s.c.doc.assets.keys, [b.id]);
  });

  testWidgets('dominant colour shows as the thumbnail placeholder', (
    tester,
  ) async {
    final s = await _pump(tester);
    final a =
        (await s.service.add(
          FakeAssetService.png(8, 8),
          'image/png',
          name: 'c.png',
        )).copyWith(
          placeholder: const ir.AssetPlaceholder(
            dominantColor: ir.StageColor(r: 1, g: 0, b: 0),
          ),
        );
    s.c.ctl.execute(AddAssets([a]));
    await tester.pump();
    final tile = find.byKey(ValueKey('asset-tile:${a.id}'));
    expect(
      find.descendant(
        of: tile,
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == const Color(0xFFFF0000),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('narrow and wide panels lay out without overflow', (
    tester,
  ) async {
    for (final w in [200.0, 420.0]) {
      final service = FakeAssetService();
      await pumpPanel(
        tester,
        const AssetsPanel(),
        width: w,
        overrides: [editorAssetServiceProvider.overrideWithValue(service)],
      );
      expect(tester.takeException(), isNull);
    }
  });

  group('fonts section', () {
    Future<({ProviderContainer c, FakeAssetService service})> pumpFonts(
      WidgetTester tester,
    ) async {
      final s = await _pump(tester);
      await tester.tap(find.text('Fonts'));
      await tester.pump();
      return s;
    }

    Future<void> importFonts(
      WidgetTester tester,
      ({ProviderContainer c, FakeAssetService service}) s,
      List<Uint8List> files,
    ) async {
      await tester.runAsync(() async {
        await s.c.read(assetActionsProvider).importFonts([
          for (final (i, b) in files.indexed)
            (name: 'f$i.ttf', bytes: b, mime: 'font/ttf'),
        ]);
      });
      await tester.pump();
    }

    testWidgets('lists families, faces and the default font', (tester) async {
      final s = await pumpFonts(tester);
      expect(find.text('No fonts yet'), findsOneWidget);
      await importFonts(tester, s, [
        buildFont(family: 'Test Sans'),
        buildFont(family: 'Test Sans', style: 'Bold', weight: 700),
      ]);
      expect(find.text('Test Sans'), findsOneWidget);
      expect(find.text('Regular · 400'), findsOneWidget);
      expect(find.text('Bold · 700'), findsOneWidget);
      // Default font menu lists the family.
      await tester.tap(find.byKey(const ValueKey('default-font')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Sans').last);
      await tester.pumpAndSettle();
      expect(s.c.doc.defaultTextStyle.fontFamilyId, s.c.doc.fonts.keys.single);
      expect(find.text('Default'), findsOneWidget);
    });

    testWidgets('a variable font lists its axes as sliders', (tester) async {
      final s = await pumpFonts(tester);
      await importFonts(tester, s, [
        buildFont(
          family: 'Var Sans',
          axes: [
            (tag: 'wght', min: 100, def: 400, max: 900),
            (tag: 'wdth', min: 75, def: 100, max: 125),
          ],
        ),
      ]);
      expect(find.text('Variable'), findsOneWidget);
      expect(find.byKey(const ValueKey('axis:wght')), findsOneWidget);
      expect(find.byKey(const ValueKey('axis:wdth')), findsOneWidget);
      // The preview line follows the slider.
      final face = s.c.doc.fonts.values.single.faces.single;
      Text preview() =>
          tester.widget<Text>(find.byKey(ValueKey('preview:${face.assetId}')));
      expect(
        preview().style!.fontVariations!
            .firstWhere((v) => v.axis == 'wght')
            .value,
        400,
      );
      final slider = tester.getRect(find.byKey(const ValueKey('axis:wght')));
      await tester.tapAt(Offset(slider.right - 10, slider.center.dy));
      await tester.pump();
      expect(
        preview().style!.fontVariations!
            .firstWhere((v) => v.axis == 'wght')
            .value,
        greaterThan(800),
      );
    });

    testWidgets('removing a face and a family', (tester) async {
      final s = await pumpFonts(tester);
      await importFonts(tester, s, [
        buildFont(family: 'Test Sans'),
        buildFont(family: 'Test Sans', style: 'Bold', weight: 700),
      ]);
      final bold = s.c.doc.fonts.values.single.faces.last.assetId;
      await tester.tap(find.byKey(ValueKey('face-remove:$bold')));
      await tester.pump();
      expect(s.c.doc.fonts.values.single.faces, hasLength(1));
      final id = s.c.doc.fonts.keys.single;
      await tester.tap(find.byKey(ValueKey('font-menu:$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove family'));
      await tester.pumpAndSettle();
      expect(s.c.doc.fonts, isEmpty);
    });

    testWidgets('a family in use cannot be removed and says where', (
      tester,
    ) async {
      final s = await pumpFonts(tester);
      await importFonts(tester, s, [buildFont(family: 'Test Sans')]);
      final id = s.c.doc.fonts.keys.single;
      s.c.ctl.execute(
        SetProperty(['T'], 'style.fontFamilyId', ir.IrValue.string(id)),
      );
      await tester.tap(find.byKey(ValueKey('font-menu:$id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove family'));
      await tester.pumpAndSettle();
      expect(find.text('Test Sans is in use'), findsOneWidget);
      expect(s.c.doc.fonts, isNotEmpty);
    });
  });
}
