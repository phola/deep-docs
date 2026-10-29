# Phase 8: Review

Verify all documentation against source code. Fix inaccuracies. Repeat until clean.

## Setup (orchestrator, before spawning any review sub-agents)

Build an explicit pipe-delimited review scope. Update mode uses current affected, non-removed
components; standalone review and init use the full current inventory. Bind the scope to the active
run identity before accepting any prior review artifact.

## Removal-only updates

Zero current affected components is valid only for a mechanically validated, nonempty set of
`REMOVED` changes. Run a dedicated system-level review (`review-system.md`), covering deleted
pages, surviving tiers, group membership, overviews, diagrams and stale cross-references.
Require a successful agent exit and exactly one final `SYSTEM_REVIEW_CLEAN` marker; the alternative
`SYSTEM_REVIEW_ISSUES: N unresolved`, missing or contradictory markers all block completion.
Fingerprint the reviewed content and recheck it after packaging. `REVIEW.md` must state that
zero current components were reviewed; do not fabricate component-clean counts.

A source no-op checks complete inherited outputs/navigation and builds strictly when MkDocs is
available. It neither claims a fresh semantic review nor advances the source baseline.

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

Read these component documents:
- {{DOCS_DIR}}/L2/{{COMPONENT_SLUG}}.md
- {{DOCS_DIR}}/L3/{{COMPONENT_SLUG}}.md
- {{DOCS_DIR}}/L4/{{COMPONENT_SLUG}}.md
- Relevant diagrams from {{DOCS_DIR}}/diagrams/ (only those referencing this component)
- Begin source inspection at {{REPO_PATH}}/{{COMPONENT_PATH}}.

Source reads are permitted throughout {{REPO_PATH}}, but must be targeted to this component's
documented claims: follow specific imports, schemas, root configuration, consumers and infrastructure
wiring. Read-only Git inspection is permitted. Do not treat another package in the same repository
as forbidden evidence. Writes remain limited to the three component pages and their review artifact.

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
- First resolve repository-answerable questions through targeted dependency/configuration reads.
- Remove unsupported generated assertions or replace them with the actual source-confirmed behaviour
  and a precise evidence boundary. Report accurately labelled unknown external context separately as
  an evidence limitation, not automatically as a factual error.
- Missing runtime execution or an optional automated check is not itself a documentation error;
  never imply those checks ran. Do not install dependencies, access live services or bypass approvals.
- A marker alone does not resolve a material unsupported claim. Preserve HUMAN blocks verbatim;
  material unsupported HUMAN assertions remain blockers rather than being edited or waived.
- Count remaining factual errors, misleading/incomplete material claims and verification gaps in
  those claims as unresolved. Never obtain clean status by relabelling such an issue as a limitation.
- For nits: fix if trivial, skip if subjective

After all fixes, write {{DOCS_DIR}}/builder/.scratch/review-{{COMPONENT_SLUG}}.md:
- Table: | File | Issue Found | Severity | Action Taken |
- Severity: error (factually wrong), warning (misleading/incomplete), nit (style)
- Files with no issues: list as ✅ verified
- Count: errors fixed, warnings fixed, remaining unverified items

The **final non-empty line** must be exactly one of:

- `COMPONENT_CLEAN`
- `COMPONENT_ISSUES: N unresolved` where `N` is an integer

Note: the orchestrator reads this exact final line to determine per-component status and
appends progress.md entries automatically — sub-agents do NOT need to write to progress.md.
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

After `REVIEW.md` is complete, write the orchestrator-provided aggregation marker file with
`REVIEW_AGGREGATE_COMPLETE` as its exact final non-empty line.

Note: failed aggregation, missing `REVIEW.md`, or a missing/malformed completion marker fails the
phase even if all component reviews are clean.
Do NOT write to progress.md — the orchestrator handles that.
```

## Loop Logic

The orchestrator writes a pipe-delimited review scope for the current run. Init and standalone
review use the current inventory; update reviews affected, non-removed components only. A clean
review file is reusable only when its review-state identity matches the current source range and
scope **and** its recorded fingerprint matches the current source target plus L2/L3/L4 contents.
Files from previous runs are invalidated for scoped slugs; same-range doc edits invalidate the
changed component's clean review. Agent stdout never repairs a missing or malformed file marker.

`REVIEW_CLEAN` is emitted only when `clean == required scope size`. Missing files, a missing review
file, a final line that does not match the exact marker grammar, or an unresolved marker all remain
non-clean and are retried. After three incomplete iterations the review phase returns non-zero and
the orchestrator must not write `last-run.md`.

Each iteration reruns every unresolved, stale, missing, or malformed component review. Already clean
reviews are skipped only when their fingerprints still match. The aggregate report is rebuilt from
the exact current scope after component review. There is no shared known-issues artifact whose stale
contents can contaminate a later iteration or run.

## User Touchpoint

Present final REVIEW.md to user. Show:
- How many review iterations ran
- Total issues found and fixed
- Any remaining `<!-- UNVERIFIED -->` items
- Ask: "Happy with these docs, or want me to dig deeper on anything?"

## Cleanup

After user approval:
- Scratchpad files in `.scratch/` may be retained for resume, but update/review artifacts are reused
  only after run/scope/fingerprint validation
- `builder/` directory contains all specs, plans, and scratchpad for future update runs
- Write `{{DOCS_DIR}}/builder/last-run.md` (enables future update runs):

```markdown
date: {{ISO_8601_TIMESTAMP}}
commit: {{EXACT_SOURCE_COMMIT}}
mode: init
profile: {{PROFILE}}
components: {{COMMA_SEPARATED_COMPONENT_SLUGS}}
```
