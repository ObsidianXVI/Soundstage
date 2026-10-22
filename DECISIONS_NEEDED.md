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
