# Phase 7: Write

Produce the actual L1-L4 documentation from accumulated understanding.
One sub-agent per component (for L2/L3/L4), plus a final sub-agent for L1.

## Principle

By this phase, the agent has genuine understanding from comprehension loops,
cross-component synthesis, and diagrams. Writing should be informed, not exploratory.
The agent READS scratchpad notes and diagrams — it should not need to re-explore source
code extensively (though it may verify specific details).

## Per-Component Sub-agent Task

CRITICAL: The orchestrator MUST loop through EVERY component in component-inventory.md
and spawn a write sub-agent for each one individually. Do NOT delegate "write all
components" to a single agent — it WILL skip components to optimise for completion.

Orchestrator write loop:
```
For each component in component-inventory.md (dependency order):
  1. Spawn write sub-agent for this component
  2. Verify L2/{{COMPONENT_SLUG}}.md, L3/{{COMPONENT_SLUG}}.md, L4/{{COMPONENT_SLUG}}.md exist
  3. Log completion to progress.md
  4. If failed after retry, log to skipped-components.md
  5. Next component

After ALL components: verify file count matches component count.
Then spawn overview + L1 sub-agents.
```

For small repos only (≤5 components): a single sub-agent may handle all components,
but the orchestrator must verify all output files exist before proceeding.

```
Write documentation for the {{COMPONENT_NAME}} component.

Read these inputs (do NOT re-explore the entire codebase):
- {{DOCS_DIR}}/builder/.scratch/comprehend-{{COMPONENT_SLUG}}-summary.md
- Relevant loop scratchpads: {{DOCS_DIR}}/builder/.scratch/comprehend-{{COMPONENT_SLUG}}-*.md
- {{DOCS_DIR}}/builder/.scratch/synthesise-*.md (for cross-component context)
- {{DOCS_DIR}}/diagrams/ (embed by copying .mmd source into ```mermaid fences.
  You MAY create additional inline diagrams for component-specific flows not
  covered by the diagram phase, but prefer embedding from diagrams/ when one exists.)
- Source code at {{COMPONENT_PATH}} (for verification only)

Write THREE files:

{{DOCS_DIR}}/L2/{{COMPONENT_SLUG}}.md
- Audience: BAs, PMs, non-engineers
- What this component does and why it exists
- Data flows with mermaid diagrams (embed from diagrams/ or create inline)
- Business rules and logic in plain language
- Dependencies on other components (in user terms)
- What "healthy" looks like, data volumes, scheduling
- 2-4 pages

{{DOCS_DIR}}/L3/{{COMPONENT_SLUG}}.md
- Audience: developers, maintainers
- Architecture and design decisions
- Code structure with file references (relative to repo root)
- Patterns used and why
- Configuration and environment setup
- How to extend or modify
- Error handling and gotchas
- Include code snippets where they clarify
- Embed relevant sequence/flow diagrams

{{DOCS_DIR}}/L4/{{COMPONENT_SLUG}}.md
- Audience: AI agents
- NO PROSE — headings, tables, and code blocks only
- File inventory: path | purpose | key exports
- Function signatures with parameters and return types
- Data schemas (tables, types, interfaces)
- Environment variables: name | required | default | description
- CLI flags and arguments
- Key constants and configuration values
- Dependency list: package | purpose | version constraint

{{HARD_RULES}}
```

## L2-Group Sub-agent Task (after all per-component writes)

If `{{DOCS_DIR}}/builder/specs/component-groups.md` exists and contains groups,
spawn one sub-agent per group. Skip if no groups or fewer than 2 groups.

CRITICAL: The orchestrator MUST loop through EVERY group in component-groups.md
and spawn a write sub-agent for each one individually.

Orchestrator group-write loop:
```
For each group in component-groups.md:
  1. Spawn group-write sub-agent
  2. Verify L2/groups/{{GROUP_SLUG}}.md exists
  3. Log completion to progress.md
  4. If failed after retry, log to skipped-components.md
  5. Next group

After ALL groups: spawn overview + L1 sub-agents (which now reference groups).
```

Per-group sub-agent task:

```
Write a module/subsystem overview for the "{{GROUP_NAME}}" group.

