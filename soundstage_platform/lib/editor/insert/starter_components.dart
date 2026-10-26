import 'package:soundstage_platform/ir/ir.dart' as ir;

import '../core/command.dart';
import '../core/editor_state.dart';

// Starter components (architecture §9; m3.md T3.3): ready-made components
// built on the behaviours, added to a story as an ordinary component plus an
// instance, then edited like any other. Placeholder fills show where images
// go.

/// The starters, in menu order.
enum StarterComponent { gallery, carousel, tiles }

String starterName(StarterComponent s) => switch (s) {
  StarterComponent.gallery => 'Gallery',
  StarterComponent.carousel => 'Carousel',
  StarterComponent.tiles => 'Tiles',
};

const _placeholder = ir.StageColor(r: 0.86, g: 0.87, b: 0.9);
const _ink = ir.StageColor(r: 0.1, g: 0.1, b: 0.12);

ir.Paint _fill(ir.IdGenerator ids, ir.StageColor c) =>
    ir.Paint.solid(id: ids.next(), color: c);

ir.FrameNode _box(
  ir.IdGenerator ids,
  String name,
  double w,
  double h, {
  ir.LayoutChild layoutChild = const ir.LayoutChild(),
  List<ir.Node> children = const [],
  ir.AutoLayout? autoLayout,
}) => ir.FrameNode(
  common: ir.NodeCommon(
    id: ids.next(),
    name: name,
    width: w,
    height: h,
    layoutChild: layoutChild,
  ),
  appearance: ir.Appearance(
    fills: [_fill(ids, _placeholder)],
    cornerRadius: const ir.CornerRadius.uniform(8),
  ),
  autoLayout: autoLayout,
  children: children,
  clipContent: true,
);

ir.TextNode _text(ir.IdGenerator ids, String text, double size, double w) =>
    ir.TextNode(
      common: ir.NodeCommon(
        id: ids.next(),
        name: text,
        width: w,
        height: size * 1.4,
        layoutChild: const ir.LayoutChild(horizontalSizing: ir.Sizing.fill),
      ),
      autoResize: ir.TextAutoResize.height,
      style: ir.TextStyleOverride(fontSize: size, fills: [_fill(ids, _ink)]),
      content: [
        ir.Paragraph(spans: [ir.Span(text: text)]),
      ],
    );

/// The main frame of starter [s] (fresh ids from [ids]).
ir.FrameNode starterRoot(StarterComponent s, ir.IdGenerator ids) {
  switch (s) {
    case StarterComponent.gallery:
      const cell = ir.LayoutChild(
        grid: ir.GridPlacement(
          alignX: ir.GridAlign.stretch,
          alignY: ir.GridAlign.stretch,
        ),
      );
      return ir.FrameNode(
        common: ir.NodeCommon(
          id: ids.next(),
          name: 'Gallery',
          width: 800,
          height: 412,
        ),
        behavior: const ir.Behavior.lightbox(),
        grid: const ir.GridLayout(
          columns: [
            ir.GridTrack.flex(),
            ir.GridTrack.flex(),
            ir.GridTrack.flex(),
          ],
          rows: [ir.GridTrack.fixed(200), ir.GridTrack.fixed(200)],
          columnGap: 12,
          rowGap: 12,
        ),
        children: [
          for (var i = 0; i < 6; i++)
            _box(ids, 'Image ${i + 1}', 200, 200, layoutChild: cell),
        ],
      );
    case StarterComponent.carousel:
      return ir.FrameNode(
        common: ir.NodeCommon(
          id: ids.next(),
          name: 'Carousel',
          width: 800,
          height: 420,
        ),
        behavior: const ir.Behavior.carousel(loop: true, peek: 40),
        autoLayout: const ir.AutoLayout(
          gap: ir.Gap.fixed(16),
          padding: ir.EdgeInsetsValue(left: 40, right: 40),
        ),
        children: [
          for (var i = 0; i < 4; i++) _box(ids, 'Slide ${i + 1}', 680, 420),
        ],
      );
    case StarterComponent.tiles:
      return ir.FrameNode(
        common: ir.NodeCommon(
          id: ids.next(),
          name: 'Tiles',
          width: 800,
          height: 400,
          layoutChild: const ir.LayoutChild(verticalSizing: ir.Sizing.hug),
        ),
        grid: const ir.GridLayout(
          columns: [ir.GridTrack.flex(), ir.GridTrack.flex()],
          columnGap: 16,
          rowGap: 16,
        ),
        children: [
          for (var i = 0; i < 4; i++)
            _box(
              ids,
              'Tile ${i + 1}',
              392,
              180,
              layoutChild: const ir.LayoutChild(
                grid: ir.GridPlacement(alignX: ir.GridAlign.stretch),
              ),
              autoLayout: const ir.AutoLayout(
                direction: ir.LayoutDirection.vertical,
                gap: ir.Gap.fixed(8),
                padding: ir.EdgeInsetsValue(
                  left: 20,
                  right: 20,
                  top: 20,
                  bottom: 20,
                ),
              ),
              children: [
                _text(ids, 'Tile title', 24, 352),
                _text(ids, 'A sentence or two about this tile.', 16, 352),
              ],
            ),
        ],
      );
  }
}

/// Adds starter [starter] as a new component and puts an instance of it in
/// frame [parentId] at ([x], [y]), selected. One undo step.
class AddStarterComponent extends EditCommand {
  const AddStarterComponent(
    this.starter, {
    required this.parentId,
    this.x = 40,
    this.y = 40,
    this.ids,
  });

  final StarterComponent starter;
  final String parentId;
  final double x;
  final double y;
  final ir.IdGenerator? ids;

  @override
  String get label => 'Add ${starterName(starter).toLowerCase()}';

  @override
  CommandResult apply(EditorState state) {
    final gen = ids ?? ir.IdGenerator.forDocument(state.document);
    final root = starterRoot(starter, gen);
    final compId = gen.next(), instId = gen.next();
    final doc = state.document;
    final withDef = doc.copyWith(
      components: {
        ...doc.components,
        compId: ir.ComponentDef(
          id: compId,
          name: starterName(starter),
          root: root,
        ),
      },
    );
    final parent = ir.DocumentIndex.of(withDef).node(parentId);
    final r = ir.insertNodes(
      withDef,
      parentId,
      parent is ir.FrameNode ? parent.children.length : 0,
      [
        ir.InstanceNode(
          common: ir.NodeCommon(
            id: instId,
            name: starterName(starter),
            x: x,
            y: y,
            width: root.common.width,
            height: root.common.height,
          ),
          source: ir.InstanceSource.component(compId),
        ),
      ],
    );
    return resultOf(state, r, label: label, selectionAfter: {instId});
  }
}
