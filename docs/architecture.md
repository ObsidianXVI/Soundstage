# Soundstage — Architecture

Status: v1 blueprint, 22/10/26. This is the contract that the IR, runtime and editor are built
against. Changes to it are recorded in `DECISIONS.md`.

## 1. Principles

1. **One document model, two consumers.** A story is a `StageDocument` (the Stage IR). The
   runtime (`StagePlayer`) renders it; the editor edits it. Neither holds story state outside it.
2. **The editor is the player in edit mode.** The canvas renders with the same render objects
   readers get. What you see while editing is exactly what ships.
3. **Figma-grade primitives, our own implementation.** Layout, media sizing and typography follow
   Figma's semantics precisely (§4–§7), because those semantics are well understood and expressive.
   Soundstage then adds what Figma lacks: scroll/time/audio clocks, keyframed motion, behaviours.
4. **Everything animatable is a property bound to a clock.** Scroll progress, time, audio position
   and pointer/gesture input are all clocks. Tracks map a clock to a property via keyframes.
5. **One property addressing scheme everywhere.** Breakpoint overrides, component-instance
   overrides, token bindings, keyframe tracks and the inspector all address properties by the same
   `PropertyPath` through one `PropertyRegistry` (§11).
6. **Render objects, not widget rebuilds, for motion.** Per-frame animation writes directly into
   render objects. Scrolling a story never rebuilds widgets.

## 2. System overview

```
                 ┌──────────── lib/ir (pure Dart) ────────────┐
 .stage.json ──▶ │ migrate → StageDocument (freezed)           │
                 │ PropertyRegistry · Patches · Interpolators  │
                 │ Resolver → ResolvedTree                     │
                 └───────────────┬─────────────────────────────┘
                                 │
        ┌────────────────────────┴───────────────────────┐
        ▼                                                ▼
 lib/runtime  StagePlayer                         lib/editor
  scene slivers · clocks · animator               EditorController (Riverpod)
  RenderStageFrame/Text/Shape · media · fonts     commands + history (undo)
  (play mode / edit mode)                         canvas = StagePlayer(edit) + overlay
                                                  panels · inspector · timeline
```

## 3. The document

```
StageDocument
  schemaVersion: int                    // 1 at launch; see §13
  id, meta { title, slug, author, description, coverAssetId, language }
  breakpoints: [Breakpoint]             // §3.1
  baseBreakpointId
  tokens: TokenSystem                   // §8
  assets: { id: Asset }                 // §12
  fonts:  { id: FontFamily }            // §12
  components: { id: ComponentDef }      // §9
  variantSets: { id: VariantSet }       // §9
  scenes: [Scene]                       // §3.2, in reading order
  audioTracks: [AudioTrack]             // §10.5
  overlay: FrameNode?                   // persistent chrome over all scenes (progress bar, player)
```

IDs are short random base62 strings, unique within a document. All geometry is logical pixels.
Angles are degrees. Colours are `StageColor { r, g, b, a }` doubles in 0–1, sRGB.

### 3.1 Breakpoints and overrides

`Breakpoint { id, name, minWidth, designSize: {w, h} }`. The active breakpoint is the one with the
largest `minWidth` ≤ viewport width. `designSize` is the reference viewport the author designs that
breakpoint at (e.g. desktop 1440×900, mobile 390×844); it is the reference size for constraints on
a scene's stage root (§4.3).

Every node carries `breakpointOverrides: { breakpointId: Patch }`. **Cascade model (provisional,
see DECISIONS.md):** the base breakpoint holds the node's own values. A breakpoint resolves by
applying, in order, the patches of every breakpoint between the base and itself — so with
base = desktop, `tablet` inherits desktop, and `mobile` inherits desktop + tablet. Breakpoints
larger than the base cascade upward the same way.

A **Patch** is `{ PropertyPath: IrValue }` (§11). Patches are also used for instance overrides.

### 3.2 Scenes

```
Scene
  id, name
  kind: pinned | flow
  scrollLength: double        // pinned only: scroll distance while pinned, in viewport heights
  root: FrameNode             // the stage
  tracks: [Track]             // §10
  clocks: [Clock]             // §10.1, every clock this scene's tracks use (all kinds)
  background: [Paint]
  modeOverrides: { collectionId: modeId }
  transitionIn: { kind: none | overlap | crossfade, amount }   // M3
```

