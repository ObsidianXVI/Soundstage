// The lyrics transcript is exposed as text, whole and static: nothing
// changes in the semantics tree while lines go by (so a screen reader hears
// nothing per line). Reads the demo with dart:io (see sound_demo_test.dart).
@TestOn('vm')
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/runtime/runtime.dart';

import 'sound_demo_test.dart' show loadSoundDemo;
import 'stage_test_helpers.dart';

void main() {
  testWidgets('the whole transcript is one text node, not live', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    setViewport(tester, const Size(390, 844));
    final doc = loadSoundDemo();
    final controller = StagePlayerController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StagePlayer(
          document: doc,
          viewportOverride: const Size(390, 844),
          environment: StageEnvironment.forDocument(doc),
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    // Into the lyric scene (the second, pinned).
    controller.scrollController!.jumpTo(844 * 2.5 + 400);
    await tester.pump();
    await tester.pump();

    const transcript =
        'Lights go low across the stage\n'
        'every word becomes a sound\n'
        'scroll the night and turn the page\n'
        'till the story comes around';
    final node = find.semantics.byLabel(transcript);
    expect(node, findsOneWidget);
    final data = node.evaluate().first.getSemanticsData();
    expect(data.flagsCollection.isLiveRegion, isFalse);

    // Time passing changes which line is active, never the semantics.
    final id = node.evaluate().first.id;
    final audio = controller.animator!;
    audio.notifyClockChanged();
    await tester.pump(const Duration(seconds: 2));
    expect(find.semantics.byLabel(transcript).evaluate().first.id, id);
    handle.dispose();
  });
}
