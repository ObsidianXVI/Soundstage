import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';
import 'package:soundstage_platform/runtime/src/interactions/open_url.dart';
import 'package:soundstage_platform/runtime/src/interactions/stage_interactions.dart';

import 'stage_test_helpers.dart';

ir.Interaction _i(ir.InteractionTrigger t, List<ir.Action> a) =>
    ir.Interaction(id: 'i${t.hashCode}', trigger: t, actions: a);

ir.ResolvedDocument _resolved(
  List<ir.Node> children, {
  List<ir.Clock> clocks = const [],
}) => ir.resolveDocument(
  ir.StageDocument(
    id: 'd',
    breakpoints: const [kDesktop],
    scenes: [
      ir.Scene(
        id: 's',
        root: ir.FrameNode(
          common: const ir.NodeCommon(id: 'root', width: 800, height: 600),
          children: children,
        ),
        clocks: clocks,
      ),
    ],
  ),
);

ir.FrameNode _node(
  String id,
  List<ir.Interaction> list, {
  List<ir.Node> kids = const [],
}) => ir.FrameNode(
  common: ir.NodeCommon(id: id, width: 100, height: 100, interactions: list),
  children: kids,
);

void main() {
  group('trigger semantics', () {
    late List<String> log;
    late StageInteractions e;
    setUp(() {
      log = [];
      e = StageInteractions(
        StageInteractionHost(
          playTimeline: (id) => log.add('play $id'),
          scrollToScene: (id) => log.add('scroll $id'),
          seekAudio: (id, s) => log.add('seek $id $s'),
        ),
      );
    });

    test('a tap runs the innermost node that has a tap interaction', () {
      e.load(
        _resolved([
          _node(
            'outer',
            [
              _i(const ir.InteractionTrigger.tap(), [
                const ir.Action.playTimeline(clockId: 'o'),
              ]),
            ],
            kids: [
              _node('inner', [
                _i(const ir.InteractionTrigger.tap(), [
                  const ir.Action.playTimeline(clockId: 'i'),
                ]),
              ]),
              _node('plain', const []),
            ],
          ),
        ]),
      );
      expect(e.hasTapTriggers, isTrue);
      e.tap(['inner', 'outer', 'root']);
      e.tap(['plain', 'outer', 'root']);
      expect(e.tap(['root']), isFalse);
      expect(log, ['play i', 'play o']);
    });

    test('hover enter and leave fire on changes only', () {
      e.load(
        _resolved([
          _node('a', [
            _i(const ir.InteractionTrigger.hoverEnter(), [
              const ir.Action.playTimeline(clockId: 'in'),
            ]),
            _i(const ir.InteractionTrigger.hoverLeave(), [
              const ir.Action.playTimeline(clockId: 'out'),
            ]),
          ]),
        ]),
      );
      e
        ..hover(['a', 'root'])
        ..hover(['a', 'root'])
        ..hover(['root'])
        ..hover(const []);
      expect(log, ['play in', 'play out']);
    });

    test('scene enter and leave fire on visibility edges', () {
      e.load(
        _resolved([
          _node('a', [
            _i(const ir.InteractionTrigger.sceneEnter(), [
              const ir.Action.scrollToScene(sceneId: 'x'),
            ]),
          ]),
        ]),
      );
      e
        ..sceneVisible('s', visible: true)
        ..sceneVisible('s', visible: true)
        ..sceneVisible('s', visible: false)
        ..sceneVisible('s', visible: true);
      expect(log, ['scroll x', 'scroll x']);
    });

    test('clock reach and audio cues fire on crossing, both ways', () {
      e.load(
        _resolved(
          [
            _node('a', [
              _i(
                const ir.InteractionTrigger.clockReach(
                  clockId: 'c',
                  value: 0.5,
                ),
                [const ir.Action.playTimeline(clockId: 'reach')],
              ),
              _i(
                const ir.InteractionTrigger.audioCue(
                  audioTrackId: 't',
                  time: 2,
                ),
                [const ir.Action.seekAudio(audioTrackId: 't', time: 0)],
              ),
            ]),
          ],
          clocks: const [
            ir.Clock.timeline(id: 'c', duration: 1),
            ir.Clock.audio(id: 'ac', audioTrackId: 't'),
          ],
        ),
      );
      e
        ..clock('c', 0.2) // arms
        ..clock('c', 0.5) // reaches
        ..clock('c', 0.7)
        ..clock('c', 0.3) // back across
        ..clock('ac', 1.9)
        ..clock('ac', 2.1);
      expect(log, ['play reach', 'play reach', 'seek t 0.0']);
    });
  });

  test('only web-safe URLs open', () {
    expect(openStageUrl('javascript:alert(1)', newTab: true), isFalse);
    expect(openStageUrl('file:///etc/passwd', newTab: true), isFalse);
    // Outside the browser nothing opens, but the URL is accepted.
    expect(openStageUrl('https://example.com', newTab: true), isFalse);
  });

  testWidgets('in the player a tap sets a variable and the stage '
      're-resolves with it', (tester) async {
    setViewport(tester, const Size(800, 600));
    final doc = ir.StageDocument(
      id: 'd',
      breakpoints: const [kDesktop],
      tokens: const ir.TokenSystem(
        collections: [
          ir.VariableCollection(
            id: 'c',
            name: 'State',
            modes: [ir.TokenMode(id: 'm', name: 'M')],
            defaultModeId: 'm',
            variables: [
              ir.Variable(
                id: 'open',
                name: 'open',
                type: ir.VariableType.number,
                valuesByMode: {'m': ir.IrValue.number(0.2)},
              ),
            ],
          ),
        ],
      ),
      scenes: [
        ir.Scene(
          id: 's',
          root: ir.FrameNode(
            common: const ir.NodeCommon(id: 'root', width: 800, height: 600),
            children: [
              ir.FrameNode(
                common: ir.NodeCommon(
                  id: 'btn',
                  x: 100,
                  y: 100,
                  width: 200,
                  height: 100,
                  bindings: const {'opacity': ir.TokenRef(variableId: 'open')},
                  interactions: [
                    _i(const ir.InteractionTrigger.tap(), [
                      const ir.Action.setVariable(
                        variableId: 'open',
                        value: ir.IrValue.number(1),
                      ),
                    ]),
                  ],
                ),
                appearance: const ir.Appearance(
                  fills: [ir.Paint.solid(id: 'f', color: ir.StageColor.black)],
                ),
              ),
            ],
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: StagePlayer(
          document: doc,
          viewportOverride: const Size(800, 600),
          environment: const StageEnvironment(),
        ),
      ),
    );
    await tester.pump();
    expect(stageBox(tester, 'btn').common.opacity, 0.2);
    await tester.tapAt(const Offset(200, 150));
    await tester.pump();
    await tester.pump();
    expect(stageBox(tester, 'btn').common.opacity, 1);
  });
}
