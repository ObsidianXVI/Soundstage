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

## T0.4-1. Which field decides whether an auto-layout frame hugs, and is it per axis?
**Context.** The IR has two sources for a frame's sizing. `autoLayout.primarySizing/counterSizing`
are relative to `direction`, and `layoutChild.horizontalSizing/verticalSizing` are per axis.
Figma has one per-axis setting. Because our auto-layout sizing is direction-relative, a breakpoint
patch that flips `direction` (e.g. a card row that becomes a column on mobile) silently swaps
which axis is fixed. This happened in the T0.4 demo: the column collapsed to a height of 0.
**Provisional answer (runtime, T0.4).** Effective sizing per axis is `fill` > `hug` > `fixed`.
An axis hugs when either the auto-layout sizing for that axis or `layoutChild` says `hug`. Text
hugs according to `autoResize`. Authors set `layoutChild.verticalSizing: hug` to keep an axis
hugging across a direction flip.
**Options.**
- A. Keep both, with the rule above (no schema change).
- B. Make the auto-layout sizing per axis (`widthSizing`/`heightSizing`), as in Figma. This needs a
  schema bump and a migration.
- C. Drop `primarySizing/counterSizing` and use `layoutChild` sizing only (`hug` on a frame means
  "hug its auto-layout content"). This also needs a migration.

Recommendation: B or C before M1, because the editor's inspector shows one control per axis.
**Needed by:** M1 (inspector, T1.x).

## T0.4-2. Geometric rotation direction
**Context.** The spec gives the units for `rotation` but not its direction. Ellipse arcs are
clockwise, and `motion.rotate` is CSS-like (clockwise). Figma's UI shows positive rotation as
counter-clockwise.
**Provisional answer.** Positive is clockwise on screen everywhere. The editor can negate the
value for display if it wants Figma's convention.
**Needed by:** M1 (inspector rotation field).

## T0.4-3. Reference size of a flow scene's root
**Context.** §4.3 says a scene root's reference size is the breakpoint's `designSize`. A flow
root's height is its content height, not a viewport height, so `designSize.height` makes
bottom/center/scale constraints inside flow roots meaningless.
**Provisional answer.** Pinned roots use `designSize`. Flow roots use `designSize.width` × the
root's stored height.
**Needed by:** M1 (canvas artboard sizing).

## T0.4-4. Fill on the counter axis of a hugging frame, and `gap: auto` with fill children
**Context.** §4.4 covers neither case.
**Provisional answer (Figma-like).**
- Counter-axis `fill` children stretch to the largest non-fill sibling, and hug if every child
  fills.
- With `gap: auto`, fill children are sized with a gap of 0. Any leftover space (from fills
  frozen at their max) becomes the gap.
**Needed by:** none (informational; the editor may disable these combinations as Figma does).