- **pinned**: the stage root is sized to the viewport. The scene's scroll extent is
  `viewportHeight × (1 + scrollLength)`. While the reader scrolls through `scrollLength`, the stage
  stays fixed on screen and the scene's scroll clock runs 0 → 1. Then it scrolls away normally.
- **flow**: the stage root is laid out at viewport width with its own vertical sizing (usually
  hug) and scrolls like a normal page section. Its scroll clock is 0 when the scene's top enters
  the bottom of the viewport and 1 when its bottom leaves the top.

## 4. Nodes and layout

### 4.1 Node kinds

`Node` is a sealed union:

| Kind | Purpose |
|---|---|
| `FrameNode` | Container. Free (absolute children) or auto-layout (§4.4) or grid (§4.5). Has fills, strokes, effects, corners, clip. Also the "image layer": a frame with an `ImagePaint` fill. |
| `TextNode` | Rich text (§7). Also takes strokes and effects (text shadows, outlines). |
| `ShapeNode` | `rectangle`, `ellipse` (with arc start/end/inner radius), `line`, `polygon` (point count), `star` (point count, inner ratio). Fills/strokes/effects. Vector paths are out of scope. |
| `InstanceNode` | An instance of a component or variant (§9). |
| `VideoNode` | Video with the same scale modes as images (§6). Also takes corners, strokes and effects. |
| `EmbedNode` | Rive or Lottie asset with state-machine inputs bindable to clocks (M3). |

### 4.2 Common properties (every node)

```
id, name, visible, locked (editor only), opacity, blendMode (incl. passThrough for frames)
x, y, width, height           // design-time geometry, relative to parent, at the parent's
                              // reference size (§4.3)
rotation                      // geometric rotation; auto-layout measures the rotated bounds (Figma)
flipX, flipY
motion: { translateX, translateY, scaleX, scaleY, rotate, skewX, skewY, originX, originY }
                              // paint-only transform, like CSS `transform`; never affects layout.
                              // This is what scroll animations should normally drive.
layoutChild: {                // how this node behaves inside its parent
  positioning: auto | absolute         // absolute = "ignore auto layout" in an auto-layout parent
  horizontalSizing: fixed | hug | fill
  verticalSizing:   fixed | hug | fill
  minWidth, maxWidth, minHeight, maxHeight  (nullable)
  constraints: { horizontal: left|right|leftRight|center|scale,
                 vertical:   top|bottom|topBottom|center|scale }   // used when absolute
  grid: { column, row, columnSpan, rowSpan, alignX, alignY }       // used in a grid parent
}
fills, strokes, effects, cornerRadius   // on frames and shapes (text: strokes + effects;
                                        // video: corners + strokes + effects)
fillStyleId, strokeStyleId, effectStyleId // style refs (§8); the style's stack replaces the local one
mask: none | alpha | luminance          // M3: masks the siblings above it in the same parent
breakpointOverrides: { bpId: Patch }
bindings: { PropertyPath: TokenRef }    // token-bound properties (§8)
```

### 4.3 Absolute positioning and constraints

Children of a free frame, and `absolute` children of an auto-layout frame, are placed by
constraints against the **parent's frame box** (not its padding box). Stored geometry
`(x, y, w, h)` is design-time geometry relative to the parent's **reference size** `R`: the
parent's own stored `width/height` (for a scene root: the active breakpoint's `designSize`). At
layout the parent's actual size is `P`. Horizontally (vertical is symmetric):

| Constraint | Result |
|---|---|
| `left` | `x' = x`, `w' = w` |
| `right` | right margin `R.w − x − w` kept; `w' = w` |
| `leftRight` | both margins kept; `w' = P.w − x − (R.w − x − w)` |
| `center` | offset of the child's centre from the parent's centre kept; `w' = w` |
| `scale` | `x' = x·P.w/R.w`, `w' = w·P.w/R.w` |

Then min/max clamp `w'`. Hug/fill sizing does not apply to absolute children except that a
hug-sized frame or auto-width text measures its own content.

### 4.4 Auto layout

