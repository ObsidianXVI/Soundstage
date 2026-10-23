# Soundstage — Roadmap

Each milestone ends in something usable. Task specs for the active milestone live in
`_dev/features/<milestone>.md`. Section references (§) point into `architecture.md`.

## M0 — Foundations and runtime spike
Goal: a hand-written `.stage.json` renders in the real runtime with Figma-grade layout, media and
text, plus scroll-driven motion and synced audio. This answers the Flutter-web scroll-feel risk
before the editor is built on top.

| Task | What | Agent |
|---|---|---|
| T0.1 | Project foundations: dependencies, `lib/` skeleton, lint config, codegen, test setup | orchestrator |
| T0.2 | IR models: every model in §3–§12 as freezed + JSON, `schemaVersion` 1, migration scaffold, ids | dev-high |
| T0.3 | IR operations: PropertyRegistry, patches, breakpoint cascade, interpolators, easing, track evaluation, resolver → ResolvedTree | dev-high |
| T0.3b | Validator, fuzz tests, benchmark harness (§17–§18) | dev-moderate |
| T0.4 | Runtime layout and text: `RenderStageFrame` (free + constraints + auto layout incl. wrap/baseline), `RenderStageText` (§7), `RenderStageShape`; the layout test table | dev-high |
| T0.5 | Runtime paint: paint stacks, gradients, image scale modes + focal point + filters, strokes, effects, corner smoothing, blend modes, clip, motion transform | dev-moderate |
| T0.6 | Runtime motion: `StagePlayer`, pinned/flow scene slivers, clocks + smoothing, animator writing to render objects | dev-high |
| T0.7 | Fonts and audio: runtime font loading, `just_audio` tracks, audio clock, LRC import, `Lyrics` + `TextReveal` behaviours, enter gate | dev-moderate |
| T0.8 | Spike demo story + feel/performance report + go/no-go checkpoint with the user | orchestrator + dev-moderate |

## M1 — Editor foundations (static design)
Goal: build a static, responsive multi-scene story entirely in the editor and save it.

- T1.1 Editor design system (chrome tokens, panels, number/colour fields, icons) and app shell
  routes (`/edit/<id>`, `/play/<id>`).
- T1.2 `EditorController`, `EditorState`, `History`, command framework, `SetProperty` routing.
- T1.3 Canvas: camera (zoom/pan), artboard at breakpoint size, free-width drag, edit-mode player,
  `NodeGeometryRegistry`.
- T1.4 Selection and hover (Figma rules), marquee, overlay painter.
- T1.5 Transform tools: move, resize, rotate, nudge; snapping and smart spacing guides;
  measurement; reorder inside auto layout.
- T1.6 Layers panel.
- T1.7 Inspector: Frame, Position and Constraints, Auto layout, Layout child, Appearance, Fill,
  Stroke, Effects — registry-driven, with mixed values and value-source badges.
- T1.8 Text: inline text editing on the canvas, text inspector, rich spans, semantic `role`
  (heading/paragraph/quote/caption/figure/decorative), alt text and reading order.
- T1.9 Insert tools (frame, text, shapes, image), Assets panel (upload, variants, placeholders),
  Fonts panel (upload families, variable axes).
- T1.10 Scenes panel (add, reorder, pinned/flow, scroll length) and breakpoint editing (overrides).
- T1.11 Persistence: IndexedDB autosave, `.stage.json` and zip import/export.

## M2 — Motion and timeline
- T2.1 Timeline panel: lanes, playhead bound to the scene clock, scrubbing.
- T2.2 Keyframes: auto-key, add/move/delete/copy, multi-select.
- T2.3 Easing editor (bezier + spring) and motion presets.
- T2.4 Timeline clocks (time-based) and triggers; pointer clocks; smoothing controls.
- T2.5 Audio lane (waveform peaks), lyrics lane, LRC import UI, `Lyrics` and `TextReveal` setup.
- T2.6 Preview mode (real scroll) beside the editor.
- T2.7 Player accessibility: semantics generated from roles and reading order (screen readers,
  headings, links, lyric transcript), keyboard navigation between scenes. Invisible, so it adds
  no static content.

## M3 — Systems
- T3.1 Tokens: collections, modes, variables, breakpoint modes; styles (text/paint/effect); binding UI.
- T3.2 Components: create, edit main, instances, overrides, component properties, variants, detach.
- T3.3 Behaviours: Carousel, Lightbox, Marquee; starter component library (gallery, carousel, tiles).
- T3.4 Interactions (triggers → actions) and state variables.
- T3.5 Grid layout (§4.5) runtime and inspector.
- T3.6 Video nodes, image sequences, Rive/Lottie embeds, masks.
- T3.7 Scene transitions and the story overlay.

## M4 — Publishing
- T4.1 Firebase Auth, Firestore metadata, Storage documents and assets (Terraform-provisioned).
- T4.2 Publish/version flow, `/s/<slug>` player route, asset CDN variants.
- T4.3 Head metadata per story (title, description, canonical, OG/Twitter card with poster
  frame), `robots.txt`, `sitemap.xml`. Nothing visible besides the rendering.
- T4.5 Static exports (§16.1): Markdown, HTML, Medium/Substack rich-text copy, Letterpress
  (Markdown + generated `LPModule`), poster frames, "View interactive article on Soundstage"
  backlinks. Local export (no backlink URL yet) can ship earlier, from the M1 editor.
- T4.4 Chunked published documents (manifest + per-scene chunks, lazy fetch), §17.3.

## M5 — Later
- `.stage.script` as a text view of the IR, for diffs and LLM-assisted editing.
- Multi-author accounts, collaboration.
- Letterpress embedding (`StagePlayer` inside an `LPModule`).
- **Export to Flutter:** a one-way generator from a story to a standalone Dart widget tree, for
  ownership and no lock-in. The IR stays the source of truth.
