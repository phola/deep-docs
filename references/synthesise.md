# Phase 5: Synthesise

Cross-component understanding phase. Single sub-agent reads all scratchpad notes
and builds system-level understanding.

## Purpose

Individual component comprehension misses the big picture: how data flows end-to-end,
why the architecture is shaped the way it is, what the deployment topology looks like.
This phase connects the dots.

## Sub-agent Task

```
You have studied every component of a codebase individually. Now build system-level
understanding by reading all comprehension notes and tracing cross-component patterns.

Read:
- {{DOCS_DIR}}/builder/interview-notes.md
- {{DOCS_DIR}}/builder/specs/scope-and-goals.md
- {{DOCS_DIR}}/builder/specs/component-inventory.md

CONTEXT MANAGEMENT:
For repos with ≤20 components: read all summary scratchpads directly:
  {{DOCS_DIR}}/builder/.scratch/comprehend-*-summary.md

For repos with >20 components: synthesise in batches:
  1. Group components by dependency level (from calibration.md parallel grouping)
  2. Spawn one synthesis sub-agent per group, reading only that group's summaries
  3. Each writes: .scratch/synthesise-group-{{N}}.md
  4. Spawn a final synthesis sub-agent that reads ONLY the group-level outputs
     (not raw summaries) to produce the cross-cutting synthesis files below

In both cases: do NOT load individual loop scratchpads. If a summary is unclear on
a specific point, read ONLY the single relevant loop file — never bulk-load.

Run the synthesis passes listed below.

ORCHESTRATOR: include ONLY the matching pass block based on calibration profile.
- Small: include PASS 1 only
- Medium: include PASS 1 and PASS 2
- Large: include PASS 1, PASS 2, and PASS 3

PASS 1 — INTEGRATION MAP
- How do components connect? Map every integration point:
  imports, shared data, API calls, file handoffs, message passing, shared DB tables
- Identify the dependency graph (what depends on what)
- Note any implicit dependencies (shared conventions, assumed file locations, env vars)
- Write: .scratch/synthesise-01-integration.md

PASS 2 — END-TO-END FLOWS
- Trace 3-5 key flows from trigger to completion
  (e.g., "user uploads file → processing → storage → notification")
- For each flow: which components are involved, in what order, what data transforms
- Identify the critical path and any bottlenecks
- Note scheduled/cron-driven flows separately from request-driven flows
- Write: .scratch/synthesise-02-flows.md

PASS 3 — ARCHITECTURE & RATIONALE
- Deployment topology: what runs where, how it's orchestrated
- Architectural patterns in use (and whether they're consistent)
- Data architecture: sources of truth, derived data, sync patterns
- Infrastructure: cloud services, CI/CD, monitoring, secrets management
- Infer the "why" — what constraints or goals shaped these choices
- Write: .scratch/synthesise-03-architecture.md

{{HARD_RULES}}
```

## Transition

Proceed to Phase 6: Diagram.
