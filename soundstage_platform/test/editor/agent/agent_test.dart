import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/agent/agent_panel.dart';
import 'package:soundstage_platform/editor/agent/agent_session.dart';
import 'package:soundstage_platform/editor/agent/agent_tools.dart';
import 'package:soundstage_platform/editor/agent/agent_transport.dart';
import 'package:soundstage_platform/editor/core/core.dart';
import 'package:soundstage_platform/editor/shell/editor_layout.dart';
import 'package:soundstage_platform/editor/shell/editor_shell.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;

ir.StageDocument _doc() {
  final base = ir.StageDocument.empty(
    ids: ir.IdGenerator.seeded(1),
    meta: const ir.StageMeta(title: 'Agent story'),
  );
  return base.copyWith(
    scenes: [
      const ir.Scene(
        id: 's1',
        name: 'Opening',
        kind: ir.SceneKind.pinned,
        root: ir.FrameNode(
          common: ir.NodeCommon(id: 'stage', width: 1440, height: 900),
          children: [
            ir.TextNode(
              common: ir.NodeCommon(
                id: 'title',
                name: 'Title',
                x: 100,
                y: 80,
                width: 600,
                height: 60,
                role: ir.NodeRole.heading1,
              ),
              content: [
                ir.Paragraph(spans: [ir.Span(text: 'The Hour')]),
              ],
            ),
            ir.FrameNode(
              common: ir.NodeCommon(
                id: 'box',
                name: 'Box',
                y: 300,
                width: 200,
                height: 100,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _FakeTransport implements AgentTransport {
  _FakeTransport(this.replies);

  final List<Object Function()> replies;
  final List<Map<String, Object?>> bodies = [];

  @override
  AgentConfig get config => const AgentConfig(effort: 'low');

  @override
  Future<Map<String, Object?>> claude(Map<String, Object?> body) async {
    // A deep copy: the session keeps appending to its message list.
    bodies.add({
      ...body,
      'messages': [...body['messages']! as List],
    });
    final next = replies.removeAt(0)();
    if (next is AgentException) throw next;
    return next as Map<String, Object?>;
  }

  @override
  Future<Uint8List> illustrate(
    String prompt, {
    double? width,
    double? height,
  }) => throw UnimplementedError();
}

Map<String, Object?> _toolUse(
  String id,
  String name,
  Map<String, Object?> input,
) => {'type': 'tool_use', 'id': id, 'name': name, 'input': input};

Map<String, Object?> _reply(List<Map<String, Object?>> content, String stop) =>
    {'content': content, 'stop_reason': stop};

(ProviderContainer, EditorController) _editor() {
  final c = ProviderContainer(
    overrides: [initialDocumentProvider.overrideWithValue(_doc())],
  );
  addTearDown(c.dispose);
  final e = c.read(editorControllerProvider.notifier);
  e.select({});
  return (c, e);
}

ir.Node _node(ProviderContainer c, String id) =>
    ir.DocumentIndex.of(c.read(editorControllerProvider).document).node(id)!;

void main() {
  group('tools', () {
    late ProviderContainer c;
    late AgentToolbox tools;

    setUp(() {
      final (container, editor) = _editor();
      c = container;
      tools = AgentToolbox(
        editor: editor,
        readState: () => c.read(editorControllerProvider),
      );
    });

    test('the outline names scenes and layers compactly', () {
      final o = tools.outline('s1');
      expect(o, contains('1. s1 "Opening" pinned'));
      expect(
        o,
        contains('- title text "Title" heading1 (100,80 600×60) "The Hour"'),
      );
      expect(o, contains('- box frame "Box" (0,300 200×100)'));
    });

    test('writes go through the editor commands', () async {
      expect(
        (await tools.run('set_text', {
          'node_id': 'title',
          'text': 'Dusk',
        })).isError,
        isFalse,
      );
      final title = _node(c, 'title') as ir.TextNode;
      expect(title.content.single.spans.single.text, 'Dusk');

      final r = await tools.run('set_properties', {
        'node_ids': ['box', 'title'],
        'x': 40,
        'fill': '#ff0000',
        'font_size': 48,
        'name': 'Renamed',
      });
      expect(r.isError, isFalse, reason: r.content);
      final box = _node(c, 'box') as ir.FrameNode;
      expect(box.common.x, 40);
      expect(box.common.name, 'Renamed');
      expect(
        (box.appearance.fills.single as ir.SolidPaint).color.toHex(),
        '#ff0000',
      );
      expect((_node(c, 'title') as ir.TextNode).style.fontSize, 48);

      final add = await tools.run('add_layer', {
        'kind': 'text',
        'x': 10,
        'y': 10,
        'width': 300,
        'height': 40,
        'text': 'Hello',
      });
      expect(add.isError, isFalse, reason: add.content);
      expect(tools.outline('s1'), contains('"Hello"'));

      expect(
        (await tools.run('set_note', {'id': 's1', 'text': 'Louder'})).isError,
        isFalse,
      );
      expect(c.read(editorControllerProvider).document.notes['s1'], 'Louder');
      expect(
        (await tools.run('delete_layers', {
          'node_ids': ['box'],
        })).isError,
        isFalse,
      );
      expect(
        ir.DocumentIndex.of(
          c.read(editorControllerProvider).document,
        ).node('box'),
        isNull,
      );
      // set_text, properties, two renames, add, note, delete.
      expect(tools.writes, 7);
    });

    test('bad input is an error for the model, not a crash', () async {
      expect(
        (await tools.run('set_text', {'node_id': 'box', 'text': 'x'})).isError,
        isTrue,
      );
      expect(
        (await tools.run('set_text', {'node_id': 'title'})).isError,
        isTrue,
      );
      expect(
        (await tools.run('get_node', {'node_id': 'nope'})).isError,
        isTrue,
      );
      expect((await tools.run('fly', {})).isError, isTrue);
      expect(
        (await tools.run('add_illustration', {
          'prompt': 'p',
          'alt': 'a',
          'x': 0,
          'y': 0,
          'width': 1,
          'height': 1,
        })).isError,
        isTrue,
      );
    });
  });

  group('session', () {
    test('a run reads, edits, answers, and undoes in one step', () async {
      final (c, editor) = _editor();
      final t = _FakeTransport([
        () => _reply([
          {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
          _toolUse('t1', 'get_outline', {}),
        ], 'tool_use'),
        () => _reply([
          _toolUse('t2', 'set_text', {'node_id': 'title', 'text': 'Dusk'}),
          _toolUse('t3', 'set_properties', {
            'node_ids': ['box'],
            'y': 10,
          }),
        ], 'tool_use'),
        () => _reply([
          {'type': 'text', 'text': 'Retitled and moved the box.'},
        ], 'end_turn'),
      ]);
      final s = AgentSession(
        editor: editor,
        readState: () => c.read(editorControllerProvider),
        transport: t,
      );
      await s.send('Retitle it');
      expect(
        (_node(c, 'title') as ir.TextNode).content.single.spans.single.text,
        'Dusk',
      );
      expect(_node(c, 'box').common.y, 10);
      expect(s.events.value.last, isA<AgentReply>());
      expect(s.running.value, isFalse);

      // The request shape.
      final first = t.bodies.first;
      expect(
        first.containsKey('model'),
        isFalse,
        reason: 'added by the transport',
      );
      expect(first['output_config'], {'effort': 'low'});
      final system = (first['system']! as List).single as Map;
      expect(system['cache_control'], {'type': 'ephemeral'});
      expect((first['tools']! as List).length, kAgentTools.length);
      final userTurn = (first['messages']! as List).single as Map;
      expect(
        ((userTurn['content'] as List).last as Map)['text'],
        contains('<editor_state>'),
      );
      // Both results of the parallel calls come back in one user message,
      // and the thinking block is replayed unchanged.
      final third = t.bodies[2]['messages']! as List;
      expect(
        ((third[1] as Map)['content'] as List).first,
        containsPair('type', 'thinking'),
      );
      final results = (third.last as Map)['content'] as List;
      expect(results.map((r) => (r as Map)['tool_use_id']), ['t2', 't3']);

      final history = c.read(editorControllerProvider).history;
      expect(history.undoLabel, 'Agent: Retitle it');
      editor.undo();
      expect(
        (_node(c, 'title') as ir.TextNode).content.single.spans.single.text,
        'The Hour',
      );
      expect(_node(c, 'box').common.y, 300);
    });

    test('a write after the author edited is refused until re-read', () async {
      final (c, editor) = _editor();
      final t = _FakeTransport([
        () => _reply([_toolUse('t1', 'get_outline', {})], 'tool_use'),
        () {
          // The author moves the box while the model thinks.
          editor.execute(SetProperty(['box'], 'x', const ir.IrValue.number(5)));
          return _reply([
            _toolUse('t2', 'set_properties', {
              'node_ids': ['box'],
              'x': 99,
            }),
          ], 'tool_use');
        },
        () => _reply([
          {'type': 'text', 'text': 'ok'},
        ], 'end_turn'),
      ]);
      final s = AgentSession(
        editor: editor,
        readState: () => c.read(editorControllerProvider),
        transport: t,
      );
      await s.send('Move it');
      expect(_node(c, 'box').common.x, 5);
      final refused = s.events.value.whereType<AgentToolCall>().last;
      expect(refused.isError, isTrue);
      expect(refused.result, contains('changed the document'));
    });

    test('a refusal or a missing key ends the run cleanly', () async {
      final (c, editor) = _editor();
      final t = _FakeTransport([
        () => _reply(const [], 'refusal'),
        () => const AgentException('Add your anthropic key.', needsKey: true),
      ]);
      final s = AgentSession(
        editor: editor,
        readState: () => c.read(editorControllerProvider),
        transport: t,
      );
      await s.send('Hi');
      expect(s.events.value.last, isA<AgentProblem>());
      await s.send('Again');
      final p = s.events.value.last as AgentProblem;
      expect(p.needsKey, isTrue);
      expect(s.messages.last['role'], 'user');
      expect(s.running.value, isFalse);
    });
  });

  group('panel', () {
    Future<ProviderContainer> pump(
      WidgetTester tester, {
      AgentTransport? transport,
      EditorMode mode = EditorMode.design,
      Size size = const Size(1440, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = ProviderContainer();
      addTearDown(root.dispose);
      root.read(editorLayoutProvider.notifier)
        ..setMode(mode)
        ..toggleAgent();
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
      await tester.pump();
      return root;
    }

    testWidgets('without a transport it says what it needs', (tester) async {
      await pump(tester);
      expect(find.byType(AgentPanel), findsOneWidget);
      expect(find.textContaining('signed in'), findsOneWidget);
    });

    testWidgets('a message runs the agent and shows the reply', (tester) async {
      final t = _FakeTransport([
        () => _reply([
          {'type': 'text', 'text': 'Hello from the agent.'},
        ], 'end_turn'),
      ]);
      await pump(tester, transport: t);
      await tester.enterText(find.byKey(const ValueKey('agent-input')), 'Hi');
      await tester.tap(find.byKey(const ValueKey('agent-send')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Hi'), findsOneWidget);
      expect(find.text('Hello from the agent.'), findsOneWidget);
    });

    for (final mode in EditorMode.values) {
      testWidgets('open in ${mode.name} at 1024 px', (tester) async {
        await pump(tester, mode: mode, size: const Size(1024, 768));
        expect(find.byType(AgentPanel), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
