import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/editor_controller.dart';
import 'package:soundstage_platform/editor/shell/content_mode_screen.dart';
import 'package:soundstage_platform/editor/shell/editor_layout.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

ir.StageDocument _doc() {
  final ids = ir.IdGenerator.seeded(1);
  final base = ir.StageDocument.empty(
    ids: ids,
    meta: const ir.StageMeta(title: 'The Hour Between'),
  );
  return base.copyWith(
    scenes: [
      ir.Scene.blankPinned(
        ids: ids,
        breakpoint: base.breakpoints.first,
        name: 'Opening',
      ),
      ir.Scene.blankPinned(
        ids: ids,
        breakpoint: base.breakpoints.first,
        name: 'Lighthouse',
      ),
    ],
  );
}

Finder _glyph(IconData i) => find.text(String.fromCharCode(i.codePoint));

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Size size, {
  List<String>? log,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [initialDocumentProvider.overrideWithValue(_doc())],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: Scaffold(
          body: EditorShell(
            document: _doc(),
            onBack: () => log?.add('back'),
            onPreview: () => log?.add('preview'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  for (final w in [1024.0, 1440.0, 1920.0]) {
    testWidgets(
      'the docked editor lays out at ${w.round()} px without overflow',
      (tester) async {
        await _pump(tester, Size(w, w == 1024 ? 768 : 900));
        expect(tester.takeException(), isNull);
        expect(find.byType(ContentModeScreen), findsNothing);
        expect(
          find.byKey(const ValueKey<String>('toolbar-title')),
          findsOneWidget,
        );
        expect(find.text('Scenes'), findsOneWidget);
        expect(find.text('Opening'), findsOneWidget);
        expect(find.text('Nothing selected'), findsOneWidget);
        expect(find.text('Timeline'), findsOneWidget);
        // Both artboards are drawn side by side.
        expect(find.textContaining('Desktop'), findsOneWidget);
        expect(find.textContaining('Mobile'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'the toolbar has the edit-scope segmented control with the Alt hint',
    (tester) async {
      final c = await _pump(tester, const Size(1440, 900));
      expect(find.text('Both'), findsOneWidget);
      expect(find.text('This breakpoint'), findsOneWidget);
      expect(c.read(editorLayoutProvider).scope, EditScope.both);
      await tester.tap(find.text('This breakpoint'));
      await tester.pump();
      expect(c.read(editorLayoutProvider).scope, EditScope.thisBreakpoint);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('Both')));
      await tester.pump(
        SsMotion.tooltipDelay + const Duration(milliseconds: 50),
      );
      await tester.pump();
      expect(find.textContaining('Alt flips scope'), findsOneWidget);
      await mouse.moveTo(const Offset(5, 500));
      await tester.pump();
    },
  );

  testWidgets('panels collapse with the toolbar toggles and Alt+1/2/3', (
    tester,
  ) async {
    final c = await _pump(tester, const Size(1440, 900));
    expect(find.text('Scenes'), findsOneWidget);
    await tester.tap(_glyph(SsIcons.panelLeft));
    await tester.pump();
    expect(find.text('Scenes'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(c.read(editorLayoutProvider).leftOpen, isTrue);
    expect(find.text('Scenes'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(c.read(editorLayoutProvider).rightOpen, isFalse);
    expect(c.read(editorLayoutProvider).timelineOpen, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging the divider resizes the left panel within limits', (
    tester,
  ) async {
    final c = await _pump(tester, const Size(1440, 900));
    final before = c.read(editorLayoutProvider).leftWidth;
    final pos = tester.getTopLeft(find.text('Scenes')).dx; // anchor
    expect(pos, greaterThan(0));
    final divider = Offset(before + 3, 400);
    await tester.dragFrom(divider, const Offset(60, 0));
    await tester.pump();
    expect(c.read(editorLayoutProvider).leftWidth, greaterThan(before));
    await tester.dragFrom(
      Offset(c.read(editorLayoutProvider).leftWidth + 3, 400),
      const Offset(-600, 0),
    );
    await tester.pump();
    expect(c.read(editorLayoutProvider).leftWidth, kLeftPanelMin);
    await tester.dragFrom(
      const Offset(kLeftPanelMin + 3, 400),
      const Offset(900, 0),
    );
    await tester.pump();
    expect(c.read(editorLayoutProvider).leftWidth, kLeftPanelMax);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('panel widths are remembered for the session', (tester) async {
    final c = await _pump(tester, const Size(1440, 900));
    c.read(editorLayoutProvider.notifier).setRightWidth(400);
    await tester.pump();
    expect(c.read(editorLayoutProvider).rightWidth, 400);
    // A shell rebuilt under the same container keeps the width.
    await tester.pumpWidget(const SizedBox());
    expect(c.read(editorLayoutProvider).rightWidth, 400);
  });

  testWidgets('the layout never lets the canvas shrink below its minimum', (
    tester,
  ) async {
    await _pump(tester, const Size(1024, 768));
    final c = ProviderScope.containerOf(
      tester.element(find.byType(EditorShell)),
    );
    c.read(editorLayoutProvider.notifier)
      ..setLeftWidth(420)
      ..setRightWidth(480);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('the ? key opens the shortcut help', (tester) async {
    await _pump(tester, const Size(1440, 900));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash, character: '?');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('Keyboard shortcuts'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('Preview and Back call back', (tester) async {
    final log = <String>[];
    await _pump(tester, const Size(1440, 900), log: log);
    await tester.tap(find.text('Preview'));
    await tester.tap(_glyph(SsIcons.arrowLeft));
    expect(log, ['preview', 'back']);
  });

  for (final size in [
    const Size(390, 844),
    const Size(800, 600),
    const Size(1023, 768),
  ]) {
    testWidgets('below 1024 px (${size.width.round()}) it shows content mode', (
      tester,
    ) async {
      final log = <String>[];
      await _pump(tester, size, log: log);
      expect(tester.takeException(), isNull);
      expect(find.byType(ContentModeScreen), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('content-mode-title')),
        findsOneWidget,
      );
      expect(find.text('The Hour Between'), findsOneWidget);
      expect(find.text('Opening'), findsOneWidget);
      expect(find.text('Lighthouse'), findsOneWidget);
      expect(find.textContaining('larger window'), findsOneWidget);
      expect(find.text('Scenes'), findsNothing); // no left panel
      await tester.tap(find.text('Play story'));
      expect(log, ['preview']);
    });
  }
}
