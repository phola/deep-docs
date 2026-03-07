---
name: deep-docs
description: >
  Generate deep, multi-audience documentation for any code repository using bottom-up
  comprehension loops and tiered output (L1 executive → L4 model context). Use when:
  (1) documenting an undocumented or poorly-documented codebase from scratch,
  (2) updating existing docs after code changes,
  (3) generating retrospective changelogs from git history,
  (4) onboarding new team members or AI agents to a codebase.
  Modes: init (full run), update (incremental), history (retrospective changelog).
  Never modifies source code — documentation only.
---

# deep-docs

Generate thorough, multi-audience documentation for any repository through iterative
comprehension loops. Documents the **as-is state** — never suggests fixes or improvements.

## Modes

| Mode | Trigger | Description |
|------|---------|-------------|
| `init` | "document this repo", "generate docs for..." | Full documentation from scratch |
| `update` | "update docs", "docs are stale" | Incremental update after code changes |
| `history` | "generate changelog", "document evolution" | Retrospective changelog from git history. Options: `--since YYYY-MM-DD`, `--last N` (commits), `--granularity major\|detailed` |

## Quick Start

1. Determine mode from user request (default: `init`)
2. Read the relevant phase guide from `references/`
3. Execute phases in order, spawning sub-agents as described

## Phases Overview

### init mode

| # | Phase | Guide | Sub-agents | User touchpoint |
|---|-------|-------|------------|-----------------|
| 1 | Interview | [interview.md](references/interview.md) | None (interactive) | ✅ Answers questions |
| 2 | Discover | [discover.md](references/discover.md) | 1 | ✅ Reviews specs |
| 3 | Calibrate | [calibrate.md](references/calibrate.md) | None (automated) | Optional |
| 4 | Comprehend | [comprehend.md](references/comprehend.md) | Per component | None |
| 5 | Synthesise | [synthesise.md](references/synthesise.md) | 1 | None |
| 6 | Diagram | [diagram.md](references/diagram.md) | 1 | None |
| 7 | Write | [write.md](references/write.md) | Per component + L2/L4 overviews + L1 | None |
| 8 | Review | [review.md](references/review.md) | 1 (loops until clean) | ✅ Final approval |

### update mode

See [update.md](references/update.md). Runs: diff discovery → targeted comprehend → update docs → changelog → review loop.

### history mode

See [history.md](references/history.md). Runs: harvest git → epoch detection → comprehend per epoch → write changelog → review loop.

## Output Tiers

See [audience-tiers.md](references/audience-tiers.md) for full definitions.

- **L1** — Executive summary. Leadership, stakeholders. 1 page, no code.
- **L2** — Product/BA level. Data flows, diagrams, business rules. 2-4 pages per component.
- **L3** — Developer level. Architecture, patterns, gotchas, code references. Detailed.
- **L4** — Model context. Structured inventory for AI agents. No prose — headings, tables, code blocks.

## Hard Rules (canonical — this is the single source of truth)

These apply to ALL phases and ALL sub-agents. Include in every sub-agent task prompt.

```
HARD RULES — include verbatim in every sub-agent prompt:
1. NEVER modify, fix, or suggest changes to source code
2. NEVER include "consider refactoring", "this could be improved", or similar
3. Document ACTUAL behaviour, not intended or ideal behaviour
4. If something looks like a bug, describe the actual behaviour neutrally
5. Use <!-- UNVERIFIED --> for anything not confirmed by reading source
6. All file paths relative to repo root
7. No secrets, credentials, or .env values in output
```

**Template variable:** Sub-agent prompts use `{{HARD_RULES}}`. The orchestrator MUST replace
this with the 7 rules above, copied verbatim. Do not pass the literal string `{{HARD_RULES}}`.
Always include the full block — even if phase-specific instructions overlap, the hard rules
reinforce boundaries.

## Output Location

Docs default to `{{REPO_PATH}}/docs/` but can target a **separate repository** — useful for
monorepos, centralised docs, or keeping doc PRs out of source CI. Configure during interview.

| Variable | Same repo (default) | Separate repo |
|----------|-------------------|---------------|
| `{{REPO_PATH}}` | Source code location | Source code location |
| `{{DOCS_DIR}}` | `{{REPO_PATH}}/docs/` | Root of the docs repo |

When using a separate docs repo, the builder/ directory and scratchpad live in the docs repo.
All source file references in generated docs use paths relative to `{{REPO_PATH}}`.

**Variable resolution after interview:**
- If same repo: `{{DOCS_DIR}}` = `{{REPO_PATH}}/docs/` (or user-specified subdirectory)
- If separate repo: `{{DOCS_DIR}}` = root of the docs repo path provided by user
- `{{DOCS_REPO_PATH}}` is only used during interview to capture the separate repo path.
  After resolution, all phases use `{{DOCS_DIR}}` exclusively — it is the only output path variable.

