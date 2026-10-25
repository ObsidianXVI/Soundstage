# Soundstage — Product spec (25/10/26)

The author's product spec, plus the ideas worth keeping from an external architecture review. This
file records *what* Soundstage should be. `architecture.md` says how, and `roadmap.md` says when.
Where this spec and `architecture.md` disagree, the open question is in `DECISIONS_NEEDED.md`
until it is settled.

## Modes

The editor is split into four modes over one story. Agents and Annotate work across all four.

- **Writing.** Write in Markdown or prose at any breakpoint. Reference assets, keep meta-notes,
  see version history, manage drafts, and collect notes and ideas for each draft on an
  inspiration board.
- **Design.** Layout, assets and elements; style text, colours and graphics.
- **Animation.** Timelines, gestures, interactivity, scroll animation, movement and transitions.
- **Publish.** Manage drafts, releases and versions, links, audiences, analytics, and
  publications (topics or channels). Export and publish to other platforms and formats; keep
  integrations few and core. Mailchimp is a possible newsletter integration. Manage static and
  dynamic variants of a story (without or with animation, video and interactivity).

## Agents

- **What it is.** A built-in agent with access to the current context and the author's data:
  content, assets, designs, animations and design systems.
- **Agent panel.** A chat interface for asking the agent to do things.
- **Annotate mode.** For quick low-fi wireframing, so the author can show the agent what they
  want:
  - The author draws frames, text areas, arrows and paths. Each drawn element opens a linked
    comment box for notes such as font size, family, weight or colour, frame content, and
    animation.
  - While working on a request, the agent can ask the author to point at the canvas, for
    example where an icon goes or the rough path of a line.
  - The agent then builds the real design from the annotations.
- **Proactive toggle.** The agent watches what the author is doing and detects what they need
  help with. Depending on the author's settings, it either asks for approval first or applies
  the help directly.
- **Purpose.** Take the laborious, menial, trial-and-error parts of design and animation off
  the author, who keeps creative direction and content.

## Key requirements

- **Canonical prose editor.** Editing content should be seamless. The author must never have to
  re-check or fix each element, animation or breakpoint by hand after a text edit.
- **Shared content.** Content is shared across responsive layouts.
- **The editor.** A performant, intuitive, reliable and feature-rich content editor, on desktop
  and on mobile.
- **Rendering performance.** High-performance rendering, including initial load and animation.
- **Static publishing is first class.** Static output (no video, animation or interaction) must
  be very good, because many authors will publish static versions of the same story.
  - Page and text layout should match the essentials of InDesign or Affinity Publisher.
  - Static bundles must be fast and good for discovery and SEO.
- **Platform quality.** Reliable mobile behaviour, accessible content, reduced-motion support,
  performance controls, page metadata and custom domains.
- **Design systems.** Reusable tokens, palettes and templates.

## Ideas kept from the external review

These are ideas only. Its stack advice (React, TypeScript, ProseMirror, PostgreSQL) and its
phasing do not apply: Soundstage is Flutter on GCP and its roadmap already exists.

### Model

- **Content is separate from presentation.** A visual text element references a content node.
  It does not own the prose. The same content can then appear in different compositions, in
  static exports and in agent edits.
- **Markdown is a serialization, not the schema.** Import and export it. Unsupported constructs
  are kept as explicit extensions or reported as losses, never dropped silently.
- **Schema invariants:**
  - stable ids for every persistent node;
  - references resolve or are marked broken;
  - breakpoints inherit from a base and do not copy it;
  - animations target stable ids and semantic anchors;
  - every mutation is a versioned operation;
  - releases are immutable snapshots;
  - unknown fields from newer versions are kept, not discarded.
- **Section-relative scroll anchors.** Scroll motion measures progress relative to its section,
  never an absolute document offset. Adding an intro must not shift later animations. Soundstage
  already does this: each scene has its own scroll clock.
- **Edits invalidate only what depends on them.** A text edit triggers re-measuring, re-layout
  of the container and what follows, an overflow check and motion anchors. It leaves unrelated
  crops and timelines alone.
- **Three layout modes in one element model:** flow, constraint and freeform, composable inside
  one another. Freeform is a deliberate choice, not the default.

### Operations and history (the agent's foundation)

- **One typed operation set for humans and the agent.** The agent never writes raw JSON.
  Soundstage's `EditorController` commands play this role.
- **Operation lifecycle:** validate → check preconditions → apply to a working transaction →
  run the affected layout and motion checks → commit.
  - A failed multi-step change commits nothing.
  - Large agent changes are staged in a working copy and rendered before they are committed.
- **Preconditions against stale context.** An operation can carry an expected revision for its
  targets. A stale agent edit is rejected or rebased; it never silently overwrites newer work.
