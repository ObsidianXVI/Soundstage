## Project Description
Soundstage is an immersive storytelling platform for writers, bloggers, philosophers, and
raconteurs. Instead of a Markdown/rich-text page, a Soundstage story is a sequence of **scenes**:
layered, art-directed compositions of text, images, video, audio and components, driven by
scroll, time, sound and gesture. Authors build stories in Soundstage's own visual editor — with
Figma-grade control over layout, media sizing, and typography, plus a timeline for keyframed
motion — and publish them to a hosted player. There is no Figma (or any external design tool) in
the loop.

The technical blueprint is `docs/architecture.md`. The phased plan is `docs/roadmap.md`.

## Repo layout
```
Soundstage/
├── AGENTS.md, CURRENT_TASK.md, CURRENT_RELEASE.md, DECISIONS.md, DECISIONS_NEEDED.md
├── docs/                    Technical blueprint (architecture.md) and roadmap (roadmap.md)
├── _dev/                    Local working records: features/, session_log.md, test_status.md
└── soundstage_platform/     The Flutter web app (editor + player). Run flutter/dart from here.
    └── lib/
        ├── ir/              Stage IR — the story document model. Pure Dart, no Flutter imports.
        ├── runtime/         StagePlayer — renders the IR (layout, paint, text, media, clocks, motion)
        ├── editor/          The visual editor — canvas overlay, panels, inspector, timeline, commands
        ├── design_system/   Tokens and components for the editor's own chrome (not story styling)
        ├── app/             App shell and routing (editor route, player route)
        └── utils/           Utilities
```
Dependency direction is strict: `ir` ← `runtime` ← `editor` ← `app`. `ir` imports nothing from
the others; `runtime` never imports `editor`.


## Workflows and Memory

The project is set up with a few Markdown files for long-horizon planning, situation tracking, efficient context management and surgical-precision code changes. Adhere to the following workflows, conventions, and routines.

### Context Layers

The overall picture is that state/memory is managed in three layers:

```
Layer 1 — Always loaded (cheap)
  AGENTS.md             project brief, hard rules, layout
  CURRENT_TASK.md      exactly where we are right now with the active milestone and task

Layer 2 — Loaded for the active feature (~3-5K tokens)
  _dev/features/<milestone>.md   focused spec for the current/specific work unit
  DECISIONS.md         settled architectural decisions

Layer 3 — Loaded when touching the core contract
  docs/architecture.md  IR, resolution pipeline, runtime, editor architecture
  docs/roadmap.md       milestones and tasks
```

### Workflow Each Turn

1. Read CURRENT_TASK.md first. This tells you exactly what to do.
2. Read DECISIONS.md if you hit an architecture question — it may already be answered. Likewise, if a decision has been answered by the user, document it properly in DECISIONS.md for future reference.
3. Work through the task. When done:
- Verify every checkbox in the 'Definition of done' section of CURRENT_TASK.md
- Update CURRENT_TASK.md: mark done items, write what you did, set next task
- Append a one-paragraph summary to `_dev/session_log.md` with timestamp in the format:
```
DD/MM/YY HH:mm [FEAT/FIX] (<short commit hash if any commits made>) `<agent name or "dev-pro-large" if own self>` Concise but all-encompassing description/summary
... a list of core file changes (not tests or other minor stuff) in the form:
- <"A"/"M"/"D"> <filepath>
where "A" is for addition, "M" is for modification and "D" is for deletion
```
- Update _dev/test_status.md if any test status changed
- Commit working code only. Do not commit if build or tests fail.
4. If you need more context, refer to the `docs` folder for the technical blueprint of the system. Or search for documentation online. Never use third-party APIs in the codebase without grounding evidence of its actual existence. Prompt the user for guidance when not confident. Provide enough context in the prompt to the user so the user does not have to search through the logs, feature file, diffs, etc to answer.
5. If you cannot complete the task despite user prompts for guidance, write why in CURRENT_TASK.md and stop cleanly, with enough context to pick up later on without having to re-analyse for context gathering later.

Do not invent architecture. If you hit a decision the spec doesn't cover, write it to DECISIONS_NEEDED.md and continue with unblocked work.


### Sub-Agents

In order to prevent the clouding of your own context window, you will be the main orchestrator planning the feature/fix, and commanding sub-agents to perform/work through the nitty-gritty of the actual implementation, so that token costs are lower too. You will settle only key/complex details and let the sub-agents handle the rest. The sub-agents are based on increasing orders of intelligence:
- Use the `dev-light` agent For extremely brain-dead, labour-intensive work or tasks with back-and-forths or trial-and-errors. Cheap tokens.
- Use the `dev-moderate` agent For simple-to-moderate difficulty tasks or those which require average SWE skill and reasoning. Especially UI related work and design-to-code tasks once the groundwork has been laid and some refinement is needed.
- Use the `dev-high` agent For complex, critical, or wide-scoped work which require lots of reasoning and have small room for error.
- Use the `dev-pro` For the highest level of critical thinking power, reasoning, and accuracy. For truly large-scale, complex and wide-spanning problems. Use sparingly.

Ensure the sub-agents are given enough context about the plans and approach to implement such that they don't go around in circles. Also ensure they follow all the context- and project-tracking guidelines/workflows and technical guidelines outlined in this document.

# Development/Technical Guidelines

## Hard rules — always follow these
1. `flutter analyze` must return zero errors and zero warnings before committing Dart code.
2. `lib/ir/` never imports `package:flutter`. It must stay extractable into a standalone Dart package.
3. Any change to the IR's serialised shape bumps `schemaVersion` and ships a migration, so saved
   stories keep loading.
4. Never use a third-party API without grounding evidence that it exists (pub.dev, package source).
5. Never add API keys or secrets to any file. They live in `.env` and GCP Secret Manager (in prod).
6. Generated files (`*.freezed.dart`, `*.g.dart`) and build output are git-ignored — never commit
   them. Run `dart run build_runner build` after changing models.
7. GCP/Firebase resources are created through Terraform, never `gcloud ... create`.

## Language notes
- Dart: use freezed for all data classes (IR and editor state), Riverpod for state management.
  Use the `dart` MCP for static analysis.

## GCP project
- Project ID: obsivision (provisional — see DECISIONS_NEEDED.md)
- Default zone: us-central1-a
- Default region: us-central1

## Before finishing any task
1. Run `flutter analyze` (hard rule 1) and the tests
2. Write or update the test for the code you changed
3. `git add -p` to review your own diff before committing
4. Commit with message format: `feat(component): description` or `fix(component): description`.
   Commit at each completed, green task — small commits, not one per milestone.
5. Update CURRENT_RELEASE.md with the next task to work on
6. Log into `_dev/session_log.md`

## If you hit an architecture decision the task spec doesn't cover
Stop, write the question to DECISIONS_NEEDED.md, and continue with
the next unblocked task. Do not invent architecture — flag it. At the end, prompt the user with the particular decisions needed.