## Component Variables

`{{COMPONENT_SLUG}}` = lowercase, hyphen-separated version of the component name.
Examples: "Auth Module" → `auth-module`, "UserAPI" → `user-api`, "shared/utils" → `shared-utils`.

`{{COMPONENT_PATH}}` = directory path for the component, relative to repo root.
Examples: `src/auth`, `packages/api`, `lib/shared/utils`.

`{{COMPONENT_NAME}}` = human-readable name from the component inventory.

All three are determined during discover phase and recorded in component-inventory.md.

## Progress Log

All phases append to `{{DOCS_DIR}}/builder/progress.md` — a unified, append-only log
of the entire run. The orchestrator writes phase transitions; sub-agents write on
completion (or failure).

Format — each entry is a single line:
```
[HH:MM] PHASE/component — status (details)
```

Examples:
```markdown
[07:12] INTERVIEW — complete (8 questions, output: interview-notes.md)
[07:14] DISCOVER — started
[07:16] DISCOVER — complete (12 components, 847 source files, profile: large)
[07:16] CALIBRATE — complete (large profile, 7 loops, per-loop mode for 3 components)
[07:17] COMPREHEND/shared-utils — started (single-agent, 7 loops)
[07:19] COMPREHEND/shared-utils — complete (7 loops, 4 surprises noted)
[07:19] COMPREHEND/auth — started (per-loop mode, 34 files)
[07:20] COMPREHEND/auth — loop 1/7 complete (inventory: 34 files catalogued)
[07:21] COMPREHEND/auth — loop 2/7 complete (data: 6 schemas found)
...
[07:45] COMPREHEND — all 12 components complete (2 skipped: see skipped-components.md)
[07:46] SYNTHESISE — started (batched, 3 groups)
[07:48] SYNTHESISE — group 1/3 complete
...
[08:10] REVIEW — iteration 1: 4 errors, 7 warnings fixed
[08:15] REVIEW — iteration 2: REVIEW_CLEAN
[08:15] COMPLETE — 12 components documented, L1-L4 written, 5 diagrams generated
```

**Rules:**
- Orchestrator writes phase start/complete lines
- Sub-agents append their own completion line (with key metrics)
- Per-loop agents append one line per loop completion
- Failures logged with ❌: `[07:22] COMPREHEND/payments — ❌ failed (retry 1/1)`
- Never delete or rewrite previous entries — append only

## Scratchpad Convention

Comprehension loops write working notes to `{{DOCS_DIR}}/builder/.scratch/`. These are:
- Working memory between loops — sub-agents read selectively, never "load all"
- Kept after completion as reference (not loaded into context for later runs)
- Namespaced: `.scratch/phase-component-loop.md` (e.g. `.scratch/comprehend-auth-module-03-flow.md`)

## Calibration Profiles

See [calibrate.md](references/calibrate.md). Auto-selected based on repo size.

| | Small (<20 files) | Medium (20-100) | Large (100+) |
|---|---|---|---|
| Comprehend loops | 3 (collapsed) | 5 | 7 (full) |
| Loop agents | Single agent/component | Single (per-loop if >30 files) | Per-loop agents |
| Synthesise passes | 1 | 2 | 3 (batched if >20 components) |
| Write sub-agents | 1 (all components) | Per component (sequential) | Per component (parallel where safe) |

## Error Handling

When a sub-agent fails (timeout, error, partial output):

1. **Comprehend/Write sub-agent fails:** Retry once. If it fails again, skip the component
   and note it in `{{DOCS_DIR}}/builder/skipped-components.md`. Continue with remaining
   components — don't abort the whole run.
2. **Synthesise/Diagram sub-agent fails:** Retry once. If it fails again, proceed to write
   phase without synthesis/diagrams — the comprehension scratchpads are sufficient for
   basic docs. Note the gap in REVIEW.md.
3. **Review sub-agent fails:** Retry once. If it fails again, present whatever partial
   review exists to the user.
4. **Discover/Calibrate fails:** Cannot continue — inform the user and stop.

For parallel sub-agents (large profile), allow individual failures without aborting siblings.

## Sub-agent Spawning

Use `sessions_spawn` with `runtime: "subagent"` for each sub-agent. Include in every task:
1. The hard rules (verbatim from above)
2. The repo path
3. The docs output directory
4. The relevant scratchpad files to read (not all — only what's needed)
5. The specific phase instructions from the relevant reference file
6. "On completion, append a progress line to {{DOCS_DIR}}/builder/progress.md"

The orchestrator writes phase-level start/complete lines to progress.md directly.
Sub-agents write their own completion lines (with key metrics from their work).
