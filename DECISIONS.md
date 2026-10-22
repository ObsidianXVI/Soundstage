# DECISIONS

## 22/10/26

- **Authoring happens entirely in Soundstage's own visual editor. No Figma.** Scenes, layers,
  assets, fonts, tokens, components, layout, free positioning, keyframes, timeline and motion are
  all handled inside the platform.
  Rationale (user decision): writing a script, compiling, previewing and tweaking is too slow a
  loop for spatial and temporal design. Figma has no scroll/time/audio axis and its output would
  always be a second renderer away from what ships.

- **Stories are data (the Stage IR), interpreted at runtime by one prebuilt Flutter app.** No
  per-story code generation.
  Rationale: Dart cannot evaluate code at runtime, so data is the only way to get live editing.
  One deployed runtime serves every story. The editor, any future text format and any future
  importer all just produce or edit the IR. A second renderer (e.g. HTML) stays possible later.

- **The editor is the player in edit mode.** The canvas uses the same render objects as the
  published story.
  Rationale: this removes any fidelity gap between design and output, which is the core promise.

- **Figma's semantics are the reference for layout, media sizing and text** (auto layout,
  constraints, hug/fill/fixed, min/max, scale modes, text auto-resize, line-height/letter-spacing
  units), implemented from scratch in custom render objects rather than `Row`/`Column`/`Stack`.
  Rationale (user requirement): these core functions must be top-notch, like Figma. Flex/Stack
  semantics differ (e.g. space-between, fill freezing, constraints against a reference size,
  baseline across frames), so composing stock widgets would leak those differences.

- **Everything animatable is a property bound to a clock** (scene scroll, timeline, audio,
  pointer, behaviour). Tracks of keyframes map a clock to a `PropertyPath`.
  Rationale: one mechanism covers scroll-driven animation, timed animation, lyric sync and gesture
  response, which keeps both the runtime and the timeline UI small.

- **One `PropertyPath` + `PropertyRegistry` addresses properties everywhere** — breakpoint
  overrides, instance overrides, token bindings, tracks and the inspector. Paints and effects are
  addressed by id, not by index.

- **Animation writes directly into render objects**; playback never calls `setState`. A separate
  paint-only `motion` transform exists beside geometric `rotation` so most scroll animation stays
  paint-only.

- **Breakpoint overrides cascade away from a base breakpoint** (Webflow model; base = desktop by
  default). *Provisional* — confirmation requested in DECISIONS_NEEDED.md.

- **Code layout:** one Flutter app in `soundstage_platform/` with strict layers
  `ir ← runtime ← editor ← app`. `ir` has no Flutter imports, so it can be extracted into a package
  (for a CLI, a server-side prerenderer, or Letterpress embedding) without a rewrite.
  Rationale: a multi-package workspace adds friction before there is a second consumer; enforcing
  the boundary keeps extraction cheap.

- **Stack:** freezed + json_serializable for every data class (IR and editor state), Riverpod
  (`flutter_riverpod`) for state, `just_audio` for audio (web supported). The file format is
  `.stage.json` with an integer `schemaVersion` and stepwise migrations.

- **The editor targets desktop browser widths.** Panels collapse down to tablet width; below that
  the app offers preview/playback only. Published stories must be fully responsive at every width.
  *Provisional* — confirmation requested in DECISIONS_NEEDED.md.

- **Agent config, `_dev/` and `.claude/` are git-ignored**, matching Letterpress.

- **Clocks are declared in `Scene.clocks`**, a sealed union of every clock kind, each with an `id`
  and `smoothing`; pointer clocks are single-axis. (Gap found in T0.2; adopted as built.)
  Rationale: tracks, text reveals and `clockReach` all refer to clocks by id, and every kind can
  be smoothed, so every kind needs a declaration.

- **Nodes reference paint/effect styles via `Appearance.fillStyleId/strokeStyleId/effectStyleId`**,
  and a set style replaces the local stack (Figma's model). (Gap found in T0.2; adopted as built.)

- **Text nodes take strokes and effects; video nodes take corners, strokes and effects.**
  Rationale: overrides the v1 spec's frames-and-shapes-only limit. Text shadows over imagery and
  rounded video are everyday immersive-design needs, and Figma supports both. Added before the
  property registry exists, so it costs one model change instead of a migration later.

- **The IR stays the source of truth; code is never the source of truth.** (User asked whether
  raw code could replace the IR; agreed to keep the IR as long as it is not unnecessary, and that
  it is performant, reliable and scalable.)
  Rationale: the editor needs a structured in-memory model regardless. Code as the source of
  truth would add a Dart parse/print round-trip, require a compile per edit (no live canvas) and
  a Flutter build per publish, and lose the structure that undo, overrides, instances and
  keyframes depend on. The `.stage.script` text format stays optional (M5). "Export to Flutter"
  (one-way) is planned for M5 to cover ownership.

- **Performance, reliability and scalability are specified requirements** (architecture §17,
  budgets §18): compiled allocation-free tracks, identity-based caching and incremental
  resolution, lazy scenes, contained render faults, never-failing document loads, crash-safe
  autosave, immutable published versions, CDN-only reader path, chunked published documents.