```
autoLayout: {
  direction: horizontal | vertical
  wrap: bool                           // horizontal only
  gap: double | auto                   // auto = space-between; negative gaps allowed (overlap)
  counterAxisGap: double | auto        // between wrapped rows
  padding: { top, right, bottom, left }
  primaryAlign: start | center | end
  counterAlign: start | center | end | baseline   // baseline: horizontal only
  rowAlign: start | center | end                  // wrapped rows as a block
  primarySizing: fixed | hug
  counterSizing: fixed | hug
  strokesIncludedInLayout: bool
  reverseZIndex: bool                  // first child paints on top
}
```

Algorithm (horizontal; vertical is the transpose):

1. Content box = frame size − padding. Hidden and `absolute` children are skipped for flow.
2. Measure in-flow children on the primary axis: `fixed` → its width; `hug` → its content size
   (a frame's own hug result, text per its auto-resize mode); `fill` → deferred. Use the rotated
   bounding box when `rotation ≠ 0`. If `strokesIncludedInLayout`, inflate by the outside portion
   of the child's strokes.
3. Counter axis per child: `fixed`/`hug` as above; `fill` = content box height. Clamp min/max.
4. If `primarySizing = hug`: frame width = Σ non-fill widths + gaps + padding, and `fill`
   children behave as `hug`. Clamp the frame by its own min/max.
5. Free space = content width − Σ non-fill − gap × (n − 1). Split free space **equally** among
   `fill` children, freezing any that hit min/max and redistributing (CSS flex freeze loop).
6. `gap = auto`: gap = free space / (n − 1); with n = 1 the child sits at `start`.
7. Offset the run by `primaryAlign`. Place each child on the counter axis by `counterAlign`.
   `baseline` aligns first baselines; a frame's first baseline is that of its first text
   descendant in flow order, else its bottom edge.
8. `wrap`: break into rows where the next child's width (min width for `fill`) would exceed the
   content width. Lay each row out by steps 5–7. Stack rows with `counterAxisGap` and position the
   block by `rowAlign`. `counterSizing = hug` sums row heights.
9. Absolute children are then placed per §4.3. Clip if `clipContent`.
10. Paint order is child order (later on top) unless `reverseZIndex`.

### 4.5 Grid layout (runtime: M3; in the IR from v1)

`grid: { columns: [Track], rows: [Track], columnGap, rowGap, padding, autoFlow: row | column }`
where `Track = fixed(px) | flex(fr) | hug`. Children are placed by `layoutChild.grid` (auto-placed
when `column/row` are null) and aligned within their cell by `alignX/alignY`
(`start | center | end | stretch`).

## 5. Paints, strokes, effects, corners

**Paints** (stack, bottom → top; each has `id`, `visible`, `opacity`, `blendMode`):
- `SolidPaint { color }`
- `GradientPaint { kind: linear | radial | angular | diamond, stops: [{ position, color }],
  handles: { start, end, width } }` — handles are in normalised node coordinates (0–1), as in
  Figma, so gradients scale with the node.
- `ImagePaint` — §6.

**Strokes:** `{ paints, weight | { top, right, bottom, left }, align: inside | center | outside,
cap, join, miterLimit, dash: [double] }`.

**Effects** (each `visible`, `id`): `DropShadow { color, offset, blur, spread, blendMode,
showBehindTransparentAreas }`, `InnerShadow { color, offset, blur, spread, blendMode }`,
`LayerBlur { radius }`, `BackgroundBlur { radius }`.

**Corners:** `cornerRadius: double | { tl, tr, br, bl }`, `cornerSmoothing: 0–1` (Figma's squircle;
implement Figma's published smoothing construction, not `ContinuousRectangleBorder`, which is a
different curve).

**Blend modes:** normal, passThrough (frames), darken, multiply, colorBurn, lighten, screen,
colorDodge, overlay, softLight, hardLight, difference, exclusion, hue, saturation, color,
luminosity — all map to Flutter `BlendMode`.

## 6. Media sizing

`ImagePaint { assetId, scaleMode, focalPoint {x, y}, cropRect, tileScale, rotation (0|90|180|270),
filters { exposure, contrast, saturation, temperature, tint, highlights, shadows } }`

| scaleMode | Behaviour |
|---|---|
| `fill` | Scale to cover the node; crop the overflow. The crop is positioned so `focalPoint` (normalised in the image, default 0.5/0.5) stays as close to the node centre as the bounds allow. `focalPoint` is a Soundstage addition: it is what keeps the subject in frame as breakpoints change the aspect ratio. |
| `fit` | Scale to fit entirely inside; letterbox, aligned by `focalPoint`. |
| `crop` | `cropRect` (normalised in the image) is mapped exactly onto the node; stretches if aspects differ, exactly like Figma's crop. |
| `tile` | Repeat at intrinsic size × `tileScale`. |

Filters are applied as a colour matrix (exposure, contrast, saturation, temperature, tint) and a
tone curve (highlights, shadows). The runtime picks the smallest asset variant whose width ≥
rendered width × devicePixelRatio. `VideoNode` uses the same `scaleMode` + `focalPoint` semantics
(implemented with CSS `object-fit`/`object-position` on the platform view).

## 7. Text

```
TextNode
  content: [Paragraph]
    Paragraph { spans: [Span], style: ParagraphStyle? }
    Span { text, style: TextStyleOverride, link? }
  textStyleId?                       // named style (§8); span/paragraph overrides win
  style: TextStyle                   // node-level base
  autoResize: widthAndHeight | height | fixed | truncate
  maxLines?, truncation: none | ending
  alignHorizontal: left | center | right | justified
  alignVertical: top | middle | bottom
  leadingTrim: none | capHeight      // best effort; needs font metrics (see DECISIONS_NEEDED)

TextStyle
  fontFamilyId, fontWeight (1–1000), italic, fontVariations { axisTag: value }
  fontSize
  lineHeight: auto | px(v) | percent(v)
  letterSpacing: px(v) | percent(v)          // percent of fontSize
  paragraphSpacing, paragraphIndent
  textCase: none | upper | lower | title | smallCaps | smallCapsForced
  decoration: { kind: none | underline | strikethrough, style: solid|double|dotted|dashed|wavy,
                thickness, color, skipInk }
  fills: [Paint]                              // text can take gradient and image fills
  openType: { tag: on/off/int }               // liga, tnum, ss01, …
  baselineShift: none | superscript | subscript
  listStyle: none | ordered | unordered       // paragraph level
```

Mapping to Flutter: `lineHeight.percent` → `height = v/100`; `px` → `height = v/fontSize`;
`auto` → `height = null`. Always `leadingDistribution: even` (Figma centres glyphs in the line
box). `letterSpacing.percent` → `fontSize × v/100`. `textCase` is applied to the text before layout
(`smallCaps` via the `smcp` OpenType feature). Multi-fill text paints the glyph mask once and
composites the paint stack onto it with `srcIn`. Auto-resize: `widthAndHeight` hugs both axes
without wrapping; `height` wraps at fixed width and hugs height; `fixed` is fixed in both;
`truncate` is fixed with ellipsis at `maxLines` or the box height.

## 8. Tokens

Follows Figma variables, extended for breakpoints:

```
TokenSystem
  collections: [VariableCollection { id, name, modes: [{id, name}], defaultModeId,
                                     breakpointModes: { bpId: modeId }?,   // responsive tokens
                                     variables: [Variable] }]
  Variable { id, name /* "color/brand/primary" */, type: color|number|string|boolean|fontFamily,
             valuesByMode: { modeId: IrValue | alias(variableId) } }
  textStyles:   { id: TextStyleDef { name, style: TextStyle } }     // fields may be token-bound
  paintStyles:  { id: PaintStyleDef { name, paints } }
  effectStyles: { id: EffectStyleDef { name, effects } }
```

Active mode per collection, lowest priority first: collection default → `breakpointModes` for the
active breakpoint → scene `modeOverrides` → frame `modeOverrides` (inherited by descendants) →
interaction state (M3). Boolean/number/string variables double as interaction state.

## 9. Components

```
ComponentDef { id, name, description, root: FrameNode,
               properties: { propId: ComponentPropDef { name,
                             type: text | boolean | number | asset | instanceSwap | variant,
                             default } } }
  // nodes inside root bind to props via `componentBindings: { PropertyPath: propId }`
VariantSet { id, name, axes: { axis: [values] }, variants: [{ values: {axis: value}, componentId }] }
InstanceNode { componentId | (variantSetId + variantValues), propValues: { propId: IrValue },
               overrides: { innerNodePath: Patch } }      // innerNodePath = ids joined by "/"
```

Instances are expanded during resolution (§11.3). Resolved inner ids are namespaced
`<instanceId>/<innerId>` so tracks and the editor can address them. Editing the main component
updates every instance; overrides survive by path. Detach converts an instance into plain nodes.

**Behaviours** add interactivity without hiding layout. A frame may carry
`behavior: Behavior?` (sealed): `Carousel { axis, snap, loop, autoplay, peek, physics }`,
`Lightbox`, `Marquee { speed, direction }`, `TextReveal { unit: char|word|line, stagger,
clockId, range }`, `Lyrics { audioTrackId, activeStyle, inactiveStyle, scrollMode }`,
`AudioControls { audioTrackId }`. The frame's children stay ordinary, fully styleable nodes. A
behaviour may expose clocks (e.g. a carousel's index clock) for other tracks to use.
Prebuilt "components" (gallery, carousel, tiles) ship as starter `ComponentDef`s that use these
behaviours.

## 10. Motion

### 10.1 Clocks

| Clock | Value | Source |
|---|---|---|
| `sceneScroll(sceneId)` | 0–1 | §3.2 |
| `timeline(id)` | seconds | `TimelineClock { duration, loop: none\|loop\|pingPong, rate, trigger: sceneEnter\|interaction\|autoplay }` |
| `audio(trackId)` | seconds | audio playback position |
| `pointer(frameId, axis)` | −1…1 | pointer position over a frame (hover parallax) |
| `behavior(nodeId, name)` | behaviour-defined | e.g. carousel index |

Clocks are declared in `Scene.clocks`, each with an `id` (referenced by `Track.clockId`,
behaviours and interactions). A pointer clock has one `axis` (`x` or `y`). Every clock may set `smoothing` (seconds): the evaluated value follows the raw value with a
critically damped spring. Scroll smoothing is what makes mouse-wheel scrolling feel continuous on
the web.

### 10.2 Tracks and keyframes

```
Track { id, target: nodePath, property: PropertyPath, clockId,
        keyframes: [Keyframe { id, t, value: IrValue, easing }],   // easing applies t_i → t_{i+1}
        breakpoints: [bpId]? }                                      // null = all breakpoints
```

Before the first keyframe the value holds the first keyframe's value. After the last it holds the
last. Keyframe values may be token refs, resolved in §11.4.

**Easing:** `linear`, `cubicBezier(x1, y1, x2, y2)`, named presets (`easeIn`, `easeOut`,
`easeInOut`, …), `spring { mass, stiffness, damping }` (the analytic step response, normalised to
the segment), `steps(n, jumpStart | jumpEnd)`, `hold`.

**Interpolation** comes from the property's type in the registry: numbers lerp, colours lerp in
OKLab, paints lerp stop-wise when their structure matches (otherwise they hold), shadows and blurs
lerp field-wise, everything else (enum, bool, string, asset id) steps at the keyframe.

**Motion presets** (fade, rise, scale-in, blur-in, …) are editor macros that write ordinary tracks.

### 10.3 Interactions (M3)

`Interaction { trigger: tap | hoverEnter | hoverLeave | sceneEnter | sceneLeave | audioCue(t) |
clockReach(clockId, value), actions: [Action] }` on any node. Actions: play/pause/seek/reverse
timeline, play/pause/seek audio, set variable, scroll to scene, open URL, open lightbox.

### 10.4 Audio and lyrics

`AudioTrack { id, assetId, scope: story | scene(sceneId), autoplay, loop, volume,
fadeIn, fadeOut, lyrics: LyricsDoc? }`. `LyricsDoc { lines: [{ start, end?, text,
words: [{ start, end?, text }]? }] }`, imported from LRC (line times) and enhanced LRC (word times).
Browsers block autoplay with sound, so the player opens with an "enter the stage" gesture that
unlocks audio for the session.

## 11. Property registry and resolution

### 11.1 PropertyPath and IrValue

`PropertyPath` is a dotted string: `opacity`, `motion.translateY`, `autoLayout.gap`,
`fills.<paintId>.color`, `effects.<effectId>.blur`, `style.fontSize`,
`content.<paragraphIndex>.spans.<spanIndex>.style.fontWeight`. Paints and effects are addressed by
id, never by index, so reordering the stack does not retarget tracks.

`IrValue` is a sealed, JSON-serialisable union: `number`, `color`, `bool`, `string`, `enum`,
`size`, `point`, `paints`, `effects`, `lineHeight`, `letterSpacing`, `tokenRef`, …

### 11.2 PropertyRegistry

One `PropertyDescriptor` per property: `{ pathPattern, valueType, default, appliesTo: {node kinds},
animatable, invalidation: paint | layout | compositing, interpolator, get(node), set(node, value) }`.
Patch application, overrides, track targets, token bindings and inspector controls all go through
the registry. Adding a property means adding one descriptor (plus the runtime hook that reads it).

### 11.3 Resolution pipeline

```
1. JSON → migrate (schemaVersion) → StageDocument
2. Instance expansion   InstanceNode → component/variant tree + prop bindings + overrides
3. Breakpoint           apply cascaded breakpoint patches for the active breakpoint (§3.1)
4. Modes                active mode per collection per frame scope (§8)
5. Tokens and styles    replace token refs and style refs with concrete values;
                        local values override style values
   ⇒ ResolvedTree (immutable, concrete values only) — cached; rebuilt on document edit,
     breakpoint change or mode change
6. Animation (per frame) evaluate each track whose clock changed; the animated value overrides
                        the resolved value for that property
7. Layout and paint     render objects
```

## 12. Assets and fonts

`Asset { id, kind: image | video | audio | font | imageSequence | lottie | rive, name, uri, mime,
byteSize, width?, height?, duration?, frameCount?, variants: [{ width, uri, format }],
placeholder { dominantColor, blurhash? }, alt, credit }`. `imageSequence` (M3) is a numbered frame
set driven by a clock — the reliable way to scrub "video" with scroll on the web.

`FontFamily { id, name, faces: [{ assetId, weight, italic, variable, axes: [{ tag, min, max,
default }] }], fallback: serif | sans | mono }`. The runtime loads font bytes with Flutter's
`FontLoader` before first layout. Text renders in the fallback until then and relays out on load.
The player holds the "enter" gate until the first scene's fonts are loaded.

Asset URIs: `local://<id>` (IndexedDB in the editor, M1), `https://…` (published, M4), and
`asset://<path>` (bundled demo content).

## 13. Serialisation and versioning

The file format is JSON (`.stage.json`). `schemaVersion` is an int. `lib/ir/migrations/` holds one
pure `Map → Map` function per version step; loading runs every step from the file's version to the
current one. Every freezed model round-trips through JSON losslessly (tested).

## 14. Runtime (`StagePlayer`)

- `StagePlayer(document, mode: play | edit, viewportOverride?, initialSceneId?)`.
- A `CustomScrollView` with one `SliverStageScene` per scene. `RenderSliverStageScene` reports
  `viewportHeight × (1 + scrollLength)` extent for pinned scenes. It paints its stage box at a fixed
  viewport offset while inside its pin range and publishes the scene-scroll clock. Flow scenes report
  their content height.
- Resolved nodes map to `RenderStageFrame`, `RenderStageText`, `RenderStageShape` (custom
  `RenderBox`es with `StageParentData`). Auto layout, constraints and grid are implemented in these
  render objects, **not** with `Row`/`Column`/`Stack`, whose semantics differ.
- **Animator.** One `Ticker` per player. Each frame it reads clock sources, applies smoothing,
  evaluates the tracks whose clock changed, and writes values into render objects through a
  `nodeId → RenderObject` registry. Paint-class properties (opacity, motion, colours, blur) call
  `markNeedsPaint` on a repaint boundary. Layout-class properties call `markNeedsLayout`. Animated
  nodes are repaint boundaries. No `setState` during playback.
- **Edit mode** freezes clocks at the editor's playhead. It exposes a `NodeGeometryRegistry`
  (`nodeId → RenderBox`) for the overlay and disables behaviours' gesture handling.
- Media: images decode to `ui.Image` and paint through the scale-mode painter. Audio uses
  `just_audio` (web supported). Video uses an HTML `<video>` platform view (M3) — platform views are
  costly on the web, so a scene supports at most two live video nodes.
- Build target: `flutter build web --wasm` where every dependency supports it (to verify in M0);
  otherwise CanvasKit.

## 15. Editor

- **State.** `EditorController` (Riverpod `Notifier`) over a freezed `EditorState`: document,
  selection, hover, active scene, active breakpoint, tool, camera (zoom/pan), playhead per scene,
  auto-key flag, panel layout. `History` keeps document snapshots (structural sharing keeps them
  cheap), coalesces continuous gestures into one entry, and caps at 200 entries.
- **Commands.** Every mutation is a named `EditCommand` (a pure `doc → doc` function plus an undo
  label): `SetProperty`, `InsertNodes`, `DeleteNodes`, `MoveNodes` (reparent/reorder),
  `WrapInFrame`, `AddAutoLayout`, `CreateComponent`, `DetachInstance`, `AddKeyframe`, …
- **`SetProperty` routing** makes the inspector work in every context. When the user changes a
  property:
  - if auto-key is on and the property is animatable, write a keyframe at the playhead;
  - else if inside an instance, write an instance override;
  - else if the active breakpoint is not the base, write a breakpoint patch;
  - else write the base value.

  The inspector shows which layer a value comes from (base / breakpoint / override / animated /
  token) and offers reset.
- **Canvas.** The active scene renders as an artboard at the active breakpoint's viewport size,
  frozen at the playhead, inside a custom camera (zoom/pan). The width can be dragged freely to test
  responsiveness between breakpoints. Preview mode is the real scrolling player.
- **Overlay** (above the canvas): hover outlines, selection bounds, resize/rotate handles,
  auto-layout padding/gap handles, snapping and smart-spacing guides, distance measurement
  (hold Alt), insertion indicators for reordering inside auto layout.
- **Selection rules** follow Figma: click selects the topmost child of the current context,
  double-click enters a frame or edits text, Cmd/Ctrl-click deep-selects, Shift adds, marquee
  selects.
- **Panels.** Layers (tree, reorder, rename, visibility, lock), Assets (upload, fonts), Components,
  Tokens (collections/modes/variables, styles), Inspector (registry-driven sections: Frame,
  Position & Constraints, Auto layout, Layout child, Appearance, Fill, Stroke, Effects, Text,
  Behaviour, Motion), Timeline (§15.1).
- **Controls.** Number fields scrub on drag, accept units and arithmetic, and show "Mixed" for
  multi-selection. Colour picker with token binding. Paint-stack and effect-list editors. Figma-style
  alignment matrix. Constraints widget.

### 15.1 Timeline

Per scene: lanes grouped by node, one per animated property; a playhead bound to the selected
clock (scene scroll by default, or a timeline/audio clock); keyframe diamonds you drag, box-select,
copy and paste; an easing editor (bezier handles and spring parameters with a live curve);
auto-key (stopwatch); an audio lane with waveform peaks precomputed on upload; and a lyrics lane
of draggable line/word blocks. Scrubbing updates the canvas live.

## 16. Persistence and publishing

- **M1 (local):** autosave to IndexedDB (document JSON + asset blobs under `local://` ids); import
  and export `.stage.json` (+ a zip bundle with assets).
- **M4 (hosted):** Firebase Auth; story metadata in Firestore; document JSON and assets in Cloud
  Storage (documents can exceed Firestore's 1 MiB limit); responsive image variants generated in the
  browser before upload. Publish freezes a version as `published/<slug>/v<n>.stage.json` plus a
  pointer. Player route `/s/<slug>`. A static HTML snapshot per published story (meta/OG tags and
  the story's text) for search engines and link previews.

## 17. Performance, reliability, scalability

These are requirements, not aspirations. Each one has a test or a measured budget (§18).

### 17.1 Performance

- **The IR is a boundary, not a hot path.** Nothing per-frame touches `IrValue`, `PropertyPath`
  strings or the registry. At resolve time the runtime **compiles** each track into a typed
  evaluator (keyframe times and values in `Float64List`s, pre-solved easing, a direct setter on the
  target render object). The per-frame loop allocates nothing.
- **Clock-indexed evaluation.** Tracks are grouped by clock. A frame evaluates only the groups
  whose clock value changed. A scene that is not on screen evaluates nothing.
- **Identity, not equality.** freezed's `==` is a deep comparison, O(tree). Hot paths (resolver
  caches, render-object updates, editor diffing) compare with `identical()`. Edits copy only the
  path from the root to the changed node (structural sharing), so unchanged subtrees keep their
  identity.
- **Incremental resolution.** The resolver memoises per node, keyed by the identity of the node's
  inputs (node, applicable patches, active modes, referenced component and tokens). A
  single-property edit re-resolves only the path to that node. Token or component edits
  invalidate only their dependents (a reverse-dependency index). M0 may resolve whole documents,
  but the API must not preclude this.
- **Lazy scenes.** Only scenes within ±1 viewport of the reading position have render trees.
  Media decodes ahead of need (the next scene) and is released behind it. A size-bounded LRU
  holds decoded images.
- **Cheap compositing.** Animated nodes are repaint boundaries. `saveLayer` is used only where
  semantics require it (group opacity over overlapping children, non-normal blend modes, layer and
  background blur, masks), never by default.
- **Right-sized media.** Image variants are picked by rendered width × DPR. Placeholders (dominant
  colour or blurhash) paint immediately. Modern formats are used where the browser decodes them.

### 17.2 Reliability

- **Documents never fail to open.** Loading runs migrations, then a validator that checks
  referential integrity (ids, component/asset/token/clock references, unique ids). Problems become
  diagnostics. The resolver never throws: a missing reference renders as a visible placeholder in
  the editor and is skipped in the player.
- **Render faults are contained.** A node that fails to lay out or paint renders an error box (in
  the editor) or nothing (in the player). It never takes down the scene or the story.
- **Determinism.** The same document, viewport and clock values always produce the same frame.
  Golden tests rely on this.
- **No lost work.** Autosave is debounced and crash-safe: write a new revision, then move the
  pointer. Keep a revision history. Undo history survives a reload in the same session.
- **Immutable publishing.** A published version is frozen. The player supports every
  `schemaVersion` up to its own through migrations, so old stories keep playing after runtime
  updates.
- **Fuzzed boundaries.** Property-based tests generate random documents and patches for JSON
  round-trip, migration, validation and resolution (no throws, deterministic output).

### 17.3 Scalability

- **Readers cost nothing server-side.** A published story is static JSON plus assets on a CDN,
  played by a static web app. Reader load scales with the CDN, not with any server we run.
- **Long stories.** Published documents are split per scene (a small manifest plus scene chunks
  and a shared library chunk for tokens, components, fonts and the asset table). The player
  fetches scene chunks as the reader approaches them. The editor loads the whole document.
- **Large documents in the editor.** Target: a 5,000-node story stays interactive. That relies on
  incremental resolution, virtualised panels (layers and timeline lists build lazily), and a
  canvas that only builds the active scene.
- **Authors later.** Story metadata in Firestore and documents and assets in Storage, partitioned
  by `authorId` from day one, so multi-author is a permissions change rather than a data
  migration.

## 18. Testing and budgets

- `ir`: JSON round-trip for every model, migrations, registry get/set for every descriptor, patch
  cascade, interpolators, easing curves, resolver (instances, breakpoints, modes, tokens).
- `runtime`: a layout test table that asserts child rects for every auto-layout/constraint case in
  §4; text mapping tests (§7); scale-mode geometry tests (§6); widget tests that render demo
  documents at 390 and 1440 wide without overflow; animator tests that verify no widget rebuilds
  during playback.
- `editor`: command and undo/redo tests, `SetProperty` routing tests, panel widget tests.
- Visual and feel checks through the `chrome-devtools` MCP. Performance traces of pinned-scene
  scrolling.
- **Budgets** (benchmarks under `test/bench/`, run in Chrome, checked at each milestone):

  | Budget | Target |
  |---|---|
  | Scroll an animated pinned scene, desktop Chrome | 60 fps, no frame > 16 ms |
  | Animator work per frame, 200 active tracks | < 2 ms, zero allocations |
  | Widget rebuilds during scroll playback | 0 |
  | Full resolve, 2,000-node document | < 16 ms |
  | Re-resolve after a single-property edit | < 2 ms |
  | Editor drag on a 5,000-node document | 60 fps |
  | Load and first paint of the first scene (published, fast 4G) | < 2.5 s |
