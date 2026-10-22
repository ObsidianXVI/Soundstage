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
  viewport. A flow scene's root takes the viewport width and its own vertical sizing. `StagePlayer` wraps
  it in a `SliverStageScene`.

## The paint seam (`src/paint/`)

`StageAppearancePainter` (signatures extended with optional `opacity`, `media`, `onImageReady`,
`devicePixelRatio`): `paintFills`, `paintStroke`, `paintDropShadows`, `paintInnerShadows`,
`paintStack` (the shared paint-stack engine, also used for strokes and text masks) and
`paintErrorBox`. They draw onto the canvas in node-local coordinates with a `StageOutline` (plain
or smoothed rounded box, or a path; `insetBy`/`inflated` keep corners concentric). Render objects
call `paintStageAppearance` (`appearance_compositor.dart`): background blur, then inside the
layer blur: drop shadows, fills, inner shadows, children, stroke. Text goes through
`paintStageText` (`render/text/text_paint.dart`). Pure geometry (testable): `placeImage`,
`imageTransform`, `gradientBasis`/`diamondMesh`, `strokeBand`, `dashPath`, `imageFilterMatrix`,
`smoothedRectPath` (corner smoothing, after figma-squircle's `draw.ts`/`distribute.ts`).

**Layer cost.** Fills, strokes, shadows, gradients, images and corner smoothing draw straight
onto the canvas (no layer). A layer is used only for: opacity < 1 when the node has children or
more than one painted part (otherwise opacity is folded into the paint colours); a non-normal
blend mode, or a `normal` frame with a blending child (one `saveLayer`; `passThrough` frames
use none); layer blur (one `ImageFilterLayer`); background blur (clip + `BackdropFilterLayer`,
which re-blurs the backdrop every repaint, so use sparingly); clipping frames (a clip layer); text
with gradient/image fills or non-centre/non-solid strokes (two `saveLayer`s per fill stack), and
text drop shadows (one to three `saveLayer`s each).

## Media (`src/media/`)

- `StageAssetResolver` resolves `asset://<path>` from the bundle. It picks the smallest variant at
  least as wide as the target. `local://` and `https://` are not wired yet.
- `StageImageCache` is a byte-bounded LRU of decoded `ui.Image`s (default 128 MiB). A miss loads
  once and notifies listeners. It evicts and disposes images only when a load completes.
- `StageMedia` combines the two.
- `StageFontTable` (T0.7) maps `fontFamilyId` to the engine family a text style renders with and
  loads the document's font files with Flutter's `FontLoader` (`registerFontWithFontLoader`).
  - Each face registers as `ss-<familyId>-<fnv1a of id + faces>-<faceIndex>`, once per process.
  - `faceFor(id, weight, italic)` picks a face by CSS font matching (`pickFace`). Looking up an
    unloaded family starts loading it (`loadOnDemand`), and `ensureLoaded(ids)` awaits families.
  - Until a family loads, text uses its generic fallback (`fallbackFamily`: platform default for
    sans, `serif`, `monospace`). When it loads, listeners are told and only the text render
    objects whose spans use it reset their layouts and relayout.
  - `fontVariationsFor` adds `wght` (the weight), `opsz` (the font size) and `ital`/`slnt` (italic
    on a non-italic face) on variable faces unless the style sets them. A variable `wght` face is
    laid out with `FontWeight.w400` and a static face with its own weight, so the engine never
    synthesises bold on top.
  - `parseFontMetrics` (`font_metrics.dart`, pure Dart) reads `head`/`OS/2`. Problems (missing
    assets, no OS/2 v2+) are `diagnostics`, never exceptions.
- `StageAudioService` (`audio.dart`, T0.7) plays the document's `AudioTrack`s on `just_audio`
  (`JustAudioBackend`; `StageAudioBackend` is the test seam). See notes 37–40.
- `StageMedia.ready(assetId)` completes when an image is decoded, or after a timeout.

## Motion (T0.6: `src/scenes/`, `src/clocks/`, `src/animator/`)

**StagePlayer** (`scenes/stage_player.dart`):
`StagePlayer(document:, mode:, viewportOverride:, initialSceneId:, clockOverrides:, environment:, clockFactories:, controller:, lazyWindow:)`.
- Resolves with a long-lived `ir.Resolver` for the viewport's breakpoint, and re-resolves only when the
  breakpoint or the document (by identity) changes.
- Renders a `CustomScrollView` with one `SliverStageScene` per scene. The scroll view's cache extent
  equals the lazy window.
- `StagePlayerController` exposes `timeline(id)`, `playTimeline` / `pauseTimeline` / `seekTimeline`,
  `clockValue(id)`, `nodes` (the node registry, which is also the edit overlay's geometry registry) and
  `scrollController`.

**Scene slivers** (`scenes/sliver_stage_scene.dart`):
- Pinned extent is `vh × (1 + scrollLength)`. The stage is held at the top through the pin range, and
  scrolls normally before and after it.
- Flow extent is the laid-out stage height at viewport width.
- Progress is computed in `performLayout` from `SliverConstraints` (pure functions `pinnedSceneProgress`
  and `flowSceneProgress`). It is pushed to the animator inside `invokeLayoutCallback`, so
  layout-class values for the scene's own nodes apply in the same frame.
- Laziness: the sliver is an `AbstractLayoutBuilder<bool>` whose layout info is "inside the lazy
  window". It builds its stage only while the scene is within `lazyWindow` viewports of the visible
  range, so the only widget builds during scrolling happen when a scene crosses the window boundary.
  A scene leaving the window releases its decoded images (`StageMedia.releaseAsset`) unless another
  windowed scene uses them. A scene entering prefetches them.

**Clocks** (`clocks/`):
- `StageClockSource` has `value`, `isActive`, `advance(dt)` and `sceneVisibilityChanged`. Built in:
  scene scroll, timeline (`StageTimelineSource`: play/pause/seek, `none` / `loop` / `pingPong`,
  `rate`, triggers) and pointer.
- **Plug point:** `StageClockFactories(audio:, behavior:)`. A T0.7 audio source implements
  `StageClockSource` (`value` = playback position in seconds, `isActive` = playing) and calls
  `StageAnimator.notifyClockChanged()` after seeks. Without a factory, `audio` and `behavior` clocks
  hold 0.
- `StageSmoother` is a critically damped follower, integrated in closed form.

**Compiled tracks** (`animator/compiled_track.dart`, pure Dart):
- Each resolved track becomes a `CompiledTrack`: times and components in `Float64List`s, with easing
  pre-solved per segment (`compiled_easing.dart`).
- Bezier and spring curves use the oracle's arithmetic with constants solved at compile time, so
  outputs match `ir.evaluateTrack` exactly (tested for every value type the registry animates).
- Kinds: scalar, vector, colour (OKLab), step (holds a keyframe index, so it never boxes), and boxed
  (paints, effects; these interpolate through the registry and allocate).

**Animator** (`animator/stage_animator.dart`):
- Groups tracks by clock and binds each target once, when its render object attaches to the
  `StageNodeRegistry`.
- `opacity` and `motion.*` tracks write `RenderStageBox` typed slots (`setAnimatedSlot`),
  allocation-free. On a repaint boundary this only updates its composited layers (note 32).
- Other tracks are offered to the box when it is a typed track host (below): frames and shapes
  take typed paint overrides, text takes style channels. Everything else goes through the box's
  `nodeAnimator`, which re-renders the node from its resolved base through the registry,
  invalidating paint or layout by what changed (note 43).
- One `Ticker`, running only while a timeline or audio clock is active or a smoothed clock hasn't
  settled.
- Edit mode freezes clocks at `clockOverrides`, makes pointer and behaviour clocks inert, and never
  ticks.

**Typed track hosts** (T0.7, `animator/text_style_tracks.dart`): a render object implementing
`StageTypedTrackHost` is offered every non-slot track when it binds (`bindTrack` → handle,
`trackChanged`, `unbindTrack`). `RenderStageText` takes `style.*` and
`content.<p>.spans.<s>.style.*` tracks as `TextStyleChannel`s (note 34). `RenderStageFrame` and
`RenderStageShape` (T0.6b) take the numeric and colour appearance tracks as typed paint overrides
(`StageAppearanceOverrides` in `paint/appearance_overrides.dart`, note 43): each channel holds one
track's value in a `Float64List`, written in place on `trackChanged`, and the paint seam
(`StageAppearancePainter`, `paintStageAppearance`, the outline and stroke outsets) reads it at paint
time. Both kinds of host share this one binding protocol; they differ only in what a channel
writes (span styles re-merged before text layout vs paint values read at paint). Tracks a host
declines (null handle) go through the node animator.

**Behaviour drivers** (T0.7, `animator/behavior_drivers.dart`): `TextRevealDriver` and
`LyricsDriver` follow a clock like tracks and bind to render objects through the registry. Lyrics
bring their own audio clock (`__lyrics/<frameId>`, frozen through `clockOverrides` in edit mode).
Their targets are repaint boundaries (`behaviorTargetIds`).

**Audio and the gate** (T0.7): `StagePlayer(audio:)` uses the service's clock sources for
`audio` clocks, re-reads clocks when the service seeks or starts, and reports scene visibility to
it. `StageEnterGate(document:, environment:, audio:, child:)` wraps the player.

**Animated-override layer** (`render/render_stage_box.dart`):
- `setAnimatedSlot(slot, value)` / `animatedSlot(slot)`, with `RenderStageBox.slotForPath`.
- `effectiveOpacity`, and `paintTransform` reads the slots.
- `baseNode` (resolved) vs `node` (rendered), `nodeAnimator`, `refreshAnimatedNode()`.
- Typed paint overrides: `appearanceOverrides`, `addAppearanceOverride` /
  `removeAppearanceOverride` / `clearAppearanceOverrides`, `appearanceOverrideChanged`.
- `inBlendGroup` (note 44) and `updateCompositedLayer` (note 32).
- Debug counters: `debugLayoutCount` / `debugPaintCount` (static) and `debugNodePaintCount` (per
  node: how often it recorded its content).

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

**Paint (T0.5)**

18. **Gradient handles (DN).** `start` is the centre/origin, `end - start` the first axis and
    `width - start` the second. An unset `width` (exactly 0,0) or one collinear with start/end
    uses the perpendicular of the first axis in pixel space, so radials are circles. Angular
    sweeps clockwise from `end`.
19. **Diamond (DN).** Exact, no shader: concentric diamond rings at each stop, drawn as a
    coloured triangle mesh (`drawVertices`), so it works on CanvasKit and wasm. Colour is
    linear in the L1 norm per quadrant, which the mesh reproduces exactly.
20. **Image filters (DN).** Colour matrix in order exposure (2^e), contrast, highlights/shadows,
    saturation (Rec. 709), temperature (R/B +-20%), tint (G -20%). Highlights/shadows approximate
    Figma's tone curve as a white-point scale and black-point lift acting on all tones.
    Rotation turns clockwise; `tile` uses the asset's declared original size x `tileScale`;
    `fit` aligns by `focalPoint`; variants are picked from the on-screen image width x DPR.
21. **Strokes.** Box outlines without dashes use an exact filled band (even-odd), so per-side
    weights and gradient/diamond/image stroke paints work. Dashed, round/bevel-joined or
    non-box strokes use a native stroke (inside/outside by clipping a double-width stroke); there
    diamond paints fall back to their first stop and image paints are skipped, and per-side
    weights use the largest side.
22. **Corner smoothing.** Figma's construction with `preserveSmoothing: false` (smoothing is
    reduced when a corner lacks room, radii are distributed between neighbours). Smoothed
    corners are circular; clip content follows the smoothed path.
23. **Effects.** Blur radius = 2 sigma. Shadows follow the outline, not the painted pixels;
    knocked out under the node unless `showBehindTransparentAreas` (skipped for opaque fills).
    Non-box spread scales about the centre. Text shadows have no spread; text has no inner
    shadow or background blur.
24. **Blend and opacity.** Each paint's blend mode applies to its own draw (blends with the
    stack below, inside the node). Node blend modes isolate the node in a `saveLayer`, and
    descendants never make compositing layers inside it (note 44). Masks and video appearance
    are M3.

