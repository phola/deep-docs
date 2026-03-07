# Phase 4: Comprehend

Bottom-up learning phase. One sub-agent per component, each running N loops
(determined by calibration profile). This is the core of deep-docs — genuine
understanding before any writing.

## Principle

No documentation is written in this phase. Only scratchpad notes.
The goal is to build understanding that will make the write phase accurate and insightful.

## Sub-agent Task Template

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

LOOP 1 — INVENTORY + DATA SHAPES
- List every file: path, language, line count, rough purpose
- Entry points, config files, test files
- Schemas, types, interfaces, dataclasses, models, config structures
- Input/output data formats, database tables, columns, relationships

LOOP 2 — LOGIC + FLOW
- Key function/method signatures with parameters and return types
- What each does (read the implementation, don't guess from name)
- Call graph: what calls what, in what order
- External packages, inter-component imports, external services
- Execution lifecycle: startup → processing → cleanup

LOOP 3 — ERROR HANDLING + SIDE EFFECTS
- What does this component read/write/mutate? (files, DB, env vars, APIs, stdout)
- Concurrency concerns, shared state, locking
- What can fail? How? Recovery mechanisms, retries, fallbacks
- Edge cases: empty inputs, missing config, network failures

=== MEDIUM PROFILE (5 loops) ===

LOOP 1 — INVENTORY
- List every file: path, language, line count, rough purpose
- Entry points, config files, test files

LOOP 2 — DATA SHAPES
- Schemas, types, interfaces, dataclasses, models, config structures
- Input/output data formats (JSON, CSV, Delta, API payloads...)
- Database tables, columns, relationships

LOOP 3 — FUNCTIONS + INTERNAL FLOW
- Key function/method signatures with parameters and return types
- What each does (read the implementation, don't guess from name)
- Call graph: what calls what, in what order
- Execution lifecycle: startup → processing → cleanup

LOOP 4 — DEPENDENCIES + STATE
- External packages: what, why, version constraints
- Inter-component imports, external services (APIs, databases, file systems)
- What does this component read/write/mutate? (files, DB, env vars, APIs)
- Concurrency concerns, shared state, locking

LOOP 5 — ERROR HANDLING + EDGE CASES
- What can fail? How? (exceptions, return codes, silent failures)
- Recovery mechanisms: retries, fallbacks, circuit breakers
- Edge cases: empty inputs, missing config, network failures, race conditions

=== LARGE PROFILE (7 loops) ===

LOOP 1 — INVENTORY
- List every file: path, language, line count, rough purpose
- Note entry points, config files, test files

LOOP 2 — DATA SHAPES
- Schemas, types, interfaces, dataclasses, models, config structures
- Input/output data formats (JSON, CSV, Delta, API payloads...)
- Database tables, columns, relationships

LOOP 3 — FUNCTIONS
- Key function/method signatures with parameters and return types
- What each does (read the implementation, don't guess from name)
- Note side effects explicitly

LOOP 4 — INTERNAL FLOW
- Call graph: what calls what, in what order
- Control flow: conditionals, loops, error paths
- Execution lifecycle: startup → processing → cleanup

LOOP 5 — DEPENDENCIES
- External packages: what, why, version constraints
- Inter-component imports: what does this component use from others?
- External services: APIs, databases, file systems, cloud services

LOOP 6 — STATE & SIDE EFFECTS
- What does this component read? (files, DB, env vars, API responses)
- What does it write/mutate? (files, DB, API calls, stdout)
- Concurrency concerns, shared state, locking

LOOP 7 — ERROR HANDLING
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
