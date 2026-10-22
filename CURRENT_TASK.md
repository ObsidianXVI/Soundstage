# CURRENT TASK

## Release · Feature · Task
M0 Foundations and runtime spike → T0.5 Runtime paint

Spec: `_dev/features/m0.md` (T0.5). Blueprint: `docs/architecture.md` §3–§13. Roadmap: `docs/roadmap.md`.

## Status
READY — T0.4 done; T0.5 not started. T0.3b runs in parallel in a separate worktree.

## What was done
- T0.1 (done): freezed 3.2.5 / json_serializable / flutter_riverpod 3.4.3 / build_runner added;
  strict analysis options; `build.yaml` (explicit_to_json, no nulls in JSON); `lib/` skeleton
  (`ir`, `runtime`, `editor`, `design_system`, `app`, `utils`); counter template replaced by an
  app smoke test and the `lib/ir` Flutter-purity test. `flutter build web` and `--wasm` both build.
- T0.2 (done, `dev-high`): every §3–§12 model as freezed + JSON under `lib/ir/src/` (values,
  nodes, behaviours, interactions, motion, audio, assets/fonts, tokens, components, breakpoints,
  scenes, document), exported from `lib/ir/ir.dart`. The `Node` union holds `common` + `appearance`
  per m0. Polymorphic fields are small sealed unions. `StageDocument.empty`, `Scene.blankPinned`,
  `IdGenerator` (injectable Random), `PropertyPath`/`NodePath` extension types, and the `Patch`
  typedef are in. `kStageSchemaVersion = 1` with `migrateDocumentJson` (empty step list,
  injectable steps) and `StageDocument.fromJsonMigrating`. 236 IR tests cover round-trips of
  every model and variant, a large composite document, minimal JSON defaults, unknown-type errors
  and migration chaining. They also pass under `--platform chrome`. Modelling choices are in
  `lib/ir/README.md`, and three file-format questions are in DECISIONS_NEEDED.md #6–#8.
  Note: this build_runner ignores `--delete-conflicting-outputs`, so use plain
  `dart run build_runner build`.
- T0.3 (done, `dev-high`): Part A added `TextAppearance` (stroke, effects, style ids) on text and
  `Appearance` on video (schema stays 1). `PropertyRegistry.standard` has ~290 descriptors built
  from lenses/codecs, with `lookup` → `PropertyMatch` (descriptor + params). `applyPatch` returns
  `IrDiagnostic`s for bad paths. `breakpointCascade`/`activeBreakpoint`/`breakpointForWidth`.
  Interpolation (OKLab, stop-wise paints, field-wise effects), easing (bezier solver, CSS + Back
  presets, settle-time spring, steps, hold) and `evaluateTrack` (reference oracle). `Resolver` /
  `resolveDocument` → `ResolvedDocument { breakpoint, scenes[ResolvedScene], overlay, nodeIndex,
  diagnostics }` of `ResolvedNode { id (namespaced), node (concrete, children empty), children,
  sourceComponentId, instanceId, paragraphs (merged span styles), modes, isPlaceholder }`. Built
  per §17.1–17.2: per-node steps over an immutable scope, identity-keyed caches, never throws.
  593 tests on the VM; 591 IR tests on Chrome (purity test needs dart:io). DECISIONS_NEEDED
  #6–#10 added (text style vs local style, instance placement/precedence, patches vs bindings,
  unaddressable paths, spring duration).

- T0.4 (done, `dev-high`): `lib/runtime/` renders `ResolvedDocument`s. The pure layout core is
  `computeAutoLayout` (§4.4 steps 1–10) plus `resolveAxisConstraint`/`resolveConstraints`
  (§4.3), covered by a 43-case layout table with exact rects. `RenderStageBox` is the base:
  dry-layout measurement, rotation/flip about the centre with rotated-footprint placement,
  paint-only `motion` at paint and hit test, `identical()` invalidation, and fault containment
  (an error box in edit, nothing in play). On top of it sit `RenderStageFrame`,
  `RenderStageText` (per-paragraph painters, §7 mapping, every autoResize mode, truncation, list
  markers, indent, first baseline), `RenderStageShape` and `RenderStageScene`.
  `StageAppearancePainter` is the T0.5 seam (solid fills, image `fill` with focal point, basic
  strokes). Media is `asset://` resolution plus a decoded-image LRU. `StageNodeWidget` and
  `StageSceneView` map resolved scenes to render objects. `assets/demo/static.stage.json` (3
  scenes, tablet and mobile patches) and procedural images come from `tool/gen_demo_images.dart`.
  The Riverpod dev harness is in `lib/app/`. Verified in Chrome at 390, 834 and 1440
  (`_dev/screens/t0.4/`).
  - 692 VM tests pass (99 runtime). On Chrome, 95 runtime tests pass and 4 demo tests are
    skipped, because the web test runner never completes a `rootBundle` load.
  - Behaviour notes are in `lib/runtime/README.md`. Four questions were added to
    DECISIONS_NEEDED (T0.4-1…4). The most important is T0.4-1: auto-layout sizing is
    direction-relative, so a breakpoint patch that flips `direction` changes which axis is fixed.

## Definition of done (T0.2) — met
- [x] Every model in architecture §3–§12 as freezed + JSON, under `lib/ir/src/`
- [x] `IrValue`, `StageColor`, ids, geometry value types
- [x] `schemaVersion` = 1 and a migration runner with a chaining test
- [x] `StageDocument.empty()` with desktop/tablet/mobile breakpoints (desktop base)
- [x] JSON round-trip tests for every model and union variant, plus a large composite document
- [x] `flutter analyze` clean, tests green, purity test green
- [x] Committed

