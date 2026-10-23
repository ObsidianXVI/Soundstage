
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/panels/layers_model.dart';
import 'package:soundstage_platform/editor/panels/layers_panel.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

import 'panels_harness.dart';

Future<void> _expand(
  WidgetTester tester,
  ProviderContainer c,
  Iterable<String> ids,
) async {
  c.read(layersExpansionProvider.notifier).expandAll(ids);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pump();
}

Future<void> _tapWith(
  WidgetTester tester,
  String label,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(key);
  await tester.tap(find.text(label));
  await tester.sendKeyUpEvent(key);
  await tester.pump();
}

/// Drags the row [from] with the mouse to [to] (global), in small steps.
Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final g = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await tester.pump();
  const steps = 8;
  for (var i = 1; i <= steps; i++) {
    await g.moveTo(Offset.lerp(from, to, i / steps)!);
    await tester.pump();
  }
  await g.up();
  await tester.pump();
}

Offset _at(WidgetTester tester, String label, double fraction) {
  final r = tester.getRect(rowOf(label));
  return Offset(r.left + 60, r.top + r.height * fraction);
}

void main() {
  group('model', () {
    ProviderContainer open() {
      final c = ProviderContainer(
        overrides: [initialDocumentProvider.overrideWithValue(panelsDoc())],
      );
      addTearDown(c.dispose);
      return c;
    }

    ir.ResolvedNode root(ProviderContainer c) =>
        c.read(resolvedForProvider('desktop')).scene('s1')!.root;

    test('rows are topmost first and descend only into expanded nodes', () {
      final c = open();
      final collapsed = flattenLayers(root(c), const {});
      expect([for (final r in collapsed) r.id], ['H', 'L', 'I', 'B', 'A']);
      expect(collapsed.first.indexInParent, 4);
      expect(
        collapsed.every((r) => r.depth == 0 && r.parentId == 'root'),
        isTrue,
      );
      final open2 = flattenLayers(root(c), const {'A', 'A2'});
      expect(
        [for (final r in open2) r.id],
        ['H', 'L', 'I', 'B', 'A', 'T', 'A2', 'A21', 'A1'],
      );
      expect(open2.firstWhere((r) => r.id == 'A21').depth, 2);
      expect(open2.firstWhere((r) => r.id == 'A2').expanded, isTrue);
    });

    test('instance contents are read-only; hidden and locked dim', () {
      final c = open();
      final rows = flattenLayers(root(c), const {'I'});
      final inner = rows.where((r) => r.id.startsWith('I/')).toList();
      expect(inner, hasLength(2));
      expect(inner.every((r) => r.readOnly), isTrue);
      expect(rows.firstWhere((r) => r.id == 'I').readOnly, isFalse);
      expect(rows.firstWhere((r) => r.id == 'I').canContain, isFalse);
      expect(rows.firstWhere((r) => r.id == 'H').dimmed, isTrue);
      expect(rows.firstWhere((r) => r.id == 'L').dimmed, isTrue);
    });

    test('names fall back to the kind; roles have badges', () {
      expect(
        layerName(shape('x').copyWith(common: const ir.NodeCommon(id: 'x'))),
        'Rectangle',
      );
      expect(roleBadge(ir.NodeRole.heading3), 'H3');
      expect(roleBadge(ir.NodeRole.paragraph), '¶');
      expect(roleBadge(ir.NodeRole.none), isNull);
    });

    test('planLayerDrop: zones, paint indexes and validity', () {
      final c = open();
      final rows = flattenLayers(root(c), const {'B'});
      // H, L, I, B, B1, A  (A at row 5)
      LayerDropPlan plan(double pos, Set<String> dragged) => planLayerDrop(
        rows: rows,
        rootId: 'root',
        rowPos: pos,
        dragged: dragged,
      )!;
      // Top of H: above the topmost layer.
      var p = plan(0.1, {'A'});
      expect((p.parentId, p.index, p.valid, p.lineAtRow), ('root', 5, true, 0));
      // Middle of I (not a container): upper half above, lower half below.
      p = plan(2.4, {'A'});
      expect((p.parentId, p.index, p.lineAtRow), ('root', 3, 2));
      p = plan(2.6, {'A'});
      expect((p.parentId, p.index, p.lineAtRow), ('root', 2, 3));
      // Middle of the frame B: inside, on top.
      p = plan(3.5, {'A'});
      expect((p.parentId, p.index, p.insideRow), ('B', 1, 3));
      // Bottom of the expanded B: into B, on top.
      p = plan(3.9, {'A'});
      expect((p.parentId, p.index, p.lineAtRow, p.lineDepth), ('B', 1, 4, 1));
      // Below the last row.
      p = plan(99, {'H'});
      expect((p.parentId, p.index, p.lineAtRow), ('root', 0, 6));
      // Into itself / its own child.
      expect(plan(3.5, {'B'}).valid, isFalse);
      expect(plan(4.5, {'B'}).valid, isFalse, reason: 'B1 sits inside B');
      expect(
        planLayerDrop(rows: const [], rootId: 'root', rowPos: 0, dragged: {}),
        isNull,
      );
    });
  });

  testWidgets('rows show names, kind icons, role badge and dimming', (
    tester,
  ) async {
    final c = await pumpPanel(tester, const LayersPanel());
    expect(
      [
        for (final n in ['H', 'L', 'I', 'B', 'A']) n,
      ].every((n) => rowOf(n).evaluate().isNotEmpty),
      isTrue,
    );
    // Top of the list is the topmost layer.
    expect(
      tester.getTopLeft(rowOf('H')).dy < tester.getTopLeft(rowOf('A')).dy,
      isTrue,
    );
    expect(glyph(SsIcons.frame), findsWidgets);
    expect(glyph(SsIcons.component), findsOneWidget);
    expect(rowWidget(tester, 'H').dimmed, isTrue);
    expect(rowWidget(tester, 'L').dimmed, isTrue);
    expect(rowWidget(tester, 'A').dimmed, isFalse);
    await _expand(tester, c, ['A']);
    expect(find.text('H1'), findsOneWidget);
    expect(glyph(SsIcons.type), findsOneWidget);
  });

  group('virtualisation', () {
    testWidgets('a 5,000-node scene builds only the visible rows', (
      tester,
    ) async {
      final c = await pumpPanel(
        tester,
        const LayersPanel(),
        doc: bigDoc(),
        height: 600,
      );
      c.read(layersExpansionProvider.notifier).expandAll([
        for (var f = 0; f < 50; f++) 'F$f',
      ]);
      await tester.pump();
      final all = flattenLayers(
        c.read(resolvedForProvider('desktop')).scene('s1')!.root,
        c.read(layersExpansionProvider),
      );
      expect(all.length, 5050);
      final built = find.byType(SsTreeRow).evaluate().length;
      // 600 px / 28 px = ~22 rows in view, plus the cache extent.
      expect(built, lessThan(40));
      expect(built, greaterThan(15));
      // Scrolling builds others and drops the rest.
      await tester.drag(find.byType(ListView), const Offset(0, -20000));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SsTreeRow).evaluate().length, lessThan(40));
      debugPrint('layers: built $built of ${all.length} rows');
    });
  });

  group('expansion and reveal', () {
    testWidgets('the disclosure expands and collapses, and is remembered', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      expect(rowOf('A1'), findsNothing);
      final chevron = find.descendant(
        of: rowOf('A'),
        matching: glyph(SsIcons.chevronRight),
      );
      await tester.tap(chevron);
      await tester.pump();
      expect(c.read(layersExpansionProvider), contains('A'));
      expect(rowOf('A1'), findsOneWidget);
      // Children are topmost first: T, A2, A1.
      expect(
        tester.getTopLeft(rowOf('A2')).dy < tester.getTopLeft(rowOf('A1')).dy,
        isTrue,
      );
      await tester.tap(chevron);
      await tester.pump();
      expect(rowOf('A1'), findsNothing);
      expect(c.read(layersExpansionProvider), isEmpty);
    });

    testWidgets('selecting a deep node expands its ancestors', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      c.ctl.select({'A21'});
      await tester.pumpAndSettle();
      expect(c.read(layersExpansionProvider), containsAll(['A', 'A2']));
      expect(rowOf('A21'), findsOneWidget);
      expect(rowWidget(tester, 'A21').selected, isTrue);
    });

    testWidgets('selecting scrolls the row into view', (tester) async {
      final c = await pumpPanel(
        tester,
        const LayersPanel(),
        doc: bigDoc(),
        height: 400,
      );
      c.ctl.select({'F2.99'});
      await tester.pumpAndSettle();
      expect(rowOf('F2.99'), findsOneWidget);
      final r = tester.getRect(rowOf('F2.99'));
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.bottom, lessThanOrEqualTo(440));
      // Up again.
      c.ctl.select({'F40'});
      await tester.pumpAndSettle();
      expect(rowOf('F40'), findsOneWidget);
    });

    testWidgets('selection is revealed when the panel opens', (tester) async {
      final c2 = await pumpPanel(tester, const LayersPanel());
      c2.ctl.select({'B1'});
      await tester.pumpAndSettle();
      expect(rowOf('B1'), findsOneWidget);
    });
  });

  group('selection sync', () {
    testWidgets('click selects, with the parent as context', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _expand(tester, c, ['A']);
      await _tap(tester, 'A2');
      expect(c.st.selection, {'A2'});
      expect(c.st.selectionContext, 'A');
      expect(rowWidget(tester, 'A2').selected, isTrue);
      await _tap(tester, 'B');
      expect(c.st.selection, {'B'});
      expect(rowWidget(tester, 'A2').selected, isFalse);
      expect(c.st.selectionContext, isNull);
    });

    testWidgets('Shift extends a range, Cmd toggles', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _tap(tester, 'I');
      await _tapWith(tester, 'A', LogicalKeyboardKey.shiftLeft);
      expect(c.st.selection, {'I', 'B', 'A'});
      await _tap(tester, 'L');
      await _tapWith(tester, 'B', LogicalKeyboardKey.metaLeft);
      expect(c.st.selection, {'L', 'B'});
      await _tapWith(tester, 'L', LogicalKeyboardKey.controlLeft);
      expect(c.st.selection, {'B'});
    });

    testWidgets('a range skips descendants of selected rows', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _expand(tester, c, ['A']);
      await _tap(tester, 'A');
      await _tapWith(tester, 'A1', LogicalKeyboardKey.shiftLeft);
      // A is the anchor; A's children in the range are covered by A.
      expect(c.st.selection, {'A'});
    });

    testWidgets('canvas selection and hover show in the panel', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      c.ctl.select({'B', 'L'});
      await tester.pump();
      expect(rowWidget(tester, 'B').selected, isTrue);
      expect(rowWidget(tester, 'L').selected, isTrue);
      expect(rowWidget(tester, 'A').selected, isFalse);
      c.ctl.hover('A');
      await tester.pump();
      expect(rowWidget(tester, 'A').highlighted, isTrue);
      expect(rowWidget(tester, 'B').highlighted, isFalse);
      c.ctl.hover(null);
      await tester.pump();
      expect(rowWidget(tester, 'A').highlighted, isFalse);
    });

    testWidgets('hovering a row hovers the node', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(rowOf('B')));
      await tester.pump();
      expect(c.st.hoverId, 'B');
      await mouse.moveTo(const Offset(500, 500));
      await tester.pump();
      expect(c.st.hoverId, isNull);
    });
  });

  group('rename, visibility, lock', () {
    testWidgets('double-click renames inline; undo restores', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await tester.tap(find.text('B'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('B'));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.tap(find.text('B'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      final field = find.byType(EditableText);
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Bravo');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect((ir.DocumentIndex.of(c.doc).node('B')!).common.name, 'Bravo');
      expect(rowOf('Bravo'), findsOneWidget);
      expect(c.st.history.undoLabel, 'Rename layer');
      c.ctl.undo();
      await tester.pump();
      expect(ir.DocumentIndex.of(c.doc).node('B')!.common.name, 'B');
    });

    testWidgets('Enter and F2 rename the selected row', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _tap(tester, 'B');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();
      expect(find.byType(EditableText), findsOneWidget);
      await tester.enterText(find.byType(EditableText), 'Bee');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(ir.DocumentIndex.of(c.doc).node('B')!.common.name, 'Bee');
      // Escape cancels.
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pump();
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'Nope');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(ir.DocumentIndex.of(c.doc).node('B')!.common.name, 'Bee');
      expect(find.byType(EditableText), findsNothing);
    });

    testWidgets('the eye and lock toggles write through the commands', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      Future<void> toggle(String row, IconData icon) async {
        await tester.tap(
          find.descendant(of: rowOf(row), matching: glyph(icon)),
          warnIfMissed: false,
        );
        await tester.pump();
      }

      await toggle('B', SsIcons.eye);
      expect(ir.DocumentIndex.of(c.doc).node('B')!.common.visible, isFalse);
      expect(rowWidget(tester, 'B').dimmed, isTrue);
      await toggle('B', SsIcons.eyeOff);
      expect(ir.DocumentIndex.of(c.doc).node('B')!.common.visible, isTrue);
      await toggle('B', SsIcons.lockOpen);
      expect(ir.DocumentIndex.of(c.doc).node('B')!.common.locked, isTrue);
      expect(c.st.history.undoLabel, 'Lock layer');
      c.ctl.undo();
      await tester.pump();
      expect(ir.DocumentIndex.of(c.doc).node('B')!.common.locked, isFalse);
      // The already hidden / locked rows show their state.
      expect(rowWidget(tester, 'H').visible, isFalse);
      expect(rowWidget(tester, 'L').locked, isTrue);
    });

    testWidgets('a toggle on a selected row applies to the selection', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      c.ctl.select({'A', 'B'});
      await tester.pump();
      await tester.tap(
        find.descendant(of: rowOf('B'), matching: glyph(SsIcons.eye)),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(ir.DocumentIndex.of(c.doc).node('A')!.common.visible, isFalse);
      expect(ir.DocumentIndex.of(c.doc).node('B')!.common.visible, isFalse);
      expect(c.st.history.undoLabel, 'Hide 2 layers');
    });
  });

  group('drag and drop', () {
    testWidgets('dropping between rows reorders: one undo step', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      expect(childNames(c.doc, 'root'), ['A', 'B', 'I', 'L', 'H']);
      final undoBefore = c.st.history.undoLabel;
      // Drag A (bottom row) above H (top row): to the top edge of H.
      await _drag(tester, _at(tester, 'A', 0.5), _at(tester, 'H', 0.1));
      expect(childNames(c.doc, 'root'), ['B', 'I', 'L', 'H', 'A']);
      expect(c.st.selection, {'A'});
      expect(c.st.history.undoLabel, 'Move layer');
      c.ctl.undo();
      expect(childNames(c.doc, 'root'), ['A', 'B', 'I', 'L', 'H']);
      expect(c.st.history.undoLabel, undoBefore);
    });

    testWidgets('dropping into a frame reparents on top and expands it', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _drag(tester, _at(tester, 'L', 0.5), _at(tester, 'B', 0.5));
      expect(childNames(c.doc, 'root'), ['A', 'B', 'I', 'H']);
      expect(childNames(c.doc, 'B'), ['B1', 'L']);
      expect(c.read(layersExpansionProvider), contains('B'));
      expect(rowOf('L'), findsOneWidget);
      c.ctl.undo();
      expect(childNames(c.doc, 'B'), ['B1']);
      expect(childNames(c.doc, 'root'), ['A', 'B', 'I', 'L', 'H']);
    });

    testWidgets('dropping below an expanded frame goes in on top', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _expand(tester, c, ['B']);
      await _drag(tester, _at(tester, 'L', 0.5), _at(tester, 'B', 0.9));
      expect(childNames(c.doc, 'B'), ['B1', 'L']);
    });

    testWidgets('invalid drops do nothing: into itself or a descendant', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _expand(tester, c, ['A', 'A2']);
      final before = c.doc;
      // A into its own child A2, and into A21's slot.
      await _drag(tester, _at(tester, 'A', 0.5), _at(tester, 'A2', 0.5));
      await _drag(tester, _at(tester, 'A', 0.5), _at(tester, 'A21', 0.9));
      // A into itself.
      await _drag(tester, _at(tester, 'A', 0.5), _at(tester, 'A', 0.5));
      expect(identical(c.doc, before), isTrue);
      expect(c.st.history.canUndo, isFalse);
    });

    testWidgets('the inside of an instance is not a drop target', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _expand(tester, c, ['I']);
      final before = c.doc;
      await _drag(tester, _at(tester, 'B', 0.5), _at(tester, 'cmpI', 0.5));
      expect(identical(c.doc, before), isTrue);
      // Inner rows can't be dragged either.
      await _drag(tester, _at(tester, 'cmpJ', 0.5), _at(tester, 'H', 0.1));
      expect(identical(c.doc, before), isTrue);
    });

    testWidgets('dragging a selected row moves the whole selection', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      c.ctl.select({'A', 'B'});
      await tester.pump();
      await _drag(tester, _at(tester, 'B', 0.5), _at(tester, 'H', 0.1));
      expect(childNames(c.doc, 'root'), ['I', 'L', 'H', 'A', 'B']);
      expect(c.st.selection, {'A', 'B'});
      expect(c.st.history.undoLabel, 'Move 2 layers');
    });

    testWidgets('a tap without travel is just a click', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      final g = await tester.startGesture(
        _at(tester, 'B', 0.5),
        kind: PointerDeviceKind.mouse,
      );
      await g.moveBy(const Offset(0, 2));
      await g.up();
      await tester.pump();
      expect(c.st.selection, {'B'});
      expect(c.st.history.canUndo, isFalse);
    });
  });

  group('context menu', () {
    Future<void> openMenu(WidgetTester tester, String row) async {
      final g = await tester.startGesture(
        tester.getCenter(rowOf(row).first),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pump();
      await tester.pump();
    }

    testWidgets('right-clicking selects the row and offers the actions', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await openMenu(tester, 'B');
      expect(c.st.selection, {'B'});
      for (final item in [
        'Rename',
        'Duplicate',
        'Delete',
        'Wrap in frame',
        'Add auto layout',
        'Hide',
        'Lock',
        'Copy ID',
      ]) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
    });

    testWidgets('Duplicate, Delete, Wrap, Auto layout, Hide, Lock', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await openMenu(tester, 'B');
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      expect(childNames(c.doc, 'root'), hasLength(6));
      expect(c.st.history.undoLabel, 'Duplicate layer');

      // The copy is selected and sits on top of its original.
      await openMenu(tester, 'B');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(childNames(c.doc, 'root'), ['A', 'B', 'I', 'L', 'H']);

      await openMenu(tester, 'I');
      await tester.tap(find.text('Wrap in frame'));
      await tester.pumpAndSettle();
      final wrapper = ir.DocumentIndex.of(c.doc).locate('I')!.parentId!;
      expect(wrapper, isNot('root'));
      expect(c.st.history.undoLabel, 'Frame selection');

      await openMenu(tester, 'A');
      await tester.tap(find.text('Add auto layout'));
      await tester.pumpAndSettle();
      expect(
        (ir.DocumentIndex.of(c.doc).node('A')! as ir.FrameNode).autoLayout,
        isNotNull,
      );

      await openMenu(tester, 'L');
      expect(find.text('Unlock'), findsOneWidget);
      await tester.tap(find.text('Unlock'));
      await tester.pumpAndSettle();
      expect(ir.DocumentIndex.of(c.doc).node('L')!.common.locked, isFalse);

      await openMenu(tester, 'H');
      expect(find.text('Show'), findsOneWidget);
      await tester.tap(find.text('Show'));
      await tester.pumpAndSettle();
      expect(ir.DocumentIndex.of(c.doc).node('H')!.common.visible, isTrue);
    });

    testWidgets('Rename starts inline editing; Copy ID copies', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final c = await pumpPanel(tester, const LayersPanel());
      await openMenu(tester, 'B');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(find.byType(EditableText), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await openMenu(tester, 'A');
      await tester.tap(find.text('Copy ID'));
      await tester.pumpAndSettle();
      expect(copied, 'A');
      expect(c.st.history.canUndo, isFalse);
    });

    testWidgets('the menu acts on the whole selection', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      c.ctl.select({'A', 'B'});
      await tester.pump();
      await openMenu(tester, 'B');
      expect(c.st.selection, {'A', 'B'});
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(childNames(c.doc, 'root'), ['I', 'L', 'H']);
    });
  });

  group('keyboard', () {
    testWidgets('Up and Down move the selection', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _tap(tester, 'I');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(c.st.selection, {'B'});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(c.st.selection, {'A'});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(c.st.selection, {'A'}, reason: 'stops at the last row');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(c.st.selection, {'I'});
    });

    testWidgets('Shift+Down extends the selection', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _tap(tester, 'I');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(c.st.selection, {'I', 'B', 'A'});
    });

    testWidgets('Right expands, then enters; Left collapses, then exits', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _tap(tester, 'A');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(c.read(layersExpansionProvider), contains('A'));
      expect(c.st.selection, {'A'});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(c.st.selection, {'T'}, reason: 'the topmost child');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(c.st.selection, {'A'}, reason: 'a leaf selects its parent');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(c.read(layersExpansionProvider), isNot(contains('A')));
    });

    testWidgets('Delete deletes the selection', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _tap(tester, 'B');
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(childNames(c.doc, 'root'), ['A', 'I', 'L', 'H']);
      expect(c.st.selection, isEmpty);
      c.ctl.undo();
      expect(childNames(c.doc, 'root'), ['A', 'B', 'I', 'L', 'H']);
    });

    testWidgets('keys scroll the cursor row into view', (tester) async {
      final c = await pumpPanel(
        tester,
        const LayersPanel(),
        doc: bigDoc(frames: 60, perFrame: 0),
        height: 200,
      );
      await _tap(tester, 'F59');
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.pump();
      expect(c.st.selection, {'F39'});
      final r = tester.getRect(rowOf('F39'));
      expect(r.bottom, lessThanOrEqualTo(240));
    });
  });

  group('instances are read-only', () {
    testWidgets('inner rows show a lock, no toggles, and no rename', (
      tester,
    ) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _expand(tester, c, ['I']);
      expect(rowOf('cmpI'), findsOneWidget);
      final inner = tester.widget<SsTreeRow>(
        find.byWidgetPredicate((w) => w is SsTreeRow && w.depth == 1).first,
      );
      expect(inner.onVisibleChanged, isNull);
      expect(inner.onRename, isNull);
      expect(inner.trailing, isNotNull);
      // They can be selected.
      await tester.tap(
        find.byWidgetPredicate((w) => w is SsTreeRow && w.depth == 1).first,
      );
      await tester.pump();
      expect(c.st.selection.single, startsWith('I/'));
    });

    testWidgets('the menu on an inner row only offers Copy ID', (tester) async {
      final c = await pumpPanel(tester, const LayersPanel());
      await _expand(tester, c, ['I']);
      final g = await tester.startGesture(
        tester.getCenter(rowOf('cmpI')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await tester.pump();
      await tester.pump();
      expect(c.st.selection.single, 'I/cmpI');
      await tester.tap(find.text('Delete'), warnIfMissed: false);
      await tester.pump();
      expect(c.st.history.canUndo, isFalse);
      expect(find.text('Copy ID'), findsOneWidget);
    });
  });

  testWidgets('an empty scene shows an empty state', (tester) async {
    final c = await pumpPanel(tester, const LayersPanel());
    c.ctl.setActiveScene('s2');
    await tester.pump();
    expect(rowOf('C'), findsOneWidget);
    c.ctl.execute(const DeleteNodes(['C']));
    await tester.pump();
    expect(find.text('This scene is empty'), findsOneWidget);
  });
}