**Motion (T0.6)** (DN = question for DECISIONS_NEEDED)

25. **Smoothing constant (DN).** `smoothing` seconds maps to `ω = 2 / smoothing`, the convention of
    Unity's `SmoothDamp`: roughly the time to arrive (41% of a step remains after `smoothing`, 9% after
    `2·smoothing`). Settling snaps at 1e-5.
26. **Timeline triggers (DN).**
    - `sceneEnter` plays while the scene is visible and pauses when it leaves. Re-entering resumes,
      and a finished `loop: none` timeline restarts from 0.
    - `autoplay` plays from player start, off screen too.
    - `interaction` waits for `play()`.
    - A tick advances at most 0.1 s, so a stalled or hidden tab doesn't jump.
27. **Pointer clocks.**
    - Hover only (mouse). The value is −1…1 across the frame's own box: no rotation or motion, but
      including the pin and scroll offsets.
    - It returns to 0 outside the frame or when the pointer leaves the player.
    - Scrolling under a still pointer doesn't update it.
28. **Which tracks are allocation-free (DN).** (Text style tracks: see note 34.)
    - Every numeric and colour evaluator, the push of `opacity` and `motion.*`, and (T0.6b) the
      push of typed paint overrides on frames and shapes (note 43) are allocation-free. Painting
      still allocates (`Paint`s, shaders, and a copy of each overridden paint or effect), but only
      for nodes whose paint changed.
    - Layout-class properties (`width`, `height`, `autoLayout.*`, …) and everything without a typed
      path still re-render the node through the registry: one node copy per changed node per frame.
    - Measuring this in the VM's JIT: see note 46.