Read these inputs:
- {{DOCS_DIR}}/builder/specs/component-groups.md (find your group's entry and member list)
- L2 docs for each member component: {{DOCS_DIR}}/L2/{{MEMBER_SLUG}}.md (for each member)
- L3 docs for each member component: {{DOCS_DIR}}/L3/{{MEMBER_SLUG}}.md (for architecture context)
- Synthesis notes: {{DOCS_DIR}}/builder/.scratch/synthesise-*.md (for cross-component flows)
- Diagrams: {{DOCS_DIR}}/diagrams/ (embed relevant ones)

Write ONE file:

{{DOCS_DIR}}/L2/groups/{{GROUP_SLUG}}.md

Structure:
1. **Overview** — What this module/subsystem does as a unit (2-3 paragraphs).
   This is the "what is the Content Library?" answer.

2. **Component Map** — Table listing every package in the group:
   | Package | Type | Purpose |
   Categorise packages by role: API, UI, Database, Integration, Infrastructure,
   Contracts/Models, Search, etc.
   IMPORTANT: Link each package name to its detailed L2 doc using relative paths:
   `[cl_fun_api](../cl-fun-api.md)` — the group docs live in L2/groups/ so
   component docs are one level up (../).

3. **Internal Architecture** — Mermaid diagram showing how packages within the
   group relate to each other. Show data flow direction.

4. **Data Model** — Key entities/schemas owned by this group. What data does it
   manage? Include a simple ER-style diagram if the group owns >3 entity types.

5. **Integration Points** — How this group connects to other groups/modules:
   - Events published (Service Bus topics, etc.)
   - Events consumed
   - Contracts exposed to other modules
   - Shared data or cross-module queries

6. **Key Business Rules** — The important domain logic this group implements,
   in plain language. Pull from L2 component docs but elevate to group level.

7. **Operational Notes** — Deployment units, infrastructure dependencies,
   monitoring/health considerations for the group as a whole.

Audience: architects, tech leads, BAs, new team members who need to understand
what this module IS before diving into individual package docs.

Length: 3-6 pages. Use mermaid diagrams liberally.

{{HARD_RULES}}
```

## L2 Overview Sub-agent

After all components AND all groups, spawn one sub-agent for the system overview:

```
Write the system-level L2 overview.

Read: all synthesis scratchpads, all L2 group docs ({{DOCS_DIR}}/L2/groups/*.md),
all L2 component docs, diagrams/INDEX.md

Write {{DOCS_DIR}}/L2/overview.md:
- System-level data flow (embed architecture diagram)
- Module/group map: list each group with one-sentence purpose (link to group doc)
- How groups relate to each other (embed dependency graph at group level)
- End-to-end flows in plain language (referencing groups, not individual packages)
- Scheduling and orchestration overview
```

## L4 Overview Sub-agent

After all component L4 docs, spawn one sub-agent:

```
Write the L4 system overview for AI agent consumption.

For repos with ≤20 components: read all L4 component docs directly.
For repos with >20 components: read only the FIRST 20 LINES of each L4 file
(file inventory table) plus diagrams. The overview is a rollup, not a copy.

Also read: diagrams/dependencies.mmd, synthesis scratchpads

Write {{DOCS_DIR}}/L4/OVERVIEW.md:
- NO PROSE — headings, tables, and code blocks only
- Full file inventory across all components: path | component | purpose
- System dependency graph (embed from diagrams/)
- Cross-component data flow summary as table
- All environment variables across system: name | component | required | default
- All CLI entry points: command | component | description
- Shared conventions and patterns used across components
```

## L1 Executive Summary Sub-agent (LAST)

```
Write the executive summary. This is the LAST document generated.

Read: all L2 docs, synthesis scratchpads, interview notes

Write {{DOCS_DIR}}/L1/executive-summary.md:
- What the project does (1 paragraph)
- Why it exists / business value
- Key components (1 sentence each)
- Current status and maturity
- Key risks or dependencies
- 1 page maximum, no code, no jargon
```

## Transition

Proceed to Phase 8: Review.
