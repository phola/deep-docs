# Update Mode

Incremental documentation update after code changes. Run with `deep-docs update`.

## Prerequisites

- Previous `deep-docs init` run exists (docs directory with builder/ specs)
- Git history available for diff detection

## Phases

### 1. Diff Discovery

Single sub-agent:

```
Compare the current source code against existing documentation.

Read:
- {{DOCS_DIR}}/builder/specs/component-inventory.md (what was documented)
- All L4 docs in {{DOCS_DIR}}/L4/ (most precise inventory of what was documented)
- Git diff since last documentation run (check {{DOCS_DIR}}/builder/last-run.md for date)
  If no last-run.md exists, compare docs against current source directly.

Produce {{DOCS_DIR}}/builder/.scratch/update-diff.md:

For each change found, classify:
- NEW: files/components that exist in source but not in docs
- MODIFIED: source files whose behaviour no longer matches L4 description
- REMOVED: documented items that no longer exist in source
- STRUCTURAL: renames, moves, reorganisation
- UNCHANGED: components where docs still match source

For MODIFIED items, note specifically what changed (not just "file was modified" —
what functions, schemas, behaviours differ).

List affected components in dependency order.

If NO changes detected (all components UNCHANGED): output NO_CHANGES_DETECTED.
```

If diff discovery outputs `NO_CHANGES_DETECTED`, inform the user that docs are up to date
and exit without spawning further sub-agents.

### 2. Targeted Comprehension

Re-run comprehension loops ONLY for affected components.
Read the calibration profile from `{{DOCS_DIR}}/builder/calibration.md` (written during
init). Re-run calibration if any of:
- New components detected that weren't in original inventory
- Total file count increased by >50% since last run
- Component count changed by ≥3
Otherwise, use existing calibration.

Read previous scratchpad notes for context but produce fresh notes for affected components.

If integration points changed, also re-run synthesis passes.

### 3. Update Docs

Per affected component, spawn a sub-agent:

```
Update documentation for {{COMPONENT_NAME}} based on detected changes.

Read:
- {{DOCS_DIR}}/builder/.scratch/update-diff.md (what changed)
- Fresh comprehension scratchpad notes
- Existing L2/L3/L4 docs for this component

SURGICALLY update the affected sections. Do NOT rewrite from scratch.
Preserve sections marked with <!-- HUMAN --> ... <!-- /HUMAN --> verbatim —
these are human-authored additions that must not be overwritten.
All other content is assumed to be deep-docs generated and may be updated freely.

For NEW components: write full L2/L3/L4 as in init mode.
For REMOVED components: delete the doc files, update cross-references.
For MODIFIED: update only the changed sections, note what was updated.
For STRUCTURAL: update paths and references, preserve content.
```

Regenerate affected diagrams. Update L2 overview and L1 if system-level changes.

### 4. Changelog

Single sub-agent with comprehension loops:

```
Generate a changelog entry for this documentation update.

Read:
- {{DOCS_DIR}}/builder/.scratch/update-diff.md
- All updated doc files (check git diff of docs/)
- Fresh synthesis notes if available

Comprehension loops for changelog:
1. CATALOGUE — raw list of what changed in code and docs
2. SEMANTICS — what do the changes MEAN (not just "file X modified")
3. IMPACT — what else is affected, what should users/developers know
4. WRITE — produce the changelog entry

Append to {{DOCS_DIR}}/CHANGELOG.md (create if first update):

## {{DATE}}

### Code Changes Detected
- Bullet list of meaningful source changes (not every file, grouped logically)

### Documentation Updates
- What was added/updated/removed in docs
- Which diagrams were regenerated

### Impact Summary
- 1-2 sentences: what this means for users of the codebase
```

### 5. Review Loop

Same as init mode review (see [review.md](review.md)). Verify all updated docs.

### 6. Record

Write `{{DOCS_DIR}}/builder/last-run.md` in this exact format:

```markdown
date: 2026-03-07T07:30:00Z
mode: update
profile: medium
components: auth, api, database, shared
```

Fields: ISO 8601 date, mode (init/update), calibration profile used,
comma-separated component list. The diff discovery phase parses `date` to
scope git history.
