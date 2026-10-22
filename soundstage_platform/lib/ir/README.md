# Stage IR

The story document model (`docs/architecture.md` §3–§13). Pure Dart: nothing here imports
Flutter (enforced by `test/ir/ir_purity_test.dart`). Other layers import only `ir.dart`, ideally
with a prefix (`as ir`), since several spec names (`Paint`, `TextStyle`, `BlendMode`,
`Constraints`, `Action`) collide with Flutter's.

Models are freezed + json_serializable. Run
`dart run build_runner build` after editing them. Generated files are git-ignored.

## File format conventions

- Unions serialise with a `type` key and explicit camelCase discriminators
  (`@FreezedUnionValue`). Enums serialise by camelCase name. Both are part of the file format.
- Nodes are `{ "type": "frame", "common": { …§4.2 fields… }, "appearance": {…}, …kind fields }`.
- Fields with defaults are always written out; null fields are omitted (`build.yaml`).
- Ids: 10-char base62 (`IdGenerator`). Paint and effect ids only need to be unique within their
  stack, because they are addressed as `fills.<paintId>` / `effects.<effectId>`.
- `schemaVersion` is `kStageSchemaVersion` (1). Load untrusted or old files with
  `StageDocument.fromJsonMigrating`.

## Modelling notes

Choices the spec left open, made to match Figma where possible. The clock list, style references
and text/video appearance were confirmed and are recorded in `DECISIONS.md`; open questions are
in `DECISIONS_NEEDED.md`.

- **Clocks.** `Scene.clocks: [Clock]` holds every clock kind (`sceneScroll`, `timeline`,
  `audio`, `pointer`, `behavior`), each with an `id` and `smoothing`. The spec's
  `Scene.timelines` is the `TimelineClock` subset, exposed as a getter. A single list is needed
  because every clock can set `smoothing` and needs an id for `Track.clockId`, text reveals and
  `clockReach`. A pointer clock has an `axis` (`x`|`y`), so a 2D hover parallax uses two clocks.
- **Blend mode default.** `NodeCommon.blendMode` is nullable. Null means the kind's default:
  `passThrough` for frames and `normal` for everything else (`Node.effectiveBlendMode`).
- **Strokes.** `Appearance.strokes` is one `Stroke` (geometry plus a paint stack), as in Figma.
  No paints means no stroke.
- **Style references.** `Appearance.fillStyleId/strokeStyleId/effectStyleId` point at
  `TokenSystem.paintStyles/effectStyles`, mirroring Figma. The spec defines the style maps but no
  reference field. `TextStyleDef.bindings` carries the token bindings of a text style's fields.
- **Appearance per kind.** Frames, shapes and videos hold an `Appearance` (fills, stroke,
  effects, corners, style ids). On a video, fills paint behind the video (visible in `fit`
  letterboxing and before the first frame). Text holds a `TextAppearance` (stroke, effects,
  `strokeStyleId`, `effectStyleId`): its fills come from the text style cascade, and it has no corners.
  Property paths are the same on every kind (`strokes.weight`, `effects.<effectId>.blur`), so
  the registry hides the difference.
