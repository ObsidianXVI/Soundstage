import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/board/board_view.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/shell/editor_layout.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

ir.StageDocument _doc() {
  final ids = ir.IdGenerator.seeded(1);
  final base = ir.StageDocument.empty(ids: ids);
  return base.copyWith(
    scenes: [
      ir.Scene.blankPinned(ids: ids, breakpoint: base.breakpoints.first),
    ],
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final root = ProviderContainer();
  addTearDown(root.dispose);
  root.read(editorLayoutProvider.notifier).setMode(EditorMode.writing);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: root,
      child: MaterialApp(
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: Scaffold(
          body: EditorShell(document: _doc(), onBack: () {}, onPreview: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
  return root;
}

List<ir.BoardItem> _items(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(BoardView)),
).read(editorControllerProvider).document.board.items;

void main() {
  test('commands add, update, reorder and remove; one undo per drag', () {
    final c = ProviderContainer(
      overrides: [initialDocumentProvider.overrideWithValue(_doc())],
    );
    addTearDown(c.dispose);
    final e = c.read(editorControllerProvider.notifier);
    List<ir.BoardItem> items() =>
        c.read(editorControllerProvider).document.board.items;
    e
      ..execute(
        const AddBoardItem(
          ir.BoardItem(id: 'a', kind: ir.BoardItemKind.note, text: 'one'),
        ),
      )
      ..execute(
        const AddBoardItem(
          ir.BoardItem(id: 'b', kind: ir.BoardItemKind.link, uri: 'https://x'),
        ),
      );
    expect(items().map((i) => i.id), ['a', 'b']);
    e
      ..beginGesture()
      ..execute(UpdateBoardItem(items().first.copyWith(x: 10)))
      ..execute(UpdateBoardItem(items().first.copyWith(x: 20)))
      ..endGesture();
    expect(items().first.x, 20);
    e.undo();
    expect(items().first.x, 0, reason: 'the drag is one step');
    e.execute(const BringBoardItemToFront('a'));
    expect(items().map((i) => i.id), ['b', 'a']);
    e.execute(const RemoveBoardItem('a'));
    expect(items().map((i) => i.id), ['b']);
    expect(e.execute(const RemoveBoardItem('nope')).changed, isFalse);
  });

  testWidgets('Write ▸ Board: add a note, type, undo, remove', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('Board'));
    await tester.pump();
    expect(find.byType(BoardView), findsOneWidget);
    expect(find.textContaining('Double-click anywhere'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('board-add-note')));
    await tester.pump();
    final note = _items(tester).single;
    expect(note.kind, ir.BoardItemKind.note);
    expect(note.color, kNoteColors.first);

    final field = find.byKey(ValueKey('board-text:${note.id}'));
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'Open on the sea');
    await tester.pump();
    expect(_items(tester).single.text, 'Open on the sea');

    // Drag it by its edge (the text field takes taps inside).
    final card = find.byKey(ValueKey('board:${note.id}'));
    await tester.dragFrom(
      tester.getTopLeft(card) + const Offset(4, 4),
      const Offset(100, 50),
    );
    await tester.pump();
    expect(_items(tester).single.x, closeTo(note.x + 100, 1));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BoardView)),
    );
    container.read(editorControllerProvider.notifier).undo();
    await tester.pump();
    expect(_items(tester).single.x, closeTo(note.x, 1));

    container
        .read(editorControllerProvider.notifier)
        .execute(RemoveBoardItem(note.id));
    await tester.pump();
    expect(_items(tester), isEmpty);
    // Let the double-tap recognizers' timers run out.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the board fits at 1024 px', (tester) async {
    final root = await _pump(tester, size: const Size(1024, 768));
    root.read(editorLayoutProvider.notifier).showBoard(true);
    await tester.pump();
    expect(find.byType(BoardView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
