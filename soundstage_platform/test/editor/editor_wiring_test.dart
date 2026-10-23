import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/app.dart';
import 'package:soundstage_platform/app/data/story_repository.dart';
import 'package:soundstage_platform/app/persistence/autosave.dart';
import 'package:soundstage_platform/app/persistence/providers.dart';
import 'package:soundstage_platform/app/router.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/canvas/camera.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/canvas/editor_canvas.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'canvas/canvas_test.dart' show canvasDoc;

ProviderContainer _editor(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(EditorCanvas)));

Future<void> _ctrl(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool shift = false,
}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// The shell with a callback log (tests run as Android: Ctrl shortcuts).
Future<List<String>> _pumpShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
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
            document: canvasDoc(),
            onBack: () => log.add('back'),
            onPreview: () => log.add('preview'),
            onDocumentChanged: (d) => log.add('changed'),
            onSave: () => log.add('save'),
            saveStatus: const Text('SAVE-STATUS'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return log;
}

void main() {
  testWidgets('edits report the document; undo/redo by keys and buttons', (
    tester,
  ) async {
    final log = await _pumpShell(tester);
    final e = _editor(tester);
    final ctl = e.read(editorControllerProvider.notifier);
    expect(find.text('SAVE-STATUS'), findsOneWidget);
    ctl.select({'a1'});
    await tester.pump();
    expect(log, isEmpty, reason: 'selection is not a document change');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(log, ['changed']);
    ir.Node a1() => ir.DocumentIndex.of(
      e.read(editorControllerProvider).document,
    ).node('a1')!;
    expect(a1().common.x, 11);

    await _ctrl(tester, LogicalKeyboardKey.keyZ);
    expect(a1().common.x, 10);
    expect(log, ['changed', 'changed']);
    await _ctrl(tester, LogicalKeyboardKey.keyY);
    expect(a1().common.x, 11);
    await _ctrl(tester, LogicalKeyboardKey.keyZ, shift: false);
    expect(a1().common.x, 10);
    await _ctrl(tester, LogicalKeyboardKey.keyZ, shift: true);
    expect(a1().common.x, 11);

    // Toolbar buttons follow the history.
    await tester.tap(find.bySemanticsLabel(RegExp('^Undo')));
    await tester.pump();
    expect(a1().common.x, 10);
    await tester.tap(find.bySemanticsLabel(RegExp('^Redo')));
    await tester.pump();
    expect(a1().common.x, 11);

    await _ctrl(tester, LogicalKeyboardKey.keyS);
    expect(log.last, 'save');
  });

  testWidgets('the inspector names the selection', (tester) async {
    await _pumpShell(tester);
    final ctl = _editor(tester).read(editorControllerProvider.notifier);
    expect(find.text('Nothing selected'), findsOneWidget);
    ctl.select({'a'});
    await tester.pump();
    expect(find.text('Card'), findsOneWidget);
    expect(find.text('Frame'), findsOneWidget);
    ctl.select({'rot'});
    await tester.pump();
    expect(find.text('ROT'), findsOneWidget);
    expect(find.text('Rectangle'), findsOneWidget);
    ctl.select({'a', 'rot'});
    await tester.pump();
    expect(find.text('2 layers selected'), findsOneWidget);
  });

  testWidgets('edit scope: bound to the controller, Alt shows it flipped', (
    tester,
  ) async {
    await _pumpShell(tester);
    final e = _editor(tester);
    EditorState st() => e.read(editorControllerProvider);
    expect(st().effectiveScope, EditScope.both);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(st().scopeFlipped, isTrue);
    expect(st().effectiveScope, EditScope.thisBreakpoint);
    expect(
      find.bySemanticsLabel('Edit scope (flipped by Alt)'),
      findsOneWidget,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pump();
    expect(st().effectiveScope, EditScope.both);
    await tester.tap(find.text('This breakpoint'));
    await tester.pump();
    expect(st().editScope, EditScope.thisBreakpoint);
  });

  testWidgets('tool and zoom shortcuts; the zoom readout follows', (
    tester,
  ) async {
    await _pumpShell(tester);
    final e = _editor(tester);
    final canvas = e.read(canvasControllerProvider);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(e.read(editorControllerProvider).tool, EditorTool.hand);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.pump();
    expect(e.read(editorControllerProvider).tool, EditorTool.move);

    await _ctrl(tester, LogicalKeyboardKey.digit0);
    await tester.pumpAndSettle();
    expect(canvas.camera.value.zoom, 1);
    expect(find.text('100%'), findsOneWidget);
    await _ctrl(tester, LogicalKeyboardKey.equal);
    await tester.pumpAndSettle();
    expect(canvas.camera.value.zoom, 2);
    expect(find.text('200%'), findsOneWidget);

    e.read(editorControllerProvider.notifier).select({'a2'});
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    final r = canvas.overlay.rectFor('a2', 'desktop')!.bounds;
    expect(r.height, greaterThan(400), reason: 'framed the selection');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    final b = canvas.camera.value.rectToScreen(canvas.contentBounds!);
    expect(b.width, lessThan(canvas.viewportSize.width));
    expect(canvas.camera.value, isNot(const CanvasCamera(zoom: 2)));
  });

  testWidgets('/edit/:id opens through the repository and autosaves edits', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = InMemoryStoryRepository(loadAsset: (_) async => '{}');
    final story = await repo.createFrom(canvasDoc());
    final saved = <ir.StageDocument>[];
    final autosave = AutosaveController(
      save: (d) async => saved.add(d),
      debounce: const Duration(milliseconds: 10),
    );
    final router = buildRouter(initialLocation: '/edit/${story.id}');
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storyRepositoryProvider.overrideWithValue(repo),
          autosaveProvider.overrideWith((ref, id) => autosave),
        ],
        child: SoundstageApp(router: router),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(EditorCanvas), findsOneWidget);
    final e = _editor(tester);
    expect(e.read(editorControllerProvider).document.id, story.id);
    expect(find.text('Saved'), findsOneWidget, reason: 'idle status');

    final ctl = e.read(editorControllerProvider.notifier);
    ctl.select({'a1'});
    ctl.perform(const NudgeIntent(5, 0));
    await tester.pump();
    expect(find.text('Saving…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(ir.DocumentIndex.of(saved.single).node('a1')!.common.x, 15);
    expect(find.text('Saved'), findsOneWidget);

    // Leaving flushes and drops the cached story; reopening reads the save.
    await repo.save(story.id, saved.single);
    router.go('/');
    await tester.pumpAndSettle();
    router.go('/edit/${story.id}');
    await tester.pumpAndSettle();
    final again = _editor(tester).read(editorControllerProvider).document;
    expect(ir.DocumentIndex.of(again).node('a1')!.common.x, 15);
    unawaited(autosave.dispose());
  });
}
