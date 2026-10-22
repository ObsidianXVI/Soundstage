# Runtime (StagePlayer)

Renders resolved Stage IR (`docs/architecture.md` §4–§7, §14, §17). Import `runtime.dart`, and
import the IR with a prefix (`import 'package:soundstage_platform/ir/ir.dart' as ir;`).

The runtime renders **only** from `ir.ResolvedDocument` / `ir.ResolvedNode`. It never merges
styles or applies patches. Text styling comes from `ResolvedNode.paragraphs` only.

## Layout (`src/render/layout/`)

Pure functions with no render objects, so they can be unit-tested (`test/runtime/layout_table_test.dart`):

- `computeAutoLayout(layout, children, width?, height?, min/max…)` → `AutoLayoutResult { size,
  boxes, paintOrder }`: §4.4 steps 1–8 and 10. A null `width`/`height` means the frame hugs that
  axis. Children are `AutoLayoutChild`s: stored size, per-axis `StageAxisSizing`, min/max,
  rotation, stroke outsets, plus `measure(w?, h?)` and `baseline(size)` callbacks.
- `firstBaselineOf(children, boxes)`: a frame's first baseline (first child with text, in child order).
- `resolveAxisConstraint` / `resolveConstraints`: §4.3, five constraints per axis against
  reference size R and actual size P, then min/max, re-anchored.
- `rotatedFootprint`, `sizeStageChild`, `stagePaintOrder`, `clampSize`.

## Render objects (`src/render/`)

- `RenderStageBox` is the base of every node. It handles:
  - **Layout protocol.** A tight axis is the node's size. Otherwise the node takes its natural
    size: its content if it hugs that axis, else its stored size. Parents measure children with
    dry layout (`getDryLayout`/`getDryBaseline`, which are cached) and then lay them out tight.
  - **Transforms.** Geometric rotation and flips turn the box about its centre. Layout uses the
    rotated footprint. `motion` is paint-only and applies at paint and hit test. `paintTransform`
    exposes the matrix, and parents include it in `applyPaintTransform`.
  - **Invalidation.** `set node` compares by `identical()` and primitives. Changes that affect
    layout call `markStageLayoutDirty()`, which marks this node and its parent, because tight
    children are relayout boundaries. Paint-only changes call `markNeedsPaint()`.
  - **Repaint boundaries.** Off by default. `StageSceneView` turns them on for the scene root and
    for every node a track targets (§17.1).
  - **Compositing.** No `saveLayer` by default. An opacity layer is pushed only when 0 < opacity < 1
    (group opacity), and a clip layer only for `clipContent`.
  - **Fault containment (§17.2).** Exceptions in layout, dry layout or paint are caught at the
    node, reported once through `FlutterError.reportError` (library `soundstage runtime`), and
    the node is sized from its stored geometry. It paints an error box in `StageRenderMode.edit`
    and nothing in `play`, and only edit mode can hit it. Placeholders behave the same way. The
    `debugStageFaultInjector` hook makes tests throw on demand.
- `RenderStageFrame`: free, auto-layout, or grid frames (grid lays out as free until M3). The
  reference size for children's constraints is the frame's stored size, or `referenceSize` (a
  scene root passes `StageSceneView.referenceSizeFor`). It paints fills, then children (clipped
  when `clipContent`), then the stroke.
- `RenderStageText`: §7, through `StageTextLayout`, with separate instances for measuring and
  painting. `firstBaseline` and `textLayout` are exposed.
- `RenderStageShape`: rectangle, ellipse (arc and inner radius), line, polygon and star
  (`shape_geometry.dart`). Video and embed nodes render here until M3.
- `RenderStageScene`: hosts a scene root at a viewport size and paints the scene background.

## Widgets (`src/widgets/`)

- `StageScope(environment:)` provides the `StageEnvironment`: mode, `StageFontTable`, `StageMedia`
  and the painter. Use `StageEnvironment.forDocument(doc, mode:)`.
- `StageNodeWidget(node:)` maps a `ResolvedNode` subtree to render-object widgets, keyed by node id.
- `StageSceneView(scene:, viewportSize:, breakpoint:)`: a pinned scene's root is sized to the
  viewport. A flow scene's root takes the viewport width and its own vertical sizing. T0.6 wraps
  this in slivers and clocks.

## The paint seam (`src/paint/`)

`StageAppearancePainter` has `paintFills(canvas, outline, fills, media:, onImageReady:, devicePixelRatio:)`,
`paintStroke(canvas, outline, stroke)` and `paintErrorBox(canvas, rect)`. Render objects call
them in local coordinates with a `StageOutline` (a rounded box or a path, open for lines).
Clipping and opacity stay in the render objects.

T0.4 implements only:
- solid fills;
- image fills in `fill` mode with `focalPoint` (`imageFillRect`), which paint the asset's
  placeholder colour while loading. Other scale modes paint as `fill`;
- solid strokes with one weight (per-side weights use the largest side), aligned
  inside/center/outside, with caps and joins.

T0.5 replaces the internals (gradients, scale modes, filters, dashes, per-side strokes, effects,
corner smoothing, blend modes, text paint stacks via `srcIn`) without changing the signatures.

## Media (`src/media/`)

