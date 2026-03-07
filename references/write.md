# Phase 7: Write

Produce the actual L1-L4 documentation from accumulated understanding.
One sub-agent per component (for L2/L3/L4), plus a final sub-agent for L1.

## Principle

By this phase, the agent has genuine understanding from comprehension loops,
cross-component synthesis, and diagrams. Writing should be informed, not exploratory.
The agent READS scratchpad notes and diagrams — it should not need to re-explore source
code extensively (though it may verify specific details).

## Per-Component Sub-agent Task

Spawn one per component (dependency order). For small repos, one sub-agent for all.

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

## L2 Overview Sub-agent

After all components, spawn one sub-agent for the system overview:

```
Write the system-level L2 overview.

Read: all synthesis scratchpads, all L2 component docs, diagrams/INDEX.md

Write {{DOCS_DIR}}/L2/overview.md:
- System-level data flow (embed architecture diagram)
- How components relate (embed dependency graph)
- End-to-end flows in plain language
- Scheduling and orchestration overview
```

## L4 Overview Sub-agent

After all component L4 docs, spawn one sub-agent:

```
Write the L4 system overview for AI agent consumption.

Read: all L4 component docs, diagrams/dependencies.mmd, synthesis scratchpads

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
