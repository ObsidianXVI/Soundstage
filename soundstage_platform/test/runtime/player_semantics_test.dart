// T2.7: the player's screen-reader semantics come from role, readingOrder and
// altText, are invisible, and are described per resolved scene.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soundstage_platform/ir/ir.dart' as ir;
import 'package:soundstage_platform/runtime/runtime.dart';

import 'stage_test_helpers.dart';

ir.NodeCommon _c(
  String id, {
  double x = 0,
  double y = 0,
  double w = 200,
  double h = 40,
  ir.NodeRole role = ir.NodeRole.none,
  int? order,
  String? alt,
}) => common(
  id,
  x: x,
  y: y,
  w: w,
  h: h,
).copyWith(role: role, readingOrder: order, altText: alt);

ir.TextNode _t(String id, String text, ir.NodeCommon c) =>
    textNode(id, text: text, nodeCommon: c);

ir.StageDocument _doc(List<ir.Scene> scenes) =>
    ir.StageDocument(id: 'doc', breakpoints: const [kMobile], scenes: scenes);

ir.Scene _scene(String id, String name, List<ir.Node> children) => ir.Scene(
  id: id,
  name: name,
  root: frame(
    '$id-root',
    common('$id-root', w: 390, h: 844),
    children: children,
  ),
);

/// Labelled nodes below [node], in traversal order, with their kind.
List<String> _walk(SemanticsNode node, [List<String>? out]) {
  out ??= [];
  final d = node.getSemanticsData();
  if (d.label.isNotEmpty) {
    final tag = d.headingLevel > 0
        ? 'h${d.headingLevel}'
        : d.flagsCollection.isImage
        ? 'img'
        : d.role == SemanticsRole.region
        ? 'region'
        : 'text';
    out.add('$tag:${d.label}');
  }
  for (final c in node.debugListChildrenInOrder(
    DebugSemanticsDumpOrder.traversalOrder,
  )) {
    _walk(c, out);
  }
  return out;
}

Future<List<String>> _tree(WidgetTester tester, ir.StageDocument doc) async {
  setViewport(tester, const Size(390, 844));
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: StagePlayer(
        document: doc,
        viewportOverride: const Size(390, 844),
        environment: const StageEnvironment(),
      ),
    ),
  );
  await tester.pump();
  return _walk(tester.getSemantics(find.byType(StagePlayer)));
}

void main() {
  testWidgets('roles become headings, text, figures; decorative is hidden', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final doc = _doc([
      _scene('a', 'Opening', [
        _t('h1', 'The Harbour', _c('h1', y: 40, role: ir.NodeRole.heading1)),
        _t('h2', 'Morning', _c('h2', y: 100, role: ir.NodeRole.heading2)),
        _t('h3', 'Tide', _c('h3', y: 160, role: ir.NodeRole.heading3)),
        rect(
          'hero',
          _c('hero', y: 220, h: 100, role: ir.NodeRole.figure, alt: 'A boat'),
        ),
        _t('cap', 'Dawn, 6am', _c('cap', y: 330, role: ir.NodeRole.caption)),
        _t('p', 'Gulls wheel.', _c('p', y: 380, role: ir.NodeRole.paragraph)),
        _t('q', 'To the sea', _c('q', y: 430, role: ir.NodeRole.quote)),
        _t('plain', 'No role text', _c('plain', y: 480)),
        // an image fill with no alt text and no figure role: not exposed
        rect('bg', _c('bg', y: 520, h: 100, alt: null)),
        frame(
          'deco',
          _c('deco', y: 640, h: 60, role: ir.NodeRole.decorative),
          children: [_t('hidden', 'Sparkle', _c('hidden'))],
        ),
        _t('gone', 'Invisible', _c('gone', y: 720).copyWith(visible: false)),
      ]),
    ]);
    final tree = await _tree(tester, doc);
    expect(tree, [
      'region:Opening',
      'h1:The Harbour',
      'h2:Morning',
      'h3:Tide',
      'img:A boat',
      'text:Dawn, 6am',
      'text:Gulls wheel.',
      'text:To the sea',
      'text:No role text',
    ]);
    handle.dispose();
  });

  testWidgets('a frame\'s text role is inherited by the text in it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final doc = _doc([
      _scene('a', 'S', [
        frame(
          'group',
          _c('group', y: 20, h: 100, role: ir.NodeRole.heading2),
          children: [_t('t', 'Grouped', _c('t'))],
        ),
      ]),
    ]);
    expect(await _tree(tester, doc), ['region:S', 'h2:Grouped']);
    handle.dispose();
  });

  testWidgets('without readingOrder: top-to-bottom, then left-to-right', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    // Declared in a scrambled order.
    final doc = _doc([
      _scene('a', 'S', [
        _t('c', 'C right', _c('c', x: 200, y: 100, w: 100)),
        _t('d', 'D bottom', _c('d', y: 300)),
        _t('a', 'A top', _c('a', y: 20)),
        _t('b', 'B left', _c('b', x: 10, y: 100, w: 100)),
      ]),
    ]);
    expect((await _tree(tester, doc)).skip(1), [
      'text:A top',
      'text:B left',
      'text:C right',
      'text:D bottom',
    ]);
    handle.dispose();
  });

  testWidgets('readingOrder wins, ahead of the visual order', (tester) async {
    final handle = tester.ensureSemantics();
    final doc = _doc([
      _scene('a', 'S', [
        _t('top', 'Top', _c('top', y: 20)),
        _t('mid', 'Mid', _c('mid', y: 100, order: 2)),
        _t('low', 'Low', _c('low', y: 200, order: 1)),
        _t('bottom', 'Bottom', _c('bottom', y: 300)),
      ]),
    ]);
    expect((await _tree(tester, doc)).skip(1), [
      'text:Low',
      'text:Mid',
      'text:Top',
      'text:Bottom',
    ]);
    handle.dispose();
  });

  testWidgets('one landmark per scene, named by the scene', (tester) async {
    final handle = tester.ensureSemantics();
    final doc = _doc([
      _scene('a', 'Opening', [_t('a1', 'One', _c('a1'))]),
      _scene('b', 'Finale', [_t('b1', 'Two', _c('b1'))]),
    ]);
    final tree = await _tree(tester, doc);
    expect(tree.where((l) => l.startsWith('region:')), [
      'region:Opening',
      'region:Finale',
    ]);
    expect(tree.indexOf('text:One'), lessThan(tree.indexOf('region:Finale')));
    handle.dispose();
  });

  testWidgets('semantics are not rebuilt while the story scrolls', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final controller = StagePlayerController();
    final doc = _doc([
      _scene('a', 'A', [_t('a1', 'One', _c('a1'))]),
      _scene('b', 'B', [_t('b1', 'Two', _c('b1'))]),
    ]);
    setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: StagePlayer(
          document: doc,
          viewportOverride: const Size(390, 844),
          environment: const StageEnvironment(),
          controller: controller,
        ),
      ),
    );
    await tester.pump();
    final label = find.semantics.byLabel('One');
    final before = label.evaluate().first.id;
    final builds = StageNodeWidget.debugBuildCount;
    for (var i = 1; i <= 5; i++) {
      controller.scrollController!.jumpTo(i * 10.0);
      await tester.pump();
    }
    expect(StageNodeWidget.debugBuildCount, builds);
    expect(label.evaluate().first.id, before, reason: 'same node');
    handle.dispose();
  });
}