- **Semantic history.** An entry reads like "made the intro two columns", and one agent change
  is one undo step.
- **Four distinct recovery mechanisms:** operation rollback, transaction undo, project version
  restore, and release rollback.

### Agent

- **Context builder.** Selective retrieval per task: the selection, its styles and tokens, the
  active breakpoint, and the current validation errors. Never the whole project by default.
- **Pipeline:** planner → tool executor (typed operations only) → verification (render, check
  the affected breakpoints) → change review (what changed, why, which checks passed; accept,
  reject or refine).
- **Annotations are project objects:** type (frame, arrow, region, comment, path), target
  element ids, and geometry relative to an artboard, not the viewport. Each also carries a note,
  constraints, a status (open, in progress, resolved), and the breakpoint it was drawn on.
- **Agent policy lives outside the story.** It sets what the agent may do unasked. For example,
  it may fix missing alt text, must ask before layout changes, and must never publish.
- **Proactive analysis is event-driven and debounced.** Triggers: overflow after a text edit,
  missing assets, an invalid motion target, a performance budget nearly reached, or the author
  asking for a review. It never interrupts active writing.
- **Measure the agent.** Track whether it achieved the request, its validation failures,
  accept or reject rates, the corrective iterations needed, and whether results stay valid
  across breakpoints.

### Publishing

- **Releases are immutable.** Each one records the revision, assets, compiler and runtime
  version, and a manifest of content-hashed files. A failed release never disturbs the live
  one; the public pointer switches atomically.
- **Static output is a compiler target.** It produces semantic HTML and CSS, responsive
  images, metadata, canonical URLs, structured data, a sitemap and robots rules. The
  interactive variant adds only the runtime that release needs.
- **Each interactive feature declares its static fallback.** A fade-in shows its final state,
  a scroll scene shows a chosen poster composition, click-to-reveal shows the text, an animated
  chart shows a static chart with a data summary.
- **Performance budgets per publication.** Warnings name the asset or effect that is responsible.
- **Readers never download the editor.**

### Tests

- **Model:** Markdown round trips, migrations, stable ids, reference integrity, malformed input.
- **Layout properties:** randomised text lengths, viewport widths, asset sizes and constraint
  combinations, with no invalid geometry and no unhandled overflow.
- **Operations:** apply then undo restores the state; a failed transaction leaves no partial
  commit; a stale edit never overwrites newer work.
- **Motion regressions:** targets survive text edits, reordering, breakpoint changes and
  deletion; reduced-motion and static fallbacks still work.
- **Published output:** screenshots at representative widths, metadata, semantic structure and
  layout shift.
- **Agent evaluation:** a fixed task suite, such as fixing a mobile overflow, making a section
  two columns, adding a scroll reveal, or building an annotated composition. It scores
  correctness, unintended changes and recovery.
- **Long-run regression:** the same project edited, resized, animated, exported and restored
  over and over.

### Success criteria for a beta

- Text edits propagate without manual sync.
- Common content changes cause no unexpected overflow at any breakpoint.
- Reordering content never breaks unrelated animations.
- Agent edits are inspectable, reversible and validated.
- A failed release never takes down the live one.
- Static pages stay light, and interactive ones load only what they use.
- A new author can publish an attractive story without help.
- Authors publish a second and third story.

## Already in place or planned

| Spec item | Status |
|---|---|
| Shared content across breakpoints | Done: shared-base model with per-breakpoint patches (§3.1) |
| Typed operations, one undo step per action, validation | Done: `EditorController` commands, `History`, the IR validator (§15, §17.2) |
| Section-relative scroll motion | Done: per-scene scroll clocks (§10.1) |
| Reduced motion, player semantics, keyboard navigation | Done in M2 (T2.7) |
| Mobile editing | Partly done: content mode below 1024 px (T1.13); the full editor stays desktop-only |
| Tokens, styles, components, templates | M3 (T3.1–T3.3) |
| Interactions and transitions | M3 (T3.4, T3.7) |
| Page metadata, sitemap, robots | M4 (T4.3) |
| Static exports (Markdown, HTML, Letterpress) | M4 (T4.5); static *publishing* is still open, see `DECISIONS_NEEDED.md` |
| Immutable releases | M4 (T4.2) already freezes versions; manifests and rollback are not yet specified |
| Writing / Design / Animation / Publish modes | Not planned yet; see `DECISIONS_NEEDED.md` |
| Agent, Annotate mode, Proactive | Not planned yet; see `DECISIONS_NEEDED.md` |
| Drafts, inspiration boards, meta-notes, analytics, audiences, Mailchimp, custom domains | Not planned yet |
