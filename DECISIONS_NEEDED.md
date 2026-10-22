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

## 6. Text style reference vs the node's own `style` (T0.3)
**Context.** `TextNode.style` is a complete `TextStyle`, so when `textStyleId` is set the resolver
cannot tell which of its fields are "local overrides" of the named style (§11.3 "local values
override style values").
**Provisional answer (built).** With a `textStyleId`, the base style is the named style (its token
bindings resolved in the node's modes). On top of it go only the `style.*` paths written *at that
node* by breakpoint patches, component prop bindings, instance overrides and token bindings. The
stored `style` is the detached fallback, used when the id is unset or dangling. Span overrides
then win as usual. Alternative: make the node-level style a `TextStyleOverride` (a v1 file-format
change, cheap now).
**Needed by:** M1 (inspector text section).

## 7. Instance placement and override precedence (T0.3)
**Context.** §9 says how instances expand but not which root fields the instance supplies, or how
bindings and overrides order.
**Provisional answer (built, Figma-like).** The instance supplies name (when non-empty),
`visible`, `locked`, geometry, rotation, flips, `motion`, `layoutChild`, `mask` and `blendMode`
(when set). Opacities multiply, and interactions of both apply. Everything else comes from the
component root. Order per inner node: component node → its breakpoint patches → prop bindings →
instance overrides (the instance's own, then enclosing instances', so outer wins). Override keys
are inner ids relative to the instance, `<nestedInstanceId>/<innerId>` for nested ones, and the
component root's id addresses the root. Overrides on a nested instance node can change its
`propValues.*`, `variantValues.*` and `componentId` (instance swap).
**Needed by:** M2 (components UI).

## 8. Patches vs token bindings (T0.3)
**Provisional answer (built).** A concrete value in a patch (breakpoint or override) detaches the
token binding on the same exact path at that level. A `tokenRef` value in a patch binds the path.
**Needed by:** M1 (`SetProperty` routing).

## 9. Paths the registry does not address (T0.3)
**Provisional answer.** Grid track lists, shape geometry kind, behaviours, `modeOverrides`,
interactions and span links have no `IrValue` form, so they are not patchable or animatable in v1.
Auto layout and grid are switched by the boolean paths `autoLayout` / `grid` (turning one on
removes the other). Their sub-fields are inapplicable while the layout is off, so a patch cannot
create a layout by accident. `effects.<id>.blur` addresses a shadow's blur or a blur effect's
radius, as Figma labels both "blur". `effects.<id>.radius` also exists for blur effects.
**Needed by:** M1.

## 10. Spring easing duration (T0.3)
**Provisional answer (built).** A spring segment maps the keyframe interval onto the spring's
settle time: the time after which the decay envelope stays within 1e-3 of rest. The response is
divided by its value there, so the segment ends at exactly 1. The spring parameters shape the
curve (bounce), and keyframe spacing sets the duration. The damping ratio is floored at 0.01.
Alternative: physical time (seconds), with the curve cut or held at the next keyframe.
**Needed by:** M1 (timeline easing editor).
