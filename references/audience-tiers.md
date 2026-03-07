# Audience Tiers

All tiers live in `{{DOCS_DIR}}/` within the target repo.

## L1 — Executive Summary
- **Audience:** Leadership, stakeholders, non-technical
- **Format:** `{{DOCS_DIR}}/L1/executive-summary.md` (single file, entire project)
- **Content:** What the project does, why it exists, business value, current status, key risks
- **Length:** 1 page max
- **Tone:** Plain language, no code, outcome-focused
- **Generated:** Last, after all components documented (requires full-system understanding)

## L2 — Business Analyst / Product
- **Audience:** BAs, PMs, new team members, non-engineering colleagues
- **Format:** `{{DOCS_DIR}}/L2/` directory, one file per major component
- **Content:** Data flows (mermaid diagrams), business rules, plain-language explanations,
  data volumes, scheduling, dependencies, what "healthy" looks like
- **Length:** 2-4 pages per component
- **Tone:** Semi-technical — explains "what" and "why" without implementation details

## L3 — Developer
- **Audience:** Engineers, handover recipients, future maintainers
- **Format:** `{{DOCS_DIR}}/L3/` directory, one file per component
- **Content:** Architecture decisions, code structure, patterns used, environment setup,
  how to add/extend, gotchas, error handling, retry logic, schema evolution
- **Length:** Detailed, no limit
- **Tone:** Technical, includes code snippets and file references
- **Key test:** Could a new developer get productive from L3 alone?

## L4 — Model Context
- **Audience:** AI agents (Claude Code, OpenClaw, Copilot, Cursor)
- **Format:** `{{DOCS_DIR}}/L4/` directory, one file per component, plus `OVERVIEW.md`
- **Content:** Structured file inventory with paths, function signatures, data schemas,
  env vars, CLI flags, conventions, dependency graph
- **Length:** Compact, context-window-efficient
- **Tone:** Structured, no prose — headings, tables, code blocks only
- **Key test:** A model reading L4 + source should be able to make changes without exploring the codebase

## Formatting Rules

- Mermaid for all diagrams (L2 and L3)
- Tables for structured data (env vars, CLI flags, schemas)
- L4 files: no paragraphs — only headings, tables, and code blocks
- All file paths relative to repo root
- Mark uncertainty with `<!-- UNVERIFIED -->`
