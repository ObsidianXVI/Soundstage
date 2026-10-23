import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

const ir.Breakpoint _bp = ir.Breakpoint(
  id: 'only',
  name: 'Only',
  minWidth: 0,
  designSize: ir.StageSize(width: 800, height: 600),
);

ir.Scene _flow(String id, double height) => ir.Scene(
  id: id,
  root: ir.FrameNode(
    common: ir.NodeCommon(id: '$id-root', width: 800, height: height),
  ),
  clocks: [ir.Clock.sceneScroll(id: '$id-c', sceneId: id)],
);

void main() {
  // The reader scrolls with the keyboard once the enter gate has gone: the
  // player owns the focus ScrollAction needs.
  Future<StagePlayerController> pump(WidgetTester tester) async {
    final controller = StagePlayerController();
    await tester.pumpWidget(
      MaterialApp(
        home: StagePlayer(
          document: ir.StageDocument(
            id: 'doc',
            breakpoints: const [_bp],
            scenes: [_flow('a', 3000), _flow('b', 3000)],
          ),
          mode: StageRenderMode.play,
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    return controller;
  }

  for (final (key, name) in [
    (LogicalKeyboardKey.pageDown, 'PageDown'),
    (LogicalKeyboardKey.space, 'Space'),
    (LogicalKeyboardKey.arrowDown, 'ArrowDown'),
  ]) {
    // Space and the arrows are default scroll shortcuts on the web only;
    // PageDown is one everywhere.
    testWidgets(
      '$name scrolls the story',
      skip: !kIsWeb && key != LogicalKeyboardKey.pageDown,
      (tester) async {
        tester.view
          ..physicalSize = const Size(800, 600)
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final c = await pump(tester);
        expect(c.scrollController!.offset, 0);
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
        expect(c.scrollController!.offset, greaterThan(20), reason: name);
      },
    );
  }
}