- **`clipContent`** is on `FrameNode`, not `Appearance`, because shapes don't clip.
- **Either/or fields became small unions:** `InstanceSource` (`component` | `variant`),
  `ShapeGeometry` (`rectangle` | `ellipse` | `line` | `polygon` | `star`, each with its own
  parameters), `CornerRadius`, `StrokeWeight`, `Gap`, `LineHeight`, `LetterSpacing`,
  `GridTrack`, `AudioScope`, and `SpanLink` (`url` | `scene`, like Figma's URL or node links).
- **`IrValue`** adds `insets`, `cornerRadius`, `strokeWeight`, `gap`, `paint`, `effect`,
  `numbers` (dash patterns) and `none`, which clears a nullable property in a patch.
- **`ComponentDef.root` is a `FrameNode`**, not a `Node`. A component root is always a frame
  (it needs a box, layout and appearance), and freezed generates `FrameNode.fromJson` for the
  variant, so the JSON keeps `"type": "frame"`. The same applies to `Scene.root` and
  `StageDocument.overlay`.
- **Interactions** (`NodeCommon.interactions`) and **component bindings**
  (`NodeCommon.componentBindings`) are on every node. `behavior` and `modeOverrides` are
  frame-only.
- **Text styles are layered.** `StageDocument.defaultTextStyle` (a complete `TextStyle`) is the
  base. A text node's `textStyleId` names a complete `TextStyleDef`, which replaces the default
  (token bindings resolved in the node's modes). `TextNode.style` is a `TextStyleOverride` (all
  fields nullable, null = inherit) layered over that; then the paragraph style
  (spacing/indent/list) and the span override. `style.*` paths read/write the override fields
  and `IrValue.none()` clears one. The resolved node's own `style` is emptied and `textStyleId`
  cleared: the runtime reads only `ResolvedNode.paragraphs`.
- **Text** has `ParagraphStyle` (align, spacing, indent and list style, all nullable) and a
  default fill of opaque black (`kDefaultTextFills`). `TextDecorationStyle.doubleLine`
  serialises as `"double"`.
- **Behaviours.** Carousel `autoplay` is seconds per slide (0 means off), `physics` is
  `paged`|`free`, and `peek` is in px. Marquee `speed` is px/s, `direction` is
  `left|right|up|down`. Lyrics `scrollMode` is `none|center|top`. TextReveal `range` is a
  `ClockRange`.
- **Actions** address timelines by `clockId`. `audioCue` names its `audioTrackId`.
- **Easing presets:** `ease`, `easeIn`, `easeOut`, `easeInOut`, and the `…Back` variants
  (curves land in T0.3).
- **Defaults:** node geometry 0, `AutoLayout` sizing `hug`/`hug` (Figma's default when auto
  layout is added), `Scene.kind` `flow`, grid placement indices 0-based, `Stroke.align`
  `inside`, `miterLimit` 4.
- **Migrations** reject a missing or non-integer `schemaVersion` instead of guessing.

## Operations (T0.3)

- **Registry** (`src/registry/`). `PropertyRegistry.standard` has one `PropertyDescriptor` per
  property, built from small lenses and codecs (`lens.dart`, internal) in
  `standard_properties.dart`. `lookup(path)` returns a `PropertyMatch` (descriptor + bound
  params) or null. `get` returns null when the property does not exist on the node, and
  `IrValue.none()` for an unset nullable one. `trySet` returns null instead of throwing. Paths
  are the same on every kind: `fills…` (frames, shapes, videos), `strokes…`/`effects…` (plus
  text), `style…` (text base style), `content.<p>.style…` (paragraph) and
  `content.<p>.spans.<s>.style…` (span overrides, all nullable). Stacks are addressed by id
  (`fills.<paintId>.color`, `effects.<effectId>.blur`), gradient stops by index. Whole stacks
  (`fills`, `effects`, `strokes.paints`, `style.fills`) replace the list. `characters` is a text
  node's plain text (Figma's text property target). Instances expose `componentId`,
  `variantValues.<axis>` and `propValues.<propId>`. Numbers coerce into radii, stroke weights,
  gaps and insets. Defaults are the model's constructor defaults.
- **Patches.** `applyPatch` writes through the registry. `none` clears, a `tokenRef` binds, a
  concrete value detaches a binding on the same path, and unknown or inapplicable paths become
  `IrDiagnostic`s.
- **Breakpoints.** `breakpointCascade` walks from the base towards the active breakpoint by
  `minWidth`, never including the base, in either direction. `activeBreakpoint` falls back to the
  narrowest breakpoint below every `minWidth`.
- **Interpolation.** Colours lerp in OKLab with straight alpha; endpoints are returned exactly
  and results are clamped to sRGB. Paint stacks lerp only when kinds, ids, gradient kind/stop
  count and image asset/scale mode/rotation match, otherwise they step. Discrete sub-fields
  (visibility, blend mode) keep the earlier value for the segment. Integer properties step,
  except `fontWeight`, which lerps and rounds.
- **Easing.** Presets: CSS `ease`/`easeIn`/`easeOut`/`easeInOut`, and the easings.net Back
  curves (`easeInBack` (0.36, 0, 0.66, −0.56), `easeOutBack` (0.34, 1.56, 0.64, 1),
  `easeInOutBack` (0.68, −0.6, 0.32, 1.6)). The spring maps the segment onto its settle time
  (|1 − x| envelope ≤ 1e-3) and is normalised to end at exactly 1. Steps and hold follow CSS.
- **Track evaluation.** `evaluateTrack` is the reference implementation and test oracle. Per
  architecture §17.1 the runtime compiles tracks into typed evaluators (T0.6) and never calls it
  per frame.
- **Resolver** (`src/resolve/`). `Resolver.resolve` / `resolveDocument` run §11.3 steps 2–5 as
  per-node steps over an immutable scope (namespace, active modes, enclosing instance's props and
  overrides). The only shared state is the diagnostic list and token caches keyed by the
  identity of the modes map, so per-node memoisation can be added later (§17.1). Output is a
  `ResolvedDocument` of `ResolvedNode`s with namespaced ids, concrete nodes (no instances,
  bindings, overrides, token or style refs; `FrameNode.children` is empty, and children live on
  `ResolvedNode.children`), per-span merged `TextStyle`s, active modes and placeholders for
  failed instances. Ordering and precedence choices are in `DECISIONS_NEEDED.md` #6–#10.
