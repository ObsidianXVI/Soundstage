# CURRENT TASK

## Release · Feature · Task
M0 Foundations and runtime spike → T0.3 IR operations

Spec: `_dev/features/m0.md` (T0.3). Blueprint: `docs/architecture.md` §3–§13. Roadmap: `docs/roadmap.md`.

## Status
READY — T0.2 done; T0.3 not started.

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

## Definition of done (T0.2) — met
- [x] Every model in architecture §3–§12 as freezed + JSON, under `lib/ir/src/`
- [x] `IrValue`, `StageColor`, ids, geometry value types
- [x] `schemaVersion` = 1 and a migration runner with a chaining test
- [x] `StageDocument.empty()` with desktop/tablet/mobile breakpoints (desktop base)
- [x] JSON round-trip tests for every model and union variant, plus a large composite document
- [x] `flutter analyze` clean, tests green, purity test green
- [x] Committed

## Definition of done (T0.3)
See `_dev/features/m0.md` T0.3: PropertyRegistry with descriptor get/set round-trip test,
applyPatch + breakpoint cascade (desktop-first and mobile-first), interpolators (OKLab), easing
(incl. CSS `ease` samples), track evaluation, resolver → ResolvedTree (instances, variants,
modes, aliases with cycle detection, style refs incl. `Appearance.*StyleId`).
- [ ] Registry + patches + cascade
- [ ] Interpolation + easing + track eval
- [ ] Resolver
- [ ] Tests, `flutter analyze` clean, committed

## Blocked on / decisions needed
Nothing blocking. Eight open questions in `DECISIONS_NEEDED.md`, each with a provisional answer
(#6 clock declarations and #7 style references affect T0.3/T0.6).

## Next task after this one
T0.4 Runtime layout and text.
