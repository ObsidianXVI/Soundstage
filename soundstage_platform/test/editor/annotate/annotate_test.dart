import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/agent/agent_panel.dart';
import 'package:soundstage_platform/editor/agent/agent_session.dart';
import 'package:soundstage_platform/editor/agent/agent_tools.dart';
import 'package:soundstage_platform/editor/agent/agent_transport.dart';
import 'package:soundstage_platform/editor/annotate/annotate_state.dart';
import 'package:soundstage_platform/editor/annotate/annotation_layer.dart';
import 'package:soundstage_platform/editor/canvas/canvas_controller.dart';
import 'package:soundstage_platform/editor/core/core.dart';
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

class _Transport implements AgentTransport {
  @override
  AgentConfig get config => const AgentConfig();

  @override
  Future<Map<String, Object?>> claude(Map<String, Object?> body) async => {
    'content': <Object?>[],
    'stop_reason': 'end_turn',
  };

  @override
  Future<Uint8List> illustrate(
    String prompt, {
    double? width,
    double? height,
  }) => throw UnimplementedError();
}

void main() {
  test('commands, agent tools and the point question', () async {
    final c = ProviderContainer(
      overrides: [initialDocumentProvider.overrideWithValue(_doc())],
    );
    addTearDown(c.dispose);
    final e = c.read(editorControllerProvider.notifier);
    final doc = c.read(editorControllerProvider).document;
    final scene = doc.scenes.single.id;
    final bp = doc.breakpoints.first;
    e.execute(
      AddAnnotation(
        ir.Annotation(
          id: 'a1',
          kind: ir.AnnotationKind.frame,
          sceneId: scene,
          breakpointId: bp.id,
          points: const [
            ir.StagePoint(x: 10, y: 20),
            ir.StagePoint(x: 210, y: 120),
          ],
          note: 'Big serif title here',
        ),
      ),
    );
    final session = AgentSession(
      editor: e,
      readState: () => c.read(editorControllerProvider),
      transport: _Transport(),
    );
    final tools = session.toolbox;
    final listed = (await tools.run('get_annotations', {})).content;
    final json = jsonDecode(listed.split('\n').single) as Map<String, Object?>;
    expect(json['note'], 'Big serif title here');
    expect(json['points'], [
      [10, 20],
      [210, 120],
    ]);
    expect(json['artboard'], contains('1440'));
    expect(json['status'], 'open');

    expect(
      (await tools.run('set_annotation_status', {
        'id': 'a1',
        'status': 'resolved',
      })).isError,
      isFalse,
    );
    expect(
      (await tools.run('get_annotations', {})).content,
      contains('no open'),
    );
    expect(
      (await tools.run('get_annotations', {'include_resolved': true})).content,
      contains('"resolved"'),
    );

    // ask_point waits for the author.
    final pending = tools.run('ask_point', {
      'question': 'Where does the icon go?',
    });
    await Future<void>.delayed(Duration.zero);
    expect(session.pointRequest.value!.question, 'Where does the icon go?');
    session.answerPoint((sceneId: scene, breakpointId: bp.id, x: 40, y: 50));
    final answer = jsonDecode((await pending).content) as Map<String, Object?>;
    expect(answer['x'], 40);
    expect(session.pointRequest.value, isNull);
    final cancelled = tools.run('ask_point', {'question': 'q'});
    await Future<void>.delayed(Duration.zero);
    session.stop();
    expect((await cancelled).content, contains('cancelled'));

    e.execute(const RemoveAnnotation('a1'));
    expect(c.read(editorControllerProvider).document.annotations, isEmpty);
    expect(AgentToolbox.isWrite('ask_point'), isFalse);
  });

  group('on the canvas', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      Size size = const Size(1440, 900),
      AgentTransport? transport,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = ProviderContainer();
      addTearDown(root.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: root,
          child: MaterialApp(
            builder: (c, child) =>
                SsScope(theme: SsThemeData.dark(), child: child!),
            home: Scaffold(
              body: EditorShell(
                document: _doc(),
                onBack: () {},
                onPreview: () {},
                agentTransport: transport,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return root;
    }

    ProviderContainer editor(WidgetTester tester) =>
        ProviderScope.containerOf(tester.element(find.byType(AnnotationLayer)));

    /// A screen point inside the first artboard.
    Offset inBoard(WidgetTester tester, double fx, double fy) {
      final c = editor(tester).read(canvasControllerProvider);
      final a = c.artboards.values.first;
      final world =
          a.worldRect.topLeft +
          Offset(a.worldRect.width * fx, a.worldRect.height * fy);
      final layer = tester.getTopLeft(find.byType(AnnotationLayer));
      return layer + c.camera.value.toScreen(world);
    }

    testWidgets('draw a frame, write its note, select, comment', (
      tester,
    ) async {
      final root = await pump(tester);
      await tester.tap(find.byKey(const ValueKey('toolbar-annotate')));
      await tester.pump();
      expect(root.read(annotateProvider).on, isTrue);
      expect(find.byKey(const ValueKey('annotate-tools')), findsOneWidget);

      await tester.dragFrom(inBoard(tester, 0.2, 0.2), const Offset(120, 80));
      await tester.pump();
      final doc = editor(tester).read(editorControllerProvider).document;
      final a = doc.annotations.single;
      expect(a.kind, ir.AnnotationKind.frame);
      expect(a.sceneId, doc.scenes.single.id);
      expect(a.breakpointId, doc.breakpoints.first.id);
      expect(a.points, hasLength(2));
      expect(a.points.last.x, greaterThan(a.points.first.x));

      // The new mark opens its note.
      final note = find.byKey(ValueKey('annotation-text:${a.id}'));
      expect(note, findsOneWidget);
      await tester.enterText(note, 'Title, 64px serif');
      await tester.pump();
      expect(
        editor(
          tester,
        ).read(editorControllerProvider).document.annotations.single.note,
        'Title, 64px serif',
      );

      // A click on empty artboard with the comment tool pins a comment.
      await tester.tap(find.byKey(const ValueKey('annotate-tool:comment')));
      await tester.pump();
      await tester.tapAt(inBoard(tester, 0.7, 0.7));
      await tester.pump();
      final kinds = [
        for (final x in editor(
          tester,
        ).read(editorControllerProvider).document.annotations)
          x.kind,
      ];
      expect(kinds, [ir.AnnotationKind.frame, ir.AnnotationKind.comment]);

      // Undo removes the comment.
      editor(tester).read(editorControllerProvider.notifier).undo();
      await tester.pump();
      expect(
        editor(tester).read(editorControllerProvider).document.annotations,
        hasLength(1),
      );
    });

    testWidgets('a click answers the agent', (tester) async {
      await pump(tester, transport: _Transport());
      final session = editor(tester).read(agentSessionProvider)!;
      final answer = session.askPoint('Where should the icon go?');
      await tester.pump();
      expect(find.byKey(const ValueKey('point-request')), findsOneWidget);
      await tester.tapAt(inBoard(tester, 0.5, 0.5));
      await tester.pump();
      final p = await answer;
      expect(p, isNotNull);
      expect(p!.x, closeTo(720, 2));
      expect(p.y, closeTo(450, 2));
      expect(find.byKey(const ValueKey('point-request')), findsNothing);
    });

    for (final size in const [Size(1024, 768), Size(1440, 900)]) {
      testWidgets('the toolbar fits at ${size.width.round()} px', (
        tester,
      ) async {
        await pump(tester, size: size);
        expect(find.byKey(const ValueKey('toolbar-annotate')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
