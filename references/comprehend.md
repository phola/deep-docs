# Phase 4: Comprehend

Bottom-up learning phase. One sub-agent per component, each running N loops
(determined by calibration profile). This is the core of deep-docs — genuine
understanding before any writing.

## Principle

No documentation is written in this phase. Only scratchpad notes.
The goal is to build understanding that will make the write phase accurate and insightful.

CRITICAL: The orchestrator MUST loop through EVERY component and spawn a sub-agent for
each one. Verify each component produces a summary scratchpad before marking complete.
Do not delegate "comprehend all components" to a single sub-agent.

## Sub-agent Strategy

**Small/Medium profiles:** One sub-agent per component runs all loops in a single session.

**Large profile OR any component with >30 source files:** Split into per-loop sub-agents.
Each loop is a separate sub-agent that reads the previous loop's scratchpad output.
This prevents context overflow for large components.

Per-loop sub-agent chain:
```
Loop 1 agent → writes 01-inventory.md
Loop 2 agent → reads 01-inventory.md → writes 02-data.md
Loop 3 agent → reads 01+02 → writes 03-functions.md
...each loop reads ALL prior loop outputs for this component
```

The orchestrator spawns loop agents sequentially per component (not parallel — each
depends on the previous). Different components CAN run in parallel at the same loop level.

## Sub-agent Task Template (single-agent mode: small/medium)

Spawn one sub-agent per component (in dependency order from calibration):

```
You are studying the {{COMPONENT_NAME}} component of a codebase at {{REPO_PATH}}.
Your job is to BUILD UNDERSTANDING through iterative study. Do NOT write documentation.
Write scratchpad notes only.

Read these first:
- {{DOCS_DIR}}/builder/interview-notes.md (user context)
- {{DOCS_DIR}}/builder/specs/component-inventory.md (your component's entry)
- {{DOCS_DIR}}/builder/calibration.md (which loops to run)
- Summary scratchpads from completed DIRECT DEPENDENCIES only:
  {{SCRATCH_FILES}}

  ORCHESTRATOR: construct {{SCRATCH_FILES}} as a newline-separated list of paths:
    {{DOCS_DIR}}/builder/.scratch/comprehend-{{DEP_SLUG}}-summary.md
  for each direct dependency listed in component-inventory.md.
  For components with no dependencies, pass the literal string: "None — this component has no project dependencies."

Component path: {{COMPONENT_PATH}}

Run each loop below in order. After each loop, write a scratchpad file to:
{{DOCS_DIR}}/builder/.scratch/comprehend-{{COMPONENT_SLUG}}-NN-{{LOOP_NAME}}.md

ORCHESTRATOR: include ONLY the profile block matching the calibration below.
Delete the other two profile blocks before passing this prompt to the sub-agent.

=== SMALL PROFILE (3 loops) ===

LOOP 1 — INVENTORY + DATA SHAPES → scratchpad: comprehend-{{COMPONENT_SLUG}}-01-inventory.md
- List every file: path, language, line count, rough purpose
- Entry points, config files, test files
- Schemas, types, interfaces, dataclasses, models, config structures
- Input/output data formats, database tables, columns, relationships

LOOP 2 — LOGIC + FLOW → scratchpad: comprehend-{{COMPONENT_SLUG}}-02-logic.md
- Key function/method signatures with parameters and return types
- What each does (read the implementation, don't guess from name)
- Call graph: what calls what, in what order
- External packages, inter-component imports, external services
- Execution lifecycle: startup → processing → cleanup

LOOP 3 — ERROR HANDLING + SIDE EFFECTS → scratchpad: comprehend-{{COMPONENT_SLUG}}-03-errors.md
- What does this component read/write/mutate? (files, DB, env vars, APIs, stdout)
- Concurrency concerns, shared state, locking
- What can fail? How? Recovery mechanisms, retries, fallbacks
- Edge cases: empty inputs, missing config, network failures

=== MEDIUM PROFILE (5 loops) ===

LOOP 1 — INVENTORY → scratchpad: comprehend-{{COMPONENT_SLUG}}-01-inventory.md
- List every file: path, language, line count, rough purpose
- Entry points, config files, test files

LOOP 2 — DATA SHAPES → scratchpad: comprehend-{{COMPONENT_SLUG}}-02-data.md
- Schemas, types, interfaces, dataclasses, models, config structures
- Input/output data formats (JSON, CSV, Delta, API payloads...)
- Database tables, columns, relationships

LOOP 3 — FUNCTIONS + INTERNAL FLOW → scratchpad: comprehend-{{COMPONENT_SLUG}}-03-logic.md
- Key function/method signatures with parameters and return types
- What each does (read the implementation, don't guess from name)
- Call graph: what calls what, in what order
- Execution lifecycle: startup → processing → cleanup

LOOP 4 — DEPENDENCIES + STATE → scratchpad: comprehend-{{COMPONENT_SLUG}}-04-deps.md
- External packages: what, why, version constraints
- Inter-component imports, external services (APIs, databases, file systems)
- What does this component read/write/mutate? (files, DB, env vars, APIs)
- Concurrency concerns, shared state, locking

LOOP 5 — ERROR HANDLING + EDGE CASES → scratchpad: comprehend-{{COMPONENT_SLUG}}-05-errors.md
- What can fail? How? (exceptions, return codes, silent failures)
- Recovery mechanisms: retries, fallbacks, circuit breakers
- Edge cases: empty inputs, missing config, network failures, race conditions

=== LARGE PROFILE (7 loops) ===

LOOP 1 — INVENTORY → scratchpad: comprehend-{{COMPONENT_SLUG}}-01-inventory.md
- List every file: path, language, line count, rough purpose
- Note entry points, config files, test files

LOOP 2 — DATA SHAPES → scratchpad: comprehend-{{COMPONENT_SLUG}}-02-data.md
- Schemas, types, interfaces, dataclasses, models, config structures
- Input/output data formats (JSON, CSV, Delta, API payloads...)
- Database tables, columns, relationships

LOOP 3 — FUNCTIONS → scratchpad: comprehend-{{COMPONENT_SLUG}}-03-functions.md
- Key function/method signatures with parameters and return types
- What each does (read the implementation, don't guess from name)
- Note side effects explicitly

LOOP 4 — INTERNAL FLOW → scratchpad: comprehend-{{COMPONENT_SLUG}}-04-flow.md
- Call graph: what calls what, in what order
- Control flow: conditionals, loops, error paths
- Execution lifecycle: startup → processing → cleanup

LOOP 5 — DEPENDENCIES → scratchpad: comprehend-{{COMPONENT_SLUG}}-05-deps.md
- External packages: what, why, version constraints
- Inter-component imports: what does this component use from others?
- External services: APIs, databases, file systems, cloud services

LOOP 6 — STATE & SIDE EFFECTS → scratchpad: comprehend-{{COMPONENT_SLUG}}-06-state.md
- What does this component read? (files, DB, env vars, API responses)
- What does it write/mutate? (files, DB, API calls, stdout)
- Concurrency concerns, shared state, locking

LOOP 7 — ERROR HANDLING → scratchpad: comprehend-{{COMPONENT_SLUG}}-07-errors.md
- What can fail? How does it fail? (exceptions, return codes, silent failures)
- Recovery mechanisms: retries, fallbacks, circuit breakers
- Edge cases: empty inputs, missing config, network failures, race conditions

After ALL loops, write a summary scratchpad:
{{DOCS_DIR}}/builder/.scratch/comprehend-{{COMPONENT_SLUG}}-summary.md
- Key insights and surprises
- Relationships to other components discovered
- Open questions or things that remain unclear (mark <!-- UNVERIFIED -->)

{{HARD_RULES}}
```

