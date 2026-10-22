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

Choices the spec left open, made to match Figma where possible. The ones that affect the file
format are also in `DECISIONS_NEEDED.md` (#6–#8).

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
