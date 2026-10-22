# CURRENT TASK

## Release · Feature · Task
M0 Foundations and runtime spike → T0.4 Runtime layout and text

Spec: `_dev/features/m0.md` (T0.4). Blueprint: `docs/architecture.md` §3–§13. Roadmap: `docs/roadmap.md`.

## Status
READY — T0.3 done; T0.4 not started.

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

## Blocked on / decisions needed
Nothing blocking. Ten open questions in `DECISIONS_NEEDED.md`, each with a provisional answer
(#6–#10 come from T0.3 and affect M1/M2 editor behaviour).

## Next task after this one
T0.4 Runtime layout and text: build on `ResolvedDocument`/`ResolvedNode` (render from
`ResolvedNode.node` + `children`; text from `paragraphs`). T0.3b (validator, fuzz tests,
benchmarks per architecture §17–§18) is a separate follow-up.