## Per-Loop Sub-agent Template (large profile / >30 source files)

For each loop, spawn a separate sub-agent:

```
You are studying the {{COMPONENT_NAME}} component of a codebase at {{REPO_PATH}}.
This is loop {{LOOP_NUMBER}} of {{TOTAL_LOOPS}}.

Read:
- {{DOCS_DIR}}/builder/specs/component-inventory.md (your component's entry)
- Previous loop outputs for THIS component:
  {{PRIOR_LOOP_SCRATCHPADS}}
- Dependency summaries: {{SCRATCH_FILES}}
- Source code at {{COMPONENT_PATH}}

Run ONLY this loop:
{{LOOP_INSTRUCTIONS}}

Write scratchpad to: {{SCRATCHPAD_PATH}}

{{HARD_RULES}}
```

ORCHESTRATOR: for each loop, extract the matching LOOP block from the profile section
above and pass it as `{{LOOP_INSTRUCTIONS}}`. The `→ scratchpad:` notation in the loop
block is context for the agent; the authoritative output path is `{{SCRATCHPAD_PATH}}`.

Construct `{{PRIOR_LOOP_SCRATCHPADS}}` as a newline-separated list of paths to all
scratchpad files from earlier loops of this component. For loop 1, pass the literal
string: "None — first loop."

After all loops complete, spawn one final sub-agent to write the summary scratchpad
(same as single-agent mode — reads all loop outputs, writes comprehend-{{COMPONENT_SLUG}}-summary.md).

## Scratchpad Format

Each scratchpad file should be structured, scannable, and factual:

```markdown
# Comprehend: {{component}} — Loop N: {{loop_name}}

## Findings
- ...

## Surprises / Non-obvious
- ...

## Questions
- ...
```

## Sequencing

Process components in dependency order. Earlier components' scratchpad summaries are
passed to later components so understanding accumulates. For large profiles, independent
components may run in parallel.

## Transition

After all components complete, proceed to Phase 5: Synthesise.
