import 'package:soundstage_platform/export/export.dart' show orderedChildren;
import 'package:soundstage_platform/ir/ir.dart' as ir;

// The Writing view's model (m5.md T5.2, DECISIONS 26/10/26 #5): a
// projection over the story's text nodes, scene by scene. The main flow is
// the reading order the static exports use; text it does not reach
// (decorative, hidden, or under a figure) is listed after it, so every text
// box stays reachable.

/// What a block in the Writing view is.
enum WritingBlockKind { text, figure }

/// One block of a scene in the Writing view.
class WritingBlock {
  const WritingBlock({
    required this.kind,
    required this.nodeId,
    required this.role,
    this.inFlow = true,
    this.readOnly = false,
    this.label = '',
  });

  final WritingBlockKind kind;

  /// The node (for text inside an instance, its `instance/child` path).
  final String nodeId;
  final ir.NodeRole role;

  /// In the main reading flow (false: "other text in this scene").
  final bool inFlow;

  /// Text inside a component instance: edited on the component.
  final bool readOnly;

  /// A figure's alt text, or the layer name of an out-of-flow text box.
  final String label;
}

/// A scene in the Writing view.
class WritingScene {
  const WritingScene({
    required this.id,
    required this.name,
    required this.blocks,
  });

  final String id;
  final String name;
  final List<WritingBlock> blocks;

  Iterable<WritingBlock> get flow => blocks.where((b) => b.inFlow);
  Iterable<WritingBlock> get other => blocks.where((b) => !b.inFlow);
}

/// The Writing view's scenes for [resolved] (one breakpoint's resolution).
List<WritingScene> writingScenes(ir.ResolvedDocument resolved) => [
  for (final s in resolved.scenes)
    WritingScene(id: s.id, name: s.name, blocks: _blocksOf(s.root)),
];

List<WritingBlock> _blocksOf(ir.ResolvedNode root) {
  final flow = <WritingBlock>[];
  final reached = <String>{};

  void visit(ir.ResolvedNode n, {bool isRoot = false}) {
    final node = n.node;
    final common = node.common;
    if (!common.visible || n.isPlaceholder) return;
    final role = common.role;
    if (role == ir.NodeRole.decorative) return;
    if (!isRoot && role == ir.NodeRole.figure && node is! ir.TextNode) {
      flow.add(
        WritingBlock(
          kind: WritingBlockKind.figure,
          nodeId: n.id,
          role: role,
          label: common.altText ?? '',
        ),
      );
      // A figure's caption is part of the flow, right after it.
      for (final t in _textUnder(n)) {
        if (t.node.common.role == ir.NodeRole.caption) {
          reached.add(t.id);
          flow.add(_text(t));
        }
      }
      return;
    }
    switch (node) {
      case ir.TextNode():
        reached.add(n.id);
        flow.add(_text(n));
      case ir.FrameNode():
        for (final c in orderedChildren(n)) {
          visit(c);
        }
      default:
        break;
    }
  }

  visit(root, isRoot: true);
  final other = [
    for (final t in _textUnder(root))
      if (!reached.contains(t.id)) _text(t, inFlow: false),
  ];
  return [...flow, ...other];
}

WritingBlock _text(ir.ResolvedNode n, {bool inFlow = true}) => WritingBlock(
  kind: WritingBlockKind.text,
  nodeId: n.id,
  role: n.node.common.role,
  inFlow: inFlow,
  readOnly: n.instanceId != null || n.id.contains('/'),
  label: n.node.common.name,
);

/// Every text node under [n] (including hidden ones), in tree order.
List<ir.ResolvedNode> _textUnder(ir.ResolvedNode n) {
  final out = <ir.ResolvedNode>[];
  void walk(ir.ResolvedNode c) {
    if (c.isPlaceholder) return;
    if (c.node is ir.TextNode) out.add(c);
    for (final k in c.children) {
      walk(k);
    }
  }

  walk(n);
  return out;
}
