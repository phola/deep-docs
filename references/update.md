# Update Mode

Incremental documentation update after code changes. Run with `deep-docs update`.

## Prerequisites

- Previous `deep-docs init` run exists (docs directory with builder/ specs)
- Git history available for diff detection
- Source working tree clean outside the documentation output directory, so `HEAD` is reproducible

## Run identity and resume safety

Before discovery, the orchestrator resolves one immutable Git range:

1. Prefer the exact `commit:` recorded in `builder/last-run.md`.
2. For legacy date-only records, use the last commit at or before `date:`.
3. Resolve and retain the target `HEAD` commit, then bind scratch state to the immutable
   `baseline..target` range in `builder/.scratch/update-run-state`.

An exact rerun of the same range resumes current update summaries and reviews. A different
range invalidates `update-diff.md`, `git-diff-raw.md`, update comprehension summaries,
inventory-delta state, and scoped review state before agents run. Inventory/group snapshots belong
to the last successful baseline, not the target: changing the target after a partial run restores
those snapshots and recomputes the delta without losing removals. A successful baseline change
retires the old snapshots. Baseline advancement happens
only after review, navigation and package validation pass. An invalid recorded commit, a baseline
that is not an ancestor of the target, a missing legacy baseline, or movement/dirtying of the source
tree during execution fails the update rather than widening or changing the comparison.

## Phases

### 1. Inventory Reconciliation

Re-enumerate current components before diff discovery. Compare the refreshed inventory with a
preserved copy of the prior inventory by source `Path`:

- Preserve established slugs for every surviving path and unique same-name path move.
- Derive deterministic hyphenated slugs only for new paths; the root package at `.` uses
  `repository-root`. Apply any reconciled slug changes to group and standalone membership
  references in the same refresh, and reject malformed slugs before downstream file writes.
- Reject duplicate slugs, duplicate paths and source paths that do not exist.
- Produce `builder/.scratch/inventory-delta.md` with explicit `NEW`, `REMOVED`, and path-move
  `STRUCTURAL` rows. A move is one structural identity, not contradictory new/removed rows.
- Reconcile `component-groups.md`; each current component occurs exactly once in a group or an
  explicit standalone table (`## Standalone Components` or the legacy `## Singleton Modules`,
  with columns `Component | Path | Reason`). Do not invent singleton groups. An empty group table
  with the note "No component groups detected — all components are standalone." is valid.
  Unknown/duplicate group or standalone members fail validation. One-group specifications are
  validated and regenerated, and stale group pages absent from the specification are removed.

The diff result must include every inventory-delta row with the same classification. Missing or
misclassified additions/removals/moves fail the run rather than silently reducing phase scope.

### 2. Diff Discovery

Single sub-agent:

```
Compare the current source code against existing documentation.

Read:
- Refreshed and prior component inventories plus their mechanical delta
- Git diff from the exact baseline commit recorded in `builder/last-run.md`

Produce {{DOCS_DIR}}/builder/.scratch/update-diff.md:

For each change found, classify:
- NEW: files/components that exist in source but not in docs
- MODIFIED: source files whose behaviour no longer matches L4 description
- REMOVED: documented items that no longer exist in source
- STRUCTURAL: an existing component's Path moved, recorded as STRUCTURAL in the inventory delta
- UNCHANGED: components where docs still match source

For MODIFIED items, note specifically what changed (not just "file was modified" —
what functions, schemas, behaviours differ).

The inventory delta exclusively authorises NEW, REMOVED and STRUCTURAL rows. File moves
between existing components whose Path values remain unchanged are MODIFIED for each affected
component, even when exports or helpers cross package boundaries. Describe those transfers in
the change detail; do not invent additional STRUCTURAL rows from file-level Git renames.

List affected components in dependency order.

If NO changes detected (all components UNCHANGED): output NO_CHANGES_DETECTED.
```

The orchestrator validates the complete affected set: classifications must be possible against the
old/current inventories, each delta row must have exactly one matching affected row, and unknown,
duplicate, conflicting, or extra structural classifications are rejected. `NO_CHANGES_DETECTED`
is accepted only as the exact final non-empty line when both affected and delta sets are empty.
Every diff invocation removes the old report first and must exit successfully; a failed agent
cannot be rescued by stale output. Failure is distinct from the no-change control-flow result.

A no-change result still requires every current component tier, required system/group pages,
complete navigation and a strict MkDocs build when available. Missing tiers fail closed;
missing/stale navigation is regenerated through the normal package phase. This validates output
completeness, **not a new semantic review**, and does not advance `last-run.md`.

### 3. Targeted Comprehension

Re-run comprehension loops ONLY for affected components.
Read the calibration profile from `{{DOCS_DIR}}/builder/calibration.md` (written during
init). Re-run calibration if any of:
- New components detected that weren't in original inventory
- Total file count increased by >50% since last run
- Component count changed by ≥3
Otherwise, use existing calibration.

Read previous scratchpad notes for context but produce fresh notes for affected components.

If integration points changed, also re-run synthesis passes.

### 4. Update Docs

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
Regenerate group pages from the refreshed group membership even when an older group file already
exists. A removed component is processed from the inventory delta because it no longer appears in
the current inventory loop.

### 5. Changelog

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

### 6. Review Loop

See [review.md](review.md). Update mode reviews exactly the current affected, non-removed
components; standalone review uses the full current inventory. Review files are bound to the current
run, source target, scope, and hashes of the component's L2/L3/L4 inputs. Same-range documentation
changes invalidate only the affected clean result. The run is clean only when every required
component has all L2/L3/L4 files and an exact terminal `COMPONENT_CLEAN` marker in the review file.
Missing files, missing markers, malformed markers and unresolved markers all fail closed.
Aggregation must also produce its own exact completion marker; agent stdout cannot repair a
malformed review file.

A validated removal-only update has zero current affected components, so it instead runs a
system-level removal review of current inventory/groups, surviving tiers, overviews, diagrams
and cross-references. It requires exactly one terminal `SYSTEM_REVIEW_CLEAN` in
`builder/.scratch/review-system.md`. Failed agents, unresolved/contradictory/malformed outcomes,
or changed reviewed inputs fail closed. Other empty review scopes remain invalid. Packaging
and removed-page/navigation checks still run before recording; no nonexistent component review
is counted as clean.

### 7. Package and Navigation

Regenerate `index.md` and `mkdocs.yml` after documentation updates. Mechanically verify that every
generated Markdown page appears specifically under `nav` and every `nav` Markdown target exists. If
MkDocs is installed, `mkdocs build --strict` must succeed from a fresh `site/` directory.
The configuration uses `docs_dir: docs` and `site_dir: site`. A managed relative-symlink publishing
view exposes current root documents without moving them or including builder/scratch/Git state;
conflicting user-owned entries block packaging rather than being overwritten.

### 8. Record

Write `{{DOCS_DIR}}/builder/last-run.md` in this exact format:

```markdown
date: 2026-03-07T07:30:00Z
commit: 0123456789abcdef0123456789abcdef01234567
mode: update
profile: medium
components: auth, api, database, shared
```

Fields: ISO 8601 date, exact source commit, mode (init/update), calibration profile used,
and comma-separated component list. The exact commit scopes the next update; `date` remains a
compatibility fallback for records written by older versions.
