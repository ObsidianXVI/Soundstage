# Decisions Needed

None of these block M0. Work is proceeding on the provisional answer shown for each.

## 1. Breakpoint cascade direction
**Context.** Each node stores base values plus per-breakpoint patches (`architecture.md` §3.1).
Something has to decide which breakpoint is the base and how others inherit.
**Options.**
- A. *Desktop-first (provisional).* Design at desktop; tablet/mobile inherit and override. This is
  Webflow's model, and the natural one if you design big and adapt down.
- B. *Mobile-first.* Design at mobile; larger breakpoints inherit and override. Matches CSS
  mobile-first practice, and most readers are probably on phones.
- C. *Per-document choice.* The IR already supports any base (`baseBreakpointId`). This only
  decides the default and how the editor presents it.
**Needed by:** M1 (T1.10).

## 2. Editor on small screens
**Context.** A precision layout and timeline editor is impractical on a phone.
**Provisional answer.** The editor targets ≥1024 px. Panels collapse into drawers down to 768 px,
and below that the app offers preview and playback only. Published stories stay fully responsive
at every width.
**Needed by:** M1 (T1.1).

## 3. Single author or multi-author platform?
**Context.** It changes M4: accounts, per-author storage, slugs and quotas, and whether a story's
behaviour must be sandboxed from other authors.
**Provisional answer.** Single author (you) through M4, with a data model (`authorId` on stories)
that does not preclude more.
**Needed by:** M4.

## 4. Firebase / GCP project for Soundstage
**Context.** `AGENTS.md` names `obsivision` as the GCP project. Letterpress hosts in
`letterpress-project`. Soundstage needs Hosting, Storage, Firestore and Auth from M4.
**Options.** A new dedicated Firebase project, or reuse `obsivision`.
**Needed by:** M4.

## 5. Text leading trim (`leadingTrim: capHeight`)
**Context.** Figma's "vertical trim" crops line boxes to cap height and baseline. Flutter's text
APIs do not expose a font's cap height directly, so the runtime would have to read it from the font
file's OS/2 table when the font is loaded.
**Provisional answer.** In the IR from v1, implemented best-effort in T0.4 by reading OS/2
`sCapHeight` from loaded font bytes. If that proves unreliable, it ships later.
**Needed by:** none (informational).

## 6. Where clocks are declared (file format)
**Context.** §10.1 gives every clock kind an optional `smoothing`, and tracks/text reveals/
`clockReach` refer to clocks by `clockId`, but §3.2 only stores `timelines: [TimelineClock]` on a
scene. Scroll, audio, pointer and behaviour clocks had nowhere to keep an id or smoothing.
**Provisional answer (T0.2).** `Scene.clocks: [Clock]`, a sealed union of all five kinds, each
with `id` + `smoothing`. `Scene.timelines` is a getter over it. Pointer clocks carry an `axis`
(`x`|`y`). Alternative: keep `timelines` and add implicit ids like `sceneScroll:<sceneId>`, with
smoothing on the track instead.
**Needed by:** T0.6.

## 7. Paint/effect style references on nodes (file format)
**Context.** §8 defines `paintStyles` and `effectStyles`, and §11.3 resolves "style refs", but §4.2
gives nodes no field that references them.
**Provisional answer (T0.2).** `Appearance.fillStyleId`, `strokeStyleId` and `effectStyleId`
(Figma's model). When set, the style's stack replaces the local one.
**Needed by:** T0.3 (resolver).

## 8. Effects/strokes/corners on text and video nodes
**Context.** §4.2 limits fills/strokes/effects/corners to frames and shapes, so text can't take a
drop shadow and video can't have rounded corners (both available in Figma). Adding these later is
backward compatible: they would be new optional fields with defaults, so no migration is needed.
**Provisional answer.** Follow the spec (none on text/video) for v1. Wrap the node in a frame to
get the effect.
**Needed by:** M1.
