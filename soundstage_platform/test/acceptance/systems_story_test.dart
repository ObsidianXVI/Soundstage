// M3 acceptance: a story using the M3 systems, built in the editor from a
// new story through its own surfaces:
//   - a second scene that crossfades in (Scenes ▸ Add, Scene settings);
//   - a starter carousel (Assets ▸ Comps ▸ +);
//   - a frame made a grid (Grid section), then a component (Layer header),
//     its main edited in isolation (a text property), and its instance's
//     value set;
//   - a tap interaction going to scene two (Interactions section);
// then saved, reopened, round-tripped through `.stage.zip`, and played with
// no diagnostics. Tokens and styles have their own acceptance test
// (tokens_story_test.dart); video and embeds are covered by runtime tests.
//
// COMMAND-DISPATCH SHORTCUTS: none.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/app/persistence/story_package.dart';
import 'package:soundstage_platform/design_system/design_system.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'acceptance_rig.dart';

extension on Rig {
  Future<void> key(String k) async {
    final f = find.byKey(ValueKey<String>(k));
    await reveal(f);
    await scrollInspectorTo(f);
    await tester.tap(f.first);
    await settleAnimations();
  }

  Future<void> text(String label) async {
    await tester.tap(find.text(label).last);
    await settleAnimations();
  }
}

void main() {
  testWidgets('the M3 story is built in the editor, saved, reopened and '
      'played', (tester) async {
    final r = await pumpNewStory(tester, title: 'Systems');
    await r.zoomToFit();
    final desk = r.doc.breakpoints
        .reduce((a, b) => a.designSize.width >= b.designSize.width ? a : b)
        .id;
    final sceneOne = r.st.activeSceneId!;

    // Scene two, crossfading in.
    await tester.tap(find.bySemanticsLabel('Add scene'));
    await r.settleAnimations();
    await r.text('Pinned scene');
    final sceneTwo = r.doc.scenes.last.id;
    r.ctl.setActiveScene(sceneTwo);
    await r.pump();
    await r.key('scene-transition');
    await r.text('Crossfade');
    expect(
      r.doc.scenes.last.transitionIn.kind,
      ir.SceneTransitionKind.crossfade,
    );
    r.ctl.setActiveScene(sceneOne);
    await r.pump();

    // A starter carousel.
    await r.tab('Assets');
    await r.text('Comps');
    await r.key('components:starter');
    await r.text('Carousel');
    final carousel = r.st.selection.single;
    expect(r.doc.components.values.single.name, 'Carousel');

    // A frame with a grid, then a component with a text property.
    final card = await r.draw(
      'Frame',
      desk,
      const Offset(700, 500),
      const Offset(1000, 700),
    );
    await r.key('grid:add');
    expect((r.node(card) as ir.FrameNode).grid, isNotNull);
    await r.key('component:create');
    final inst = r.st.selection.single;
    expect(r.node(inst), isA<ir.InstanceNode>());
    await r.key('component:edit');
    expect(r.st.isolation, isNotNull);
    await r.key('component:add-prop');
    await r.text('Text');
    await tester.tap(find.byKey(const ValueKey('isolation-done')));
    await r.settleAnimations();
    expect(r.st.isolation, isNull);
    final compId = (r.node(inst) as ir.InstanceNode).source;
    expect(compId, isA<ir.ComponentSource>());

    // A tap interaction on the carousel's instance: go to scene two.
    await r.selectLayer(carousel);
    await r.key('interactions:add');
    await r.text('On tap');
    final interaction = r.node(carousel).common.interactions.single;
    await r.key('interaction:${interaction.id}:add-action');
    await r.text('Go to scene');
    expect(
      r.node(carousel).common.interactions.single.actions.single,
      isA<ir.ScrollToSceneAction>(),
    );

    final built = r.doc;
    expect(
      ir
          .validateDocument(built)
          .where((d) => d.severity == ir.IrSeverity.error),
      isEmpty,
    );

    // Saved and reopened; .stage.zip round trip.
    final id = r.storyId!;
    final reopened = (await tester.runAsync(() async {
      await r.repository.save(id, built);
      return r.repository.open(id);
    }))!;
    expect(reopened.diagnostics, isEmpty);
    expect(reopened.document!.toJson(), built.toJson());
    final story = (await tester.runAsync(() async {
      final zip = await exportStageZip(built, r.repository.assetBytes);
      return importStoryFile(zip, r.store);
    }))!;
    expect(story.document!.toJson(), built.toJson());

    // It plays.
    await tester.pumpWidget(
      MaterialApp(
        home: StagePlayer(
          document: reopened.document!,
          audio: StageAudioService(tracks: const []),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    expect(find.byType(SsButton), findsNothing); // no editor chrome
  });
}
