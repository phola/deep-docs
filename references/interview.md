# Phase 1: Interview

Interactive phase — no sub-agents. The orchestrating agent asks questions directly.

## Purpose

Gather context that can't be inferred from code alone: purpose, audience, scope boundaries,
existing documentation, and output preferences.

## Questions

Ask these conversationally, not as a numbered form. Adapt based on answers.
Skip questions the user has already answered in their initial request.

### Required

1. **Repo path** — "Where's the repo?" (may already be obvious from context)
2. **Context** — "Any context that would help me understand the purpose? Even a rough
   sentence is useful, but the discover phase will figure out the details."
   - Don't press for a polished answer — user might not have one
3. **Audience** — "Who needs these docs? Just developers, or also stakeholders/PMs/AI agents?"
   - Determines which L-tiers to generate (dev-only might skip L1/L2)
4. **Exclusions** — "Anything to skip? (vendored deps, generated code, test fixtures, legacy scripts...)"

### Optional (ask if relevant)

5. **Output location** — "Where should docs go? Default is `docs/` in the repo root.
   Can also be a separate repo — useful for monorepos, centralised docs, or keeping
   doc changes out of source CI."
   - If separate repo: capture both `{{REPO_PATH}}` (source) and `{{DOCS_REPO_PATH}}` (output)
   - `{{DOCS_DIR}}` resolves to `{{DOCS_REPO_PATH}}/` root if separate, or `{{REPO_PATH}}/docs/` if same
6. **Existing docs** — "Any existing documentation to preserve or incorporate?"
7. **Key concepts** — "Any domain-specific terms or concepts I should know about?"
8. **Sensitive areas** — "Anything I should be careful about? (internal APIs, credentials patterns, etc.)"
9. **Rendering target** — "Where will these docs be read? (GitHub, GitBook, Docusaurus, Confluence, local...)"
   - Affects mermaid strategy and linking conventions
10. **Monorepo** — If discover detects multiple top-level services, ask:
    "This looks like a monorepo — should I document all services or specific ones?"

## Output

Create the directory structure (orchestrator executes, not the user):
```
mkdir -p {{DOCS_DIR}}/builder/specs
mkdir -p {{DOCS_DIR}}/builder/.scratch
mkdir -p {{DOCS_DIR}}/L1
mkdir -p {{DOCS_DIR}}/L2
mkdir -p {{DOCS_DIR}}/L3
mkdir -p {{DOCS_DIR}}/L4
mkdir -p {{DOCS_DIR}}/diagrams
```

Capture answers as `{{DOCS_DIR}}/builder/interview-notes.md` — a simple bullet list.
This file is read by all subsequent phases.

## Transition

After interview, proceed to Phase 2: Discover. Inform the user:
"I'll explore the repo now and generate a component inventory for you to review."
