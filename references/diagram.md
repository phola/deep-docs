# Phase 6: Diagram

Generate all visual artefacts from accumulated understanding. Single sub-agent.

## Purpose

Diagrams are generated as a dedicated phase (not inline during writing) because:
1. They require cross-component understanding from the synthesise phase
2. Consistency across diagrams matters (same naming, same abstraction level)
3. The write phase can reference existing diagrams rather than creating them ad-hoc

## Sub-agent Task

```
Generate Mermaid diagrams for the codebase documentation. Read all synthesis and
comprehension scratchpad notes to inform diagram creation.

Read:
- {{DOCS_DIR}}/builder/.scratch/synthesise-*.md (all synthesis notes)
- {{DOCS_DIR}}/builder/specs/component-inventory.md
- Component summary scratchpads as needed

Generate these diagrams as standalone files in {{DOCS_DIR}}/diagrams/.
YOU determine filenames — the {{FLOW_SLUG}} and {{DOMAIN_SLUG}} placeholders below
show the naming convention (lowercase, hyphenated). Choose slugs based on flow/domain
names found in synthesis notes.

1. ARCHITECTURE DIAGRAM (architecture.mmd)
   - Deployment topology: what runs where
   - Services, databases, file stores, external APIs
   - Infrastructure boundaries (cloud regions, VPCs, containers)
   - Use: flowchart or C4-style diagram

2. COMPONENT DEPENDENCY GRAPH (dependencies.mmd)
   - All components and their dependency relationships
   - Distinguish: hard dependency, optional, dev-only
   - Use: flowchart with directional arrows

3. DATA FLOW DIAGRAMS (dataflow-{{FLOW_SLUG}}.mmd)
   - One per major end-to-end flow identified in synthesis
   - Show: data source → transforms → destination
   - Include data formats at each stage
   - Use: flowchart with data annotations

4. SCHEMA / ERD DIAGRAMS (schema-{{DOMAIN_SLUG}}.mmd)
   - Data models and their relationships
   - Key fields, types, cardinality
   - One per data domain if the repo has multiple
   - Use: erDiagram

5. SEQUENCE DIAGRAMS (sequence-{{FLOW_SLUG}}.mmd)
   - Key execution flows showing component interactions over time
   - Include: triggers, API calls, data transforms, responses
   - Focus on the 2-3 most important flows
   - Use: sequenceDiagram

Rules:
- All diagrams in Mermaid syntax
- Check for common Mermaid errors: unclosed brackets, invalid node IDs,
  duplicate node names, missing arrow syntax, reserved word conflicts (end, graph)
- Use consistent naming across all diagrams (same component names everywhere)
- Keep diagrams readable: max ~15 nodes per diagram, split if larger
- Add a brief title comment at top of each .mmd file

Also write {{DOCS_DIR}}/diagrams/INDEX.md listing all diagrams with one-line descriptions.

EMBEDDING STRATEGY:
- .mmd files in diagrams/ are the CANONICAL source for each diagram
- When write-phase docs need a diagram, COPY the mermaid source into a fenced
  ```mermaid code block in the markdown file
- This ensures diagrams render on GitHub, GitBook, Docusaurus, and most renderers
- Keep the .mmd files as canonical — if a diagram needs updating, update the .mmd
  and re-embed

{{HARD_RULES}}
```

## Output Structure

```
{{DOCS_DIR}}/diagrams/
├── INDEX.md
├── architecture.mmd
├── dependencies.mmd
├── dataflow-{{FLOW_SLUG}}.mmd
├── schema-{{DOMAIN_SLUG}}.mmd
└── sequence-{{FLOW_SLUG}}.mmd
```

## Transition

Proceed to Phase 7: Write.
