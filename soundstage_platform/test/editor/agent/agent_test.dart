import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/editor/agent/agent_panel.dart';
import 'package:soundstage_platform/editor/agent/agent_policy.dart';
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
  _FakeTransport(this.replies, {this.policy = const AgentPolicy()});

  final List<Object Function()> replies;
  final List<Map<String, Object?>> bodies = [];
  AgentPolicy policy;

  @override
  AgentConfig get config => AgentConfig(effort: 'low', policy: policy);

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

  group('policy', () {
    test('kinds of change', () {
      expect(kindOf('get_outline', {}), isNull);
      expect(kindOf('set_text', {}), AgentActionKind.text);
      expect(
        kindOf('set_properties', {'node_ids': [], 'x': 1}),
        AgentActionKind.layout,
      );
      expect(
        kindOf('set_properties', {'node_ids': [], 'fill': '#000'}),
        AgentActionKind.style,
      );
      expect(kindOf('add_scene', {}), AgentActionKind.structure);
      expect(kindOf('set_note', {}), AgentActionKind.notes);
      expect(kindOf('add_illustration', {}), AgentActionKind.illustration);
    });

    test('auto-act needs every kind enabled, the boundary and the cap', () {
      final doc = _doc();
      bool allows(
        AgentPolicy p,
        List<AgentAction> a, {
        Set<String> sel = const {},
      }) => p.allowsAuto(a, document: doc, selection: sel, activeSceneId: 's1');
      const text = AgentAction('set_text', {'node_id': 'title', 'text': 'x'});
      const move = AgentAction('set_properties', {
        'node_ids': ['box'],
        'x': 1,
      });
      expect(
        allows(const AgentPolicy(), [text]),
        isFalse,
        reason: 'suggest only',
      );
      const textOnly = AgentPolicy(autoAct: {AgentActionKind.text});
      expect(allows(textOnly, [text]), isTrue);
      expect(allows(textOnly, [text, move]), isFalse);
      const selection = AgentPolicy(
        autoAct: {AgentActionKind.text},
        scope: AgentScope.selection,
      );
      expect(allows(selection, [text]), isFalse);
      expect(allows(selection, [text], sel: {'title'}), isTrue);
      expect(
        allows(selection, [text], sel: {'stage'}),
        isTrue,
        reason: 'inside',
      );
      const capped = AgentPolicy(
        autoAct: {AgentActionKind.text},
        maxChanges: 1,
      );
      expect(allows(capped, [text, text]), isFalse);
      const structure = AgentPolicy(autoAct: {AgentActionKind.structure});
      expect(
        allows(structure, [
          const AgentAction('add_scene', {'name': 'n'}),
        ]),
        isFalse,
        reason: 'a new scene is outside the active scene',
      );
      expect(
        allows(structure.copyWith(scope: AgentScope.story), [
          const AgentAction('add_scene', {'name': 'n'}),
        ]),
        isTrue,
      );
    });

    test('JSON round trip, also inside the agent config', () {
      const p = AgentPolicy(
        watch: true,
        autoAct: {AgentActionKind.notes, AgentActionKind.style},
        scope: AgentScope.selection,
        maxChanges: 3,
      );
      final back = AgentConfig.fromJson(
        const AgentConfig(policy: p).toJson(),
      ).policy;
      expect(back.watch, isTrue);
      expect(back.autoAct, p.autoAct);
      expect(back.scope, AgentScope.selection);
      expect(back.maxChanges, 3);
      expect(AgentConfig.fromJson(const {}).policy.autoAct, isEmpty);
    });
  });

  group('review', () {
    Map<String, Object?> suggest(
      String title,
      List<Map<String, Object?>> actions,
    ) => _reply([
      _toolUse('s', 'suggest', {
        'title': title,
        'why': 'Because.',
        'actions': actions,
      }),
    ], 'tool_use');

    test('unasked, it only suggests; applying is one undo step', () async {
      final (c, editor) = _editor();
      final t = _FakeTransport([
        () => _reply([
          _toolUse('w', 'set_text', {'node_id': 'title', 'text': 'Sneaky'}),
        ], 'tool_use'),
        () => suggest('Sharper title', [
          {
            'tool': 'set_text',
            'input': {'node_id': 'title', 'text': 'Dusk'},
          },
          {
            'tool': 'set_properties',
            'input': {
              'node_ids': ['title'],
              'font_size': 64,
            },
          },
        ]),
        () => _reply([
          {'type': 'text', 'text': 'Done.'},
        ], 'end_turn'),
      ]);
      final s = AgentSession(
        editor: editor,
        readState: () => c.read(editorControllerProvider),
        transport: t,
      );
      await s.review();
      // No write tools are offered, and a write is refused.
      final names = [
        for (final tool in t.bodies.first['tools']! as List)
          (tool as Map)['name'],
      ];
      expect(names, containsAll(['get_outline', 'get_board', 'suggest']));
      expect(names, isNot(contains('set_text')));
      expect(
        (_node(c, 'title') as ir.TextNode).content.single.spans.single.text,
        'The Hour',
      );

      final sg = s.suggestions.value.single;
      expect(sg.status, SuggestionStatus.open);
      await s.apply(sg);
      expect(sg.status, SuggestionStatus.applied);
      expect(
        (_node(c, 'title') as ir.TextNode).content.single.spans.single.text,
        'Dusk',
      );
      expect(
        c.read(editorControllerProvider).history.undoLabel,
        'Agent: Sharper title',
      );
      expect(s.undo(sg), isTrue);
      expect(
        (_node(c, 'title') as ir.TextNode).content.single.spans.single.text,
        'The Hour',
      );
      s.dismiss(sg);
      expect(s.suggestions.value, isEmpty);
    });

    test('a suggestion the policy allows applies itself', () async {
      final (c, editor) = _editor();
      final t = _FakeTransport([
        () => suggest('Leave a note', [
          {
            'tool': 'set_note',
            'input': {'id': 's1', 'text': 'Try a darker sky'},
          },
        ]),
        () => _reply([
          {'type': 'text', 'text': 'ok'},
        ], 'end_turn'),
      ], policy: const AgentPolicy(autoAct: {AgentActionKind.notes}));
      final s = AgentSession(
        editor: editor,
        readState: () => c.read(editorControllerProvider),
        transport: t,
      );
      await s.review();
      await Future<void>.delayed(Duration.zero);
      expect(s.suggestions.value.single.status, SuggestionStatus.autoApplied);
      expect(
        c.read(editorControllerProvider).document.notes['s1'],
        'Try a darker sky',
      );
    });

    test(
      'the watcher reviews after a pause, never mid-gesture, rate-limited',
      () {
        fakeAsync((async) {
          final (c, editor) = _editor();
          var reviews = 0;
          final t = _FakeTransport([
            for (var i = 0; i < 10; i++)
              () {
                reviews++;
                return _reply([
                  {'type': 'text', 'text': 'nothing'},
                ], 'end_turn');
              },
          ]);
          final s = AgentSession(
            editor: editor,
            readState: () => c.read(editorControllerProvider),
            transport: t,
          );
          var now = DateTime(2026);
          final w = AgentWatcher(
            s,
            idle: const Duration(seconds: 30),
            minGap: const Duration(minutes: 3),
            now: () => now,
          );
          w.changed();
          async.elapse(const Duration(minutes: 1));
          expect(reviews, 0, reason: 'not watching');

          t.policy = const AgentPolicy(watch: true);
          editor.beginGesture();
          w.changed();
          async.elapse(const Duration(seconds: 31));
          expect(reviews, 0, reason: 'mid-gesture');
          editor.endGesture();
          async.elapse(const Duration(seconds: 31));
          expect(reviews, 1);

          now = now.add(const Duration(seconds: 70));
          w.changed();
          async.elapse(const Duration(seconds: 31));
          expect(reviews, 1, reason: 'too soon');
          now = now.add(const Duration(minutes: 3));
          async.elapse(const Duration(minutes: 3));
          expect(reviews, 2);
          w.dispose();
        });
      },
    );
  });

  testWidgets('the policy dialog stores the author\'s choices', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final stored = <AgentConfig>[];
    final root = ProviderContainer();
    addTearDown(root.dispose);
    root.read(editorLayoutProvider.notifier).toggleAgent();
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
              agentTransport: _FakeTransport([]),
              onAgentConfig: stored.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('agent-policy')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('policy-watch')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('policy-auto:notes')));
    await tester.pump();
    expect(stored.last.policy.watch, isTrue);
    expect(stored.last.policy.autoAct, {AgentActionKind.notes});
  });
}