## Definition of done (T0.3)
- [x] Part A: TextNode strokes + effects (`TextAppearance`), VideoNode `Appearance`; round-trip tests; README
- [x] PropertyRegistry: a descriptor per §4.2/§5/§6/§7 property (stacks by id, gradient stops, image fields, text, `style.*`, span/paragraph paths, whole stacks); lookup → (descriptor, params); unknown → null
- [x] `applyPatch` via the registry (`none` clears; unknown/inapplicable → diagnostics, never throws)
- [x] Breakpoint cascade (desktop-first and mobile-first) + `breakpointForWidth`
- [x] Interpolation (number, OKLab colour, paint stacks stop-wise with structure check, shadows/blurs, insets/radii/points/sizes, step otherwise)
- [x] Easing (linear, bezier Newton+bisection 1e-6, CSS presets + Back, analytic spring ending at 1, steps, hold)
- [x] `evaluateTrack` per §10.2
- [x] Resolver §11.3 steps 2–5 → `ResolvedDocument` (instances, variants, props, overrides, namespaced ids, cycles, cascade, modes, aliases, styles, keyframe token refs, diagnostics)
- [x] Tests listed in the T0.3 brief; existing tests and purity test green; Chrome run of `test/ir`
- [x] `flutter analyze` clean; committed in logical steps; records updated

## Definition of done (T0.4)
- [x] Pure layout core under `lib/runtime/src/render/layout/`: `auto_layout.dart` (§4.4 steps 1–10: hug, fill split with min/max freeze loop, gap auto incl. n=1, negative gaps, primary/counter alignment, baseline across nested frames, wrap rows with rowAlign and counterAxisGap, strokesIncludedInLayout, rotated bounding boxes, hidden/absolute skipped, reverseZIndex paint order) and `constraints.dart` (§4.3, five constraints per axis against R vs P, then min/max). Grid frames lay out as free.
- [x] Render objects: `StageParentData`, `RenderStageFrame` (reference size = stored size, scene root = breakpoint `designSize`), `RenderStageText` (§7 mapping), `RenderStageShape` (rectangle, ellipse incl. arc, line, polygon, star). Rotation/flip about the centre with rotated-bbox placement; paint-only `motion` at paint and hit test; `identical()`-based updates (layout vs paint invalidation); repaint boundaries per §17.1; no default `saveLayer`.
- [x] Text: per-paragraph `TextPainter`s, paragraph spacing, first-line indent, list markers with hanging indent, line height/letter spacing mapping, `TextLeadingDistribution.even`, text case (smallCaps via `smcp`), OpenType features, font variations, decorations, baseline shift, all autoResize modes incl. truncate, horizontal (incl. justified) and vertical alignment, first baseline, font table → family with fallback, first visible solid fill as colour.
- [x] Minimal paint seam `StageAppearancePainter` (solid fills, basic solid stroke inside/center/outside, uniform/per-corner radii, clip content, opacity) and image fills (`asset://` resolution, size-bounded decoded `ui.Image` LRU, `fill` scale mode + focal point).
- [x] Widgets: `StageNodeWidget` (ResolvedNode subtree → render-object widgets keyed by id) and `StageSceneView` (pinned: viewport-sized root; flow: viewport width, own vertical sizing).
- [x] Fault containment (§17.2): layout/paint exceptions caught at the render-object boundary, reported via `FlutterError.reportError`, sized from stored geometry, error box in `edit`, nothing in `play`; placeholders behave the same.
- [x] Dev harness in `lib/app/` loads `assets/demo/static.stage.json`, resolves at the viewport width (re-resolves on breakpoint change), stacks scenes in a `SingleChildScrollView`.
- [x] Demo document with the listed content (pinned hero with focal-point image, constrained title, scrim; flow column of rich text with list; tag wrap; fill card row with min/max; baseline row; rotated element; mobile patch) and bundled images with a source README.
- [x] Tests in `test/runtime/`: layout table (every §4.4 step/edge case, every §4.3 constraint at a resized parent, exact rects), render-level frame rects, text mapping, fault containment, demo renders without exceptions/overflow at 390/834/1440.
- [x] Visual check via chrome-devtools at 390/834/1440, screenshots in `_dev/screens/t0.4/`.
- [x] `flutter analyze` clean; `flutter test` green; `flutter test --platform chrome test/runtime` run; `lib/runtime/README.md` behaviour notes; DECISIONS_NEEDED for ambiguities; records updated; committed in logical steps.

## Blocked on / decisions needed
Nothing blocking. Open questions in `DECISIONS_NEEDED.md` each have a provisional answer.
T0.4-1 (direction-relative auto-layout sizing) should be settled before the M1 inspector.

## Next task after this one
T0.5 Runtime paint: replace the internals of `StageAppearancePainter`
(`lib/runtime/src/paint/appearance_painter.dart`) behind its existing signatures. That covers
gradients, every image scale mode, crop, tile, rotation and filters, per-side and dashed strokes,
effects, corner smoothing, blend modes, and text paint stacks via `srcIn` (in
`RenderStageText.paintStage`). Text strokes and effects are also T0.5. See the "Paint seam" and
"Behaviour notes" sections of `lib/runtime/README.md`.
