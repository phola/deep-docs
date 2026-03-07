# Phase 8: Review

Verify all documentation against source code. Fix inaccuracies. Repeat until clean.

## Setup (orchestrator, before spawning any review sub-agents)

Create an empty file: `{{DOCS_DIR}}/builder/.scratch/review-known-issues.md`

## Principle

The review loop is the quality gate. It runs repeatedly until no errors remain.
It fixes DOCUMENTATION only — never source code.

## Structure

Review is split into per-component sub-agents plus a final aggregation sub-agent.
This avoids loading all docs into a single context.

### Per-Component Review Sub-agent

Spawn one per component (matching the write phase):

```
Review documentation for {{COMPONENT_NAME}} against the actual source code.

Read ONLY these files:
- {{DOCS_DIR}}/L2/{{COMPONENT_SLUG}}.md
- {{DOCS_DIR}}/L3/{{COMPONENT_SLUG}}.md
- {{DOCS_DIR}}/L4/{{COMPONENT_SLUG}}.md
- Relevant diagrams from {{DOCS_DIR}}/diagrams/ (only those referencing this component)
- Source code at {{COMPONENT_PATH}}

For EACH documentation file, verify against source at {{REPO_PATH}}:

1. PATH CHECK
   - Every file path referenced in docs must exist in the repo
   - Every directory referenced must exist
   - Flag any dead references

2. ACCURACY CHECK — read the actual source files
   - Function signatures match?
   - Env var names and defaults correct?
   - CLI flags and arguments accurate?
   - Described behaviour matches implementation?
   - Data schemas match actual types/tables?
   - Schedule times / cron expressions correct?

3. COMPLETENESS CHECK
   - Compare against component-inventory.md: any components missing docs?
   - Any significant source files not mentioned in L4?
   - All tiers present for each component?

4. DIAGRAM CHECK
   - Mermaid syntax valid?
   - Diagrams match actual architecture/flows?
   - Consistent naming across diagrams?

5. CONSISTENCY CHECK
   - Same component called the same name everywhere?
   - No contradictions between L2/L3/L4 descriptions?
   - Cross-references between docs are valid?

ACTIONS:
- For errors and warnings: FIX the documentation immediately (not the source code)
- For uncertainties that can't be resolved: add <!-- UNVERIFIED -->
- For nits: fix if trivial, skip if subjective

After all fixes, write {{DOCS_DIR}}/builder/.scratch/review-{{COMPONENT_SLUG}}.md:
- Table: | File | Issue Found | Severity | Action Taken |
- Severity: error (factually wrong), warning (misleading/incomplete), nit (style)
- Files with no issues: list as ✅ verified
- Count: errors fixed, warnings fixed, remaining unverified items

Output: COMPONENT_CLEAN or COMPONENT_ISSUES: N unresolved
```

### Aggregation Review Sub-agent

After all per-component reviews, spawn one aggregation sub-agent:

```
Review cross-cutting documentation and aggregate component review results.

Read:
- {{DOCS_DIR}}/L1/executive-summary.md
- {{DOCS_DIR}}/L2/overview.md
- {{DOCS_DIR}}/L4/OVERVIEW.md
- {{DOCS_DIR}}/diagrams/INDEX.md + all .mmd files
- Per-component review files from {{DOCS_DIR}}/builder/.scratch/review-*.md:
  1. Check each file's final line for COMPONENT_CLEAN or COMPONENT_ISSUES
  2. Read ONLY files that output COMPONENT_ISSUES
  3. Skip files that are entirely ✅ verified

Check:
1. CONSISTENCY — same component names everywhere, no contradictions between L2/L3/L4
2. CROSS-REFERENCES — links between docs are valid
3. DIAGRAMS — mermaid syntax valid, consistent naming, match actual architecture
4. L1 ACCURACY — executive summary consistent with component docs
5. L4 OVERVIEW — dependency graph complete, all components listed

Fix any issues found in the docs (not source). Then write {{DOCS_DIR}}/REVIEW.md:
- Summary: overall quality assessment (1 paragraph)
- Aggregated table from all component reviews + cross-cutting issues
- Total counts: errors fixed, warnings fixed, remaining unverified

If ALL clean: output REVIEW_CLEAN
If issues remain: output REVIEW_ISSUES: N unresolved
```

## Loop Logic

**Known-issues tracking across iterations:**
- Orchestrator creates empty `{{DOCS_DIR}}/builder/.scratch/review-known-issues.md` before
  the first review iteration.
- Per-component sub-agents write to their OWN `review-{{COMPONENT_SLUG}}.md` only (no shared file).
- The aggregation sub-agent reads all per-component files and writes a consolidated
  `review-known-issues.md` at the end of each iteration.
- Next iteration's per-component sub-agents read `review-known-issues.md` and SKIP
  already-resolved items — focus only on:
  - Issues flagged in the previous iteration's output
  - Items marked `<!-- UNVERIFIED -->` that might now be resolvable
  - Never strip an `<!-- UNVERIFIED -->` tag unless you can now confirm the fact from source

The orchestrating agent checks the aggregation sub-agent output:
- `REVIEW_CLEAN` → done, proceed to user approval
- `REVIEW_ISSUES` → re-spawn review (up to 3 iterations)
- After 3 iterations with remaining issues → present REVIEW.md to user with unresolved items

## User Touchpoint

Present final REVIEW.md to user. Show:
- How many review iterations ran
- Total issues found and fixed
- Any remaining `<!-- UNVERIFIED -->` items
- Ask: "Happy with these docs, or want me to dig deeper on anything?"

## Cleanup

After user approval:
- Scratchpad files in `.scratch/` are kept but noted as reference-only
- `builder/` directory contains all specs, plans, and scratchpad for future update runs
- Write `{{DOCS_DIR}}/builder/last-run.md` (enables future update runs):

```markdown
date: {{ISO_8601_TIMESTAMP}}
mode: init
profile: {{PROFILE}}
components: {{COMMA_SEPARATED_COMPONENT_SLUGS}}
```
