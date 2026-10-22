# CURRENT TASK

## Release · Feature · Task
M0 Foundations and runtime spike → T0.2 IR models

Spec: `_dev/features/m0.md` (T0.2). Blueprint: `docs/architecture.md` §3–§13. Roadmap: `docs/roadmap.md`.

## Status
IN PROGRESS — delegated to `dev-high`.

## What was done
- T0.1 (done): freezed 3.2.5 / json_serializable / flutter_riverpod 3.4.3 / build_runner added;
  strict analysis options; `build.yaml` (explicit_to_json, no nulls in JSON); `lib/` skeleton
  (`ir`, `runtime`, `editor`, `design_system`, `app`, `utils`); counter template replaced by an
  app smoke test and the `lib/ir` Flutter-purity test. `flutter build web` and `--wasm` both build.

## Definition of done (T0.2)
- [ ] Every model in architecture §3–§12 as freezed + JSON, under `lib/ir/src/`
- [ ] `IrValue`, `StageColor`, ids, geometry value types
- [ ] `schemaVersion` = 1 and a migration runner with a chaining test
- [ ] `StageDocument.empty()` with desktop/tablet/mobile breakpoints (desktop base)
- [ ] JSON round-trip tests for every model and union variant, plus a large composite document
- [ ] `flutter analyze` clean, tests green, purity test green
- [ ] Committed

## Blocked on / decisions needed
Nothing blocking. Five open questions in `DECISIONS_NEEDED.md`, each with a provisional answer.

## Next task after this one
T0.3 IR operations (registry, patches, cascade, interpolation, easing, resolver).