- `StageAssetResolver` resolves `asset://<path>` from the bundle. It picks the smallest variant at
  least as wide as the target. `local://` and `https://` are not wired yet.
- `StageImageCache` is a byte-bounded LRU of decoded `ui.Image`s (default 128 MiB). A miss loads
  once and notifies listeners. It evicts and disposes images only when a load completes.
- `StageMedia` combines the two.
- `StageFontTable` maps `fontFamilyId` to a family name. Font loading is T0.7; until then
  unloaded families render in the default font.

## Behaviour notes

These are choices the spec left open, made to be Figma-consistent. The ones marked (DN) are in
`DECISIONS_NEEDED.md`.

**Sizing**

1. **Per-axis sizing.** A node's size mode on each axis comes only from
   `layoutChild.horizontalSizing`/`verticalSizing` (fixed | hug | fill). `fill` applies only inside
   an auto-layout parent. `hug` on a frame means "hug the auto-layout content", so a frame
   without auto layout (or a grid frame, until M3) treats `hug` as `fixed`. Text also hugs
   according to `autoResize` (`widthAndHeight`: both axes; `height`: height). Shapes never hug.
2. **Direction flips keep sizing.** Because sizing is per axis rather than relative to the
   direction, a breakpoint patch that flips `autoLayout.direction` keeps each axis's mode (the
   demo's card row hugs vertically in both directions). (Settled in DECISIONS.md.)
3. **Counter-axis fill in a hugging counter axis.** It stretches to the largest non-fill sibling.
   If every child fills, they hug. In wrapped rows, counter fill takes the row's height.

**Auto layout**

4. **`gap: auto` with fill children.** Fill children are sized with a gap of 0, and space left
   over (fills frozen at max) becomes the gap. Overflow gives a gap of 0 with the run at the
   start. `counterAxisGap: auto` spreads wrapped rows the same way, with a single row at the start.
5. **Wrap.** It applies only to horizontal layouts with a definite width; a hugging width never
   wraps. A row breaks when the next child's footprint (min width for `fill`) would overflow.
   Fill children then split their own row.
6. **Rotated children.** A rotated child whose sizing is `fill` keeps its stored size on that
   axis. Its footprint is the bounding box of the stroke-inflated box. Its baseline is the
   footprint's bottom edge.
7. **Baseline alignment.** The baseline block starts at the top of the content box (or the row).
   A frame's first baseline is its first in-flow child with text, in child order (any visible
   child for free frames). A child without text uses its bottom edge.

**Constraints**

8. **Absolute children.** Stored `x/y/w/h` is the unrotated box, rotated about its centre.
   - On a hugging axis with `start`/`end`/`center`, the measured size is anchored by the stored
     margins (right-anchored text grows leftwards).
   - With `stretch`/`scale`, the constraint sets the size, and text wraps to it.
9. **Scene root reference size (DN).**
   - Pinned: the breakpoint's `designSize`.
   - Flow: `designSize.width` × the root's stored height, because a flow root's height is not a
     viewport height.

**Transforms**

10. **Rotation direction (DN).** Positive geometric `rotation` is clockwise on screen (y down),
    like ellipse arcs and `motion.rotate`. Figma's UI shows counter-clockwise, so the editor can
    negate it for display.
11. **Motion.** It applies on top of the geometric transform, in the parent's space. Its origin is
    normalised in the unrotated box, so a `translateY` scroll animation moves along the screen
    even for rotated nodes.

**Text**

12. **Paragraphs, indent and lists.**
    - Paragraph spacing follows every paragraph except the last.
    - `paragraphIndent` indents the first line, including in list items.
    - The list gutter is `max(1.5 em, marker width + 0.5 em)`, using the first span's style
      without decoration.
    - Consecutive ordered paragraphs count 1, 2, 3, and any non-ordered paragraph resets the count.
13. **Truncation.**
    - Lines are cut with an ellipsis when `autoResize: truncate` or `truncation: ending`. The
      limit is `maxLines` plus, for a definite box height, the lines that fit.
    - The first paragraph always shows at least one line.
    - Paragraphs past the cut are dropped. When the cut falls exactly at a paragraph boundary,
      the previous paragraph gets no ellipsis.
    - `maxLines` without truncation is ignored.
14. **Overflow.** Fixed text overflows its box visibly. `alignVertical` distributes overflow the
    way it distributes free space, so `middle` overflows both ways.
15. **Best-effort styling** (until font metrics and the paint pipeline land in T0.5/T0.7):
    - decoration thickness assumes the font's own thickness is 1/16 em;
    - `skipInk` is not supported;
    - `baselineShift` uses the `sups`/`subs` features, with no synthetic shift;
    - the text colour is the first visible solid fill (a gradient's first stop stands in);
    - text ignores the OS text scale (`TextScaler.noScaling`), because stories are art-directed.

**Shapes and rendering**

16. **Shapes.**
    - Polygons and stars start at the top and are stretched to fill their box (Figma).
    - A line is drawn through the box's vertical centre and always has a centred stroke.
    - A partial ellipse arc is a pie slice; with an inner radius it is a ring segment.
17. **Paint and hit order.**
    - Frame strokes paint above children.
    - Hidden children are laid out at their stored geometry but neither painted nor hit-tested.
    - Unclipped frames let overflowing children be hit; clipped frames do not.
