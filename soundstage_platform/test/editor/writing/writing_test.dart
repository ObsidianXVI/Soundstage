import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/publish/publish_view.dart';
import 'package:soundstage_platform/editor/shell/editor_layout.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/editor/timeline/timeline_panel.dart';
import 'package:soundstage_platform/editor/writing/writing_blocks.dart';
import 'package:soundstage_platform/editor/writing/writing_field.dart';
import 'package:soundstage_platform/editor/writing/writing_view.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

ir.TextNode _text(
  String id,
  String text, {
  ir.NodeRole role = ir.NodeRole.paragraph,
  double y = 0,
  bool visible = true,
}) => ir.TextNode(
  common: ir.NodeCommon(
    id: id,
    name: 'Layer $id',
    y: y,
    width: 600,
    height: 40,
    role: role,
    visible: visible,
  ),
  content: [
    for (final p in text.split('\n')) ir.Paragraph(spans: [ir.Span(text: p)]),
  ],
);

ir.StageDocument _doc() {
  final base = ir.StageDocument.empty(
    ids: ir.IdGenerator.seeded(1),
    meta: const ir.StageMeta(title: 'Written'),
  );
  return base.copyWith(
    scenes: [
      ir.Scene(
        id: 's1',
        name: 'Opening',
        kind: ir.SceneKind.pinned,
        root: ir.FrameNode(
          common: const ir.NodeCommon(id: 'root', width: 1440, height: 900),
          children: [
            // Out of tree order on purpose: reading order is top to bottom.
            _text('body', 'First line\nSecond line', y: 200),
            _text('title', 'The Hour', role: ir.NodeRole.heading1, y: 50),
            ir.FrameNode(
              common: const ir.NodeCommon(
                id: 'fig',
                y: 300,
                width: 400,
                height: 300,
                role: ir.NodeRole.figure,
                altText: 'A lighthouse',
              ),
              children: [
                _text('cap', 'Built 1890', role: ir.NodeRole.caption, y: 280),
              ],
            ),
            _text('deco', 'XII', role: ir.NodeRole.decorative, y: 700),
            _text('hidden', 'Draft', y: 800, visible: false),
          ],
        ),
      ),
    ],
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  Size size = const Size(1440, 900),
  EditorMode mode = EditorMode.writing,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final root = ProviderContainer();
  addTearDown(root.dispose);
  root.read(editorLayoutProvider.notifier).setMode(mode);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: root,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (c, child) =>
            SsScope(theme: SsThemeData.dark(), child: child!),
        home: Scaffold(
          body: EditorShell(
            document: _doc(),
            onBack: () {},
            onPreview: () {},
            publishActions: [
              EditorPublishAction(
                label: 'PDF',
                icon: SsIcons.file,
                onSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return root;
}

ProviderContainer _editor(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(WritingView)));

String _plain(ProviderContainer c, String id) {
  final n =
      ir.DocumentIndex.of(c.read(editorControllerProvider).document).node(id)!
          as ir.TextNode;
  return n.content.map((p) => p.spans.map((s) => s.text).join()).join('\n');
}

void main() {
  group('text diff', () {
    test('insert, delete, replace', () {
      expect(textDiff('abc', 'abXc'), (start: 2, end: 2, text: 'X'));
      expect(textDiff('abc', 'ac'), (start: 1, end: 2, text: ''));
      expect(textDiff('hello', 'help'), (start: 3, end: 5, text: 'p'));
      expect(textDiff('same', 'same'), isNull);
    });

    test('the caret places an ambiguous insert', () {
      // Typing "a" at the start of "aa": without the caret the diff would
      // say the end.
      expect(textDiff('aa', 'aaa', caret: 1), (start: 0, end: 0, text: 'a'));
      expect(textDiff('aa', 'aaa'), (start: 2, end: 2, text: 'a'));
    });
  });

  test('blocks: reading order, figures with captions, other text', () {
    final resolved = ir.resolveDocument(
      _doc(),
      ir.ResolveContext(breakpointId: _doc().breakpoints.first.id),
    );
    final scene = writingScenes(resolved).single;
    expect(scene.name, 'Opening');
    expect(
      [for (final b in scene.flow) b.nodeId],
      ['title', 'body', 'fig', 'cap'],
    );
    expect(scene.flow.elementAt(2).kind, WritingBlockKind.figure);
    expect(scene.flow.elementAt(2).label, 'A lighthouse');
    expect([for (final b in scene.other) b.nodeId], ['deco', 'hidden']);
    expect(scene.other.first.label, 'Layer deco');
  });

  testWidgets('Writing shows every text box and no canvas or inspector', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(WritingView), findsOneWidget);
    expect(find.text('Other text in this scene'), findsOneWidget);
    expect(find.text('A lighthouse'), findsOneWidget);
    for (final id in ['title', 'body', 'cap', 'deco', 'hidden']) {
      expect(find.byKey(ValueKey('writing:$id')), findsOneWidget, reason: id);
    }
    expect(
      find.bySemanticsLabel(RegExp('^Heading 1: Layer title')),
      findsOneWidget,
    );
    expect(find.byType(TimelinePanel), findsNothing);
    expect(find.bySemanticsLabel('Toggle inspector'), findsNothing);
  });

  testWidgets('typing edits the base content; one undo step per session', (
    tester,
  ) async {
    await _pump(tester);
    final c = _editor(tester);
    final field = find.byKey(const ValueKey('writing:body'));
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'First line!\nSecond line');
    await tester.pump();
    await tester.enterText(field, 'First line!!\nSecond line');
    await tester.pump();
    expect(_plain(c, 'body'), 'First line!!\nSecond line');
    // Leaving the field ends the session.
    await tester.tap(find.byKey(const ValueKey('writing:title')));
    await tester.pump();
    c.read(editorControllerProvider.notifier).undo();
    await tester.pump();
    expect(_plain(c, 'body'), 'First line\nSecond line');
    // The field follows the undo.
    expect(
      tester.widget<TextField>(field).controller!.text,
      'First line\nSecond line',
    );
  });

  testWidgets('Cmd+B bolds the selection', (tester) async {
    await _pump(tester);
    final c = _editor(tester);
    final field = find.byKey(const ValueKey('writing:body'));
    await tester.tap(field);
    await tester.pump();
    final ctl = tester.widget<TextField>(field).controller!;
    ctl.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
    final node =
        ir.DocumentIndex.of(
              c.read(editorControllerProvider).document,
            ).node('body')!
            as ir.TextNode;
    final first = node.content.first.spans.first;
    expect(first.text, 'First');
    expect(first.style.fontWeight, 700);
  });

  testWidgets('Animation opens the timeline; collapsing it goes to Design', (
    tester,
  ) async {
    final root = await _pump(tester, mode: EditorMode.animation);
    expect(
      tester.widget<TimelinePanel>(find.byType(TimelinePanel)).open,
      isTrue,
    );
    root.read(editorLayoutProvider.notifier).toggleTimeline();
    await tester.pump();
    expect(root.read(editorLayoutProvider).mode, EditorMode.design);
  });

  testWidgets('Publish shows the player and the exports', (tester) async {
    await _pump(tester, mode: EditorMode.publish);
    expect(find.byType(PublishView), findsOneWidget);
    expect(find.text('PDF'), findsOneWidget);
    expect(find.byKey(const ValueKey('preview-tier')), findsOneWidget);
    // Local-only: no Publish button.
    expect(find.byKey(const ValueKey('publish-view-publish')), findsNothing);
  });

  for (final mode in EditorMode.values) {
    testWidgets('${mode.name} lays out at 1024 px', (tester) async {
      await _pump(tester, size: const Size(1024, 768), mode: mode);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('notes: added in the margin, undoable, dropped when published', (
    tester,
  ) async {
    await _pump(tester);
    final c = _editor(tester);
    await tester.tap(find.byKey(const ValueKey('note-button:body')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('note:body')), 'Tighten');
    await tester.pump();
    expect(c.read(editorControllerProvider).document.notes, {
      'body': 'Tighten',
    });
    await tester.tap(find.byKey(const ValueKey('writing:title')));
    await tester.pump();
    c.read(editorControllerProvider.notifier).undo();
    await tester.pump();
    await tester.pump();
    expect(c.read(editorControllerProvider).document.notes, isEmpty);
    // Scene notes too, and an empty note is removed.
    final ctl = c.read(editorControllerProvider.notifier);
    ctl.execute(const SetNote('s1', 'Open with the sound'));
    expect(c.read(editorControllerProvider).document.notes['s1'], isNotNull);
    ctl.execute(const SetNote('s1', '  '));
    expect(c.read(editorControllerProvider).document.notes, isEmpty);
    expect(ctl.execute(const SetNote('nope', 'x')).ok, isFalse);
  });
}