29. **Text style tracks.** Superseded by note 34 (T0.7): they render.
30. **Cross-scene scroll clocks.** A `sceneScroll` clock whose `sceneId` is a different scene applies
    on the next tick (one frame later), because a sliver may only mutate its own subtree during
    layout.
31. **Lazy flow extents.** A flow scene that has never been built reports its root's stored height.
    Once laid out, it keeps its measured height while unbuilt.
32. **Composited updates (T0.6b).** A repaint boundary's own layer is a `TransformLayer` holding its
    paint transform (identity without one), with an `OpacityLayer` child holding its opacity, kept
    even when opaque or transparent. `opacity` and `motion.*` changes call
    `markNeedsCompositedLayerUpdate`, and `updateCompositedLayer` updates both layers: no picture is
    re-recorded (`composited_updates_test.dart` scrolls a pinned scene and counts zero paints). A
    boundary therefore never folds its opacity into its paint colours, and records its content even
    at opacity 0.
33. Vertical, top-to-bottom scrolling only.

**Fonts, audio and text behaviours (T0.7)** (DN = question for DECISIONS_NEEDED)

34. **Animated text styles.** `style.*` and `content.<p>.spans.<s>.style.*` tracks compile to
    `TextStyleChannel`s on the text render object.
    - Precedence: a node-level channel writes the node override, so it reaches only spans (and,
      for `paragraphSpacing`/`paragraphIndent`, paragraphs) that do not set the field
      themselves. Span-level channels win.
    - Typed fields read the compiled track's output directly: `fontSize`, `fontWeight`,
      `letterSpacing`, `lineHeight`, `paragraphSpacing`, `paragraphIndent`,
      `fontVariations.<tag>`, `fills.<id>.color` and `fills.<id>.opacity`. Other fields (discrete
      ones like `textCase`, and structured ones) apply the track's `IrValue` through the
      registry, only when their value changes.
    - Invalidation comes from the descriptor: fills and decoration colour repaint (the restyled
      paragraph lays out again at the same width at paint, the box does not), everything else
      relayouts.
    - Cost: nothing when no value changed. On a change, only the affected spans re-merge, only
      their paragraphs rebuild their `TextSpan`s and painters, and unchanged spans reuse their
      mapped `TextStyle`. Measured (`test/bench/text_style_bench.dart`, VM, two channels on a
      two-paragraph heading): ~33 µs and ~91 Dart allocations per change (≈27 boxed doubles and
      15 FFI pointers inside the engine's paragraph builder; 1.7 `TextSpan`s).
    - `style.fills.<id>.*` addresses the paint with that id in each reached span's merged fills,
      so a colour track can animate the default `text` fill. The resolver accepts such tracks
      (it checks text style paths against the merged styles).
35. **TextReveal (DN).**
    - The units of every text node inside the frame (depth first) form one sequence.
      Characters are grapheme clusters; whitespace is never a unit; lines come from layout.
    - Timing: unit duration `d = max(1 − (n − 1)·stagger, stagger)`, total `T = (n − 1)·stagger
      + d`, unit `i` at `clamp((p·T − i·stagger)/d)`. A stagger too large to fit compresses
      time so the reveal still ends with the range.
    - Default look (fixed; the behaviour has no look fields): opacity 0 → 1 and a rise from 0.4
      of the unit's line height, both easeOutCubic. List markers appear with their paragraph's
      first unit. Clipping is to the unit's line box, so italic overhang at a unit edge may be
      cut while it animates.
    - Paint only: finished units draw in one clipped pass, each unit in progress in its own
      alpha layer. Strokes, shadows and gradient fills reveal the same way.
36. **Lyrics (DN).**
    - The frame's first text child is the template: its first span's style, its paragraph's
      alignment, its width and position. The stack replaces it; other children render
      normally. Line spacing is the template's paragraph spacing.
    - Each line's slot is as tall as the taller of its inactive and active renderings, so layout
      never changes with time. Lines cross-fade over 0.25 s from their start and after their end
      (the next line's start when `end` is null).
    - Scrolling: `center` puts the started line's centre at the frame's centre (the first line
      before anything starts), `top` aligns it to the stack's own top, `none` never scrolls. It
      eases (easeInOutCubic) over 0.6 s from the line's start, driven by audio time, so seeks are
      exact. Through instrumental breaks it stays on the last line.
    - Word-timed lines: the active line shows sung words in the active style and the rest in the
      active layout with the inactive fills, sweeping linearly through the current word.
    - The stack hugs its height; give the frame a fixed size and `clipContent`.
37. **Audio clock.** It advances by wall time × speed while playing. Each new player position
    report sets a drift that closes at 5/s; the clock never runs backwards; a drift over 0.25 s
    (seek, loop wrap, stall) jumps. Paused, it is the player's position.
38. **Audio scope (DN).** Nothing plays before the gate's gesture. Story `autoplay` tracks start at
    unlock. Scene `autoplay` tracks fade in while their scene is on screen (any part visible) and
    fade out and pause when it leaves; re-entering resumes. Non-autoplay tracks wait for `play()`
    (interactions, M3) and pause on leave.
39. **Fades.** `fadeIn` on every start, `fadeOut` on every pause and before the end of a track
    that does not loop. Volume is linear in time (no curve), stepped on a 32 ms timer.
40. **Enter gate.** Shows the document's title, description and cover over a dark scrim, in the
    document's default font. It starts preloading the first scene's fonts and images, the cover
    and the audio at once. Activation (tap, Enter, Space) unlocks audio inside the gesture, then
    waits for the preload (showing "Loading…"; images time out after 8 s) and fades out over
    0.6 s. Screen readers get one button, "Enter the stage: <title>".
41. **Fonts.** Weight/italic selection follows CSS (italic faces first, then the CSS weight
    order). Variable faces get `opsz` = font size automatically (Figma's and CSS's optical
    sizing). Until loaded, text uses the generic fallback; `leadingTrim` then has no metrics and
    trims nothing until the relayout after load.
42. **leadingTrim: capHeight.** Trims the first line from its top to `sCapHeight × fontSize` above
    its baseline (first non-empty span of the first visible paragraph), and the last line below
    its baseline. Without OS/2 v2+ (or a document font) there is no trim and a font diagnostic.

**Runtime hardening (T0.6b)** (DN = question for DECISIONS_NEEDED)

43. **Typed vs registry paths.** On frames and shapes (and video, which renders as a shape):
    - **Typed paint overrides:** `fills.<id>.color|opacity`, `fills.<id>.stops.<i>.color|position`,
      the same under `strokes.paints.<id>`, `strokes.weight` and `strokes.weight.<side>`,
      `effects.<id>.color|offset|blur|spread|radius`, `cornerRadius`, `cornerRadius.<corner>` and
      `cornerSmoothing`, when every keyframe has the property's type (`CompiledTrack.isTyped`).
    - **Slots:** `opacity`, `motion.*`.
    - **Registry (fallback):** everything else, including discrete properties (`visible`,
      `blendMode`, `kind`), gradient handles, image properties, whole paints/effects/stacks, layout
      properties and malformed tracks.
    - Typed overrides apply after the registry's, in track order, and address paints and effects by
      id (unique ids assumed, as the spec requires). A missing id or a field the paint kind lacks
      is ignored, like the registry. A stroke weight change relayouts only when the parent's auto
      layout has `strokesIncludedInLayout`. Equivalence with the registry and `evaluateTrack` is
      tested per path and composed (`paint_overrides_test.dart`).
    - Structural decisions depend on which overrides exist, not their values, so animating never
      changes compositing: a paint with an animated opacity counts as a painted part, a blur with
      an animated radius keeps its layer at radius 0, and drop shadows always knock out under a
      fill with overrides.
44. **Blend groups.** A node inside an ancestor that isolates a group (a non-normal blend mode, or a
    `normal` frame with a blending child) is never a repaint boundary or compositing layer
    (`inBlendGroup`), and neither is a node that blends itself. Its opacity and layer blur become
    canvas `saveLayer`s and its animated values repaint with the group. Decided at attach, when a
    node's blend changes (its subtree and its parent are updated), and when a frame adopts or drops
    a blending child. Exceptions (DN): a background blur still needs its layers, and text layer
    blur (`text_paint.dart`) still uses an `ImageFilterLayer`; both escape the group.
45. **Boundaries start at attach.** A node is not a repaint boundary until its first attach has
    decided `inBlendGroup`, because the framework assumes a node that was a boundary when
    constructed already has a layer.
46. **Allocation measurement (DN).** `animator_alloc_bench.dart` counts VM allocations. In the JIT,
    a `double` that crosses a call the JIT did not inline is boxed, so the result depends on
    inlining: hot double helpers carry `@pragma('vm:prefer-inline')`, slot values pass as a
    `Float64List` index, and the sRGB encode is local. Evaluators and slot pushes measure 0. The
    mixed bench (frames and shapes together) measures 0 in some runs and up to about 2.4 boxed
    doubles per frame in others; each kind alone is 0. AOT and the web compile doubles unboxed
    through these calls.

**T0.8 polish and the wheel experiment**

47. **Lyric style interpolation.** A lyric line in transition (`0 < mix < 1`, over `kLyricsFade`)
    is painted once, in `lerpLyricStyle(inactive, active, mix)`: weight (so the variable `wght`
    axis, via `stageTextStyle`), size, letter spacing (as px) and fills interpolate; every other
    field follows the nearer end. No two renderings overlap, so nothing ghosts. Only lines in
    transition (at most two) relayout, each frame, into one reused painter; word-timed lines
    paint an interpolated "unsung" layout under the clipped sung words. Slots stay as tall as the
    taller end style, so a transition never moves another line. On a non-variable family the face
    snaps at the weight midpoint.
48. **Lyric edge fade.** The stack is painted into a `saveLayer` the size of the frame, then a
    vertical gradient is drawn over it with `BlendMode.dstIn` (`kLyricsEdgeFade` = 20% of the
    frame height per edge; `top` scroll mode fades the bottom edge only). One extra layer per
    lyrics frame while visible.
49. **Gate cover crop.** `gateCoverPlacement` draws the cover so its focal point (the moon) lands
    in the upper `kGateFocalArea` (42%) of the viewport, centred on narrow screens, zooming up to
    1.6x when the plain crop cannot move it; the title block is bottom-aligned below it and
    drops the description on short viewports. `StageEnterGate.buildChildOnEnter` mounts the player
    when the gate starts fading, so entry animations (a timeline on scene enter) play in view.
50. **Mouse-wheel smoothing (opt-in, `StagePlayer.wheelSmoothing`).** `StageScrollController`
    creates `StageScrollPosition`, which overrides `ScrollPosition.pointerScroll(delta)`: the
    hook `Scrollable` calls (after registering the `PointerScrollEvent` with
    `GestureBinding.pointerSignalResolver` and flipping axes for modifier keys). Keyboard
    (`ScrollAction` → `animateTo`), touch drags, scrollbar drags and `jumpTo` never reach it, and
    any of them cancels a smoothed scroll (`beginActivity`). A *notch* moves a target offset
    (accumulating, clamped to the extent) and the position follows it with `StageSmoother`
    (critically damped, `smoothing` 0.06 s: 9% of a notch left after 120 ms, 2% after ~180 ms,
    exact integration, frame-rate independent) through `forcePixels`, with the same scroll
    notifications as a native wheel scroll. **Telling a wheel from a trackpad** (`WheelClassifier`):
    Flutter web turns every DOM `wheel` event into a `PointerScrollEvent` with `kind: mouse` and
    CSS-pixel `scrollDelta`, with no `deltaMode`, `wheelDelta` or device flag, so only delta and
    timing remain. Precise: `|delta| < 40`; non-integer delta; within 150 ms of a precise event
    (a flick's big first delta, then its dense momentum); in a dense stream (< 20 ms apart)
    unless the size repeats the previous notch. Otherwise a notch. **Failure modes:** a hard
    trackpad flick's first event (integer, >= 40, after a pause) is taken as a notch and eased for
    ~150 ms; mice with acceleration curves or small per-notch deltas (some Mac mice, Logitech
    "smooth scrolling" and "SmartShift" free-spin) look like a trackpad and stay native; a
    free-spinning wheel with varying deltas turns native after its first notches; Linux/Firefox
    notches of 53/48 px pass the threshold, 3-line notches of 40 px on some setups sit on it.
    Pinned scenes already smooth through their clocks, so a smoothed notch adds its ~120 ms on
    top of the clock's. The demos turn it on, `?wheel=native` turns it off.
