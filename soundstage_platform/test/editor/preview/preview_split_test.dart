import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/preview/preview_pane.dart';
import 'package:soundstage_platform/editor/preview/preview_split.dart';
import 'package:soundstage_platform/editor/preview/preview_stage.dart';
import 'package:soundstage_platform/editor/preview/preview_state.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

/// A story of three pinned scenes, each four viewports long.
ir.StageDocument _doc() {
  final ids = ir.IdGenerator.seeded(7);
  final base = ir.StageDocument.empty(
    ids: ids,
    meta: const ir.StageMeta(title: 'Story'),
  );
  return base.copyWith(
    scenes: [
      for (final name in ['One', 'Two', 'Three'])
        ir.Scene.blankPinned(
          ids: ids,
          breakpoint: base.breakpoints.first,
          name: name,
        ).copyWith(scrollLength: 4),
    ],
  );
}

final String _mobile = _doc().breakpoints[1].id;

Future<(List<String>, ProviderContainer)> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final log = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: Scaffold(
          body: EditorShell(
            document: _doc(),
            onBack: () {},
            onPreview: () => log.add('full'),
            onOpenPreviewInNewTab: () => log.add('tab'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (
    log,
    ProviderScope.containerOf(tester.element(find.byType(EditorCanvas))),
  );
}

EditorController _editor(ProviderContainer c) =>
    c.read(editorControllerProvider.notifier);

final _button = find.widgetWithText(SsButton, 'Preview');
final _pane = find.byKey(const ValueKey<String>('preview-pane'));
final _player = find.byType(StagePlayer);

Future<void> _openPreview(WidgetTester tester) async {
  await tester.tap(_button);
  await tester.pump();
  await tester.pump();
}

ScrollPosition _scroll(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _player, matching: find.byType(Scrollable)),
    )
    .position;

void main() {
  testWidgets('the Preview button toggles the split and the state persists', (
    tester,
  ) async {
    final (log, container) = await _pump(tester);
    expect(_pane, findsNothing);
    expect(find.byType(EditorCanvas), findsOneWidget);

    await _openPreview(tester);
    expect(_pane, findsOneWidget);
    expect(_player, findsOneWidget);
    expect(find.byType(EditorCanvas), findsOneWidget);

    // A choice made in the pane outlives closing and reopening it.
    container.read(previewProvider.notifier).chooseBreakpoint(_mobile);
    container.read(previewProvider.notifier).setFraction(0.5);
    await tester.tap(_button);
    await tester.pump();
    expect(_pane, findsNothing);
    await _openPreview(tester);
    final state = container.read(previewProvider);
    expect(state.breakpointId, _mobile);
    expect(state.fraction, 0.5);
    // Opening the split does not navigate away.
    expect(log, isEmpty);
  });

  testWidgets('Cmd/Ctrl-click opens the full player in a new tab', (
    tester,
  ) async {
    final (log, container) = await _pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(_button);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(log, ['tab']);
    expect(container.read(previewProvider).open, isFalse);

    await _openPreview(tester);
    await tester.tap(find.bySemanticsLabel('Open the preview in a new tab'));
    expect(log, ['tab', 'tab']);
  });

  testWidgets('dragging the divider resizes the pane', (tester) async {
    await _pump(tester);
    await _openPreview(tester);
    final before = tester.getSize(_pane).width;
    final handle = find.bySemanticsLabel('Resize preview');
    await tester.drag(handle, const Offset(-120, 0));
    await tester.pump();
    // The first 20 px of a drag are the touch slop.
    expect(tester.getSize(_pane).width, closeTo(before + 100, 1));

    // It never swallows the canvas or shrinks below its minimum.
    await tester.drag(handle, const Offset(-2000, 0));
    await tester.pump();
    final canvas = tester.getSize(find.byType(EditorCanvas)).width;
    expect(canvas, greaterThanOrEqualTo(kPreviewCanvasMin - 0.5));
    await tester.drag(handle, const Offset(2000, 0));
    await tester.pump();
    expect(tester.getSize(_pane).width, closeTo(kPreviewPaneMin, 1));
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the width picker sets the viewport; Free takes a number', (
    tester,
  ) async {
    final (_, container) = await _pump(tester);
    await _openPreview(tester);
    Size viewport() => tester.widget<StagePlayer>(_player).viewportOverride!;
    expect(viewport(), const Size(1440, 900));

    await tester.tap(
      find.descendant(
        of: find.byType(PreviewPane),
        matching: find.byType(SsDropdown<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Mobile'));
    await tester.pumpAndSettle();
    expect(viewport(), const Size(390, 844));

    await tester.tap(
      find.descendant(
        of: find.byType(PreviewPane),
        matching: find.byType(SsDropdown<String>),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Free width'));
    await tester.pumpAndSettle();
    final free = find.byKey(const ValueKey<String>('preview-free-width'));
    expect(free, findsOneWidget);
    container.read(previewProvider.notifier).setFreeWidth(600);
    await tester.pump();
    expect(viewport().width, 600);
    // The pane scales it to fit, never up.
    final shown = tester.getSize(
      find.ancestor(of: _player, matching: find.byType(FittedBox)).first,
    );
    expect(shown.width, lessThanOrEqualTo(viewport().width));
    expect(
      shown.width / shown.height,
      closeTo(600 / 1112, 0.01),
    ); // the tablet's design height
  });

  testWidgets('the tier picker previews the lite and static players', (
    tester,
  ) async {
    final (_, container) = await _pump(tester);
    await _openPreview(tester);
    StageTier tier() => tester.widget<StagePlayer>(_player).tier;
    expect(tier(), StageTier.full);
    await tester.tap(find.byKey(const ValueKey<String>('preview-tier')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Static').last);
    await tester.pumpAndSettle();
    expect(tier(), StageTier.static);
    expect(container.read(previewProvider).tier, StageTier.static);
    container.read(previewProvider.notifier).setTier(StageTier.lite);
    await tester.pump();
    expect(tier(), StageTier.lite);
  });

  testWidgets('the player rebuilds on a committed edit, not during a gesture', (
    tester,
  ) async {
    final (_, container) = await _pump(tester);
    await _openPreview(tester);
    final editor = _editor(container);
    final scene = editor.state.document.scenes.first;
    ir.StageDocument shown() => tester.widget<StagePlayer>(_player).document;
    final first = shown();
    expect(identical(first, editor.state.document), isTrue);

    editor.beginGesture();
    for (var i = 1; i <= 5; i++) {
      editor.execute(UpdateSceneSettings(scene.id, scrollLength: 4.0 + i));
      await tester.pump(const Duration(milliseconds: 40));
    }
    // Far longer than the debounce, the gesture is still open.
    await tester.pump(const Duration(milliseconds: 600));
    expect(identical(shown(), first), isTrue);

    editor.endGesture();
    await tester.pump(const Duration(milliseconds: 100));
    expect(identical(shown(), first), isTrue, reason: 'still debouncing');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(identical(shown(), editor.state.document), isTrue);
    expect(shown().scenes.first.scrollLength, 9);
  });

  testWidgets('a rebuild keeps the scroll position through length changes', (
    tester,
  ) async {
    final (_, container) = await _pump(tester);
    await _openPreview(tester);
    final editor = _editor(container);
    final scenes = editor.state.document.scenes;

    // Halfway through scene two.
    var p = _scroll(tester);
    final viewport = p.viewportDimension;
    p.jumpTo(viewport * 5 + viewport * 5 / 2);
    await tester.pump();
    p = _scroll(tester);
    final before = p.pixels;

    // An unrelated edit: same position.
    editor.execute(UpdateSceneSettings(scenes[2].id, name: 'Three!'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();
    expect(_scroll(tester).pixels, closeTo(before, 0.5));

    // The first scene gets two viewports longer: the reader stays in
    // scene two, at the same progress.
    editor.execute(UpdateSceneSettings(scenes[0].id, scrollLength: 6));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();
    expect(_scroll(tester).pixels, closeTo(before + 2 * viewport, 1));
  });

  testWidgets('follow scrolls the preview to the active scene', (tester) async {
    final (_, container) = await _pump(tester);
    await _openPreview(tester);
    container.read(previewProvider.notifier).toggleFollow();
    await tester.pump();
    final scenes = _editor(container).state.document.scenes;
    expect(_scroll(tester).pixels, 0);
    _editor(container).setActiveScene(scenes[1].id);
    await tester.pump();
    await tester.pumpAndSettle();
    final viewport = _scroll(tester).viewportDimension;
    expect(_scroll(tester).pixels, closeTo(viewport * 5, 1));
  });

  testWidgets('the player is read-only: selection does not touch it', (
    tester,
  ) async {
    final (_, container) = await _pump(tester);
    await _openPreview(tester);
    final before = tester.widget<StagePlayer>(_player).document;
    final editor = _editor(container);
    editor.select({editor.state.document.scenes.first.root.id});
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      identical(tester.widget<StagePlayer>(_player).document, before),
      true,
    );
  });

  test('previewViewportFor: a breakpoint, or free with a matching height', () {
    final doc = _doc();
    expect(
      previewViewportFor(doc, PreviewState(breakpointId: _mobile)),
      const Size(390, 844),
    );
    expect(
      previewViewportFor(doc, const PreviewState()),
      const Size(1440, 900),
    );
    expect(
      previewViewportFor(
        doc,
        const PreviewState(breakpointId: kPreviewFreeWidth, freeWidth: 500),
      ),
      const Size(500, 844),
    );
  });

  testWidgets('wheel scrolling reaches the preview', (tester) async {
    await _pump(tester);
    await _openPreview(tester);
    // Through the enter gate, once per session.
    await tester.tap(find.byType(StageEnterGate));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(StageEnterGate), findsOneWidget);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(tester.getCenter(_player));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 300)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(_scroll(tester).pixels, greaterThan(0));
  });
}
