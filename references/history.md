# History Mode

Generate a retrospective changelog from git commit history. Run with `deep-docs history`.

## Purpose

For established repos, create a narrative of how the project evolved — not a git log,
but a meaningful story of architectural decisions, feature additions, and pivots.

## Options

Parse from user's natural language request. Examples:
- "document the last 6 months" → `--since` 6 months ago
- "changelog for last 50 commits" → `--last 50`
- "detailed history" → `--granularity detailed`

If ambiguous, ask. `--since` and `--last` are mutually exclusive — if both implied, ask which.

- `--since YYYY-MM-DD` — start date (default: first commit)
- `--last N` — only last N commits
- `--granularity major|detailed` — (default: major)
  - **major**: Only significant epochs (new components, architectural shifts, major features).
    Typically 5-15 entries for a mature repo. Epoch detection is aggressive — small changes
    get folded into neighbouring epochs.
  - **detailed**: Every meaningful period of development gets an entry. Sub-divide large epochs
    into feature-level entries. Include minor but noteworthy changes (new utilities, config
    changes, dependency upgrades with impact). Typically 2-5× more entries than major.

## Phases

### 1. Harvest

Single sub-agent:

```
Analyse git history for {{REPO_PATH}}.

Collect:
- All commits (or filtered by --since/--last)
- For each: hash, date, author, message, files changed, insertions/deletions

Auto-filter OUT:
- Merge commits (unless they represent significant branch merges)
- Dependency-only updates (package-lock.json, yarn.lock, requirements.txt ONLY changes)
- Formatting/linting-only commits (detected by: only whitespace/style changes)
- CI config tweaks (unless substantial pipeline changes)
- .gitignore updates

Write: {{DOCS_DIR}}/builder/.scratch/history-harvest.md
- Filtered commit list with: date, message summary, files changed, change magnitude
```

### 2. Epoch Detection

```
Read the harvest data. Identify natural epochs — periods of coherent development
focus separated by shifts in direction.

Signals for epoch boundaries:
- New top-level directories appearing (new component/service)
- Large refactors (many files renamed/moved in one commit)
- Significant dependency changes (new framework, major version bumps)
- Gaps in commit activity (>2 weeks)
- Shifts in which directories are being changed
- Explicit version tags or release commits

For each epoch:
- Date range
- Descriptive name (inferred from changes, not commit messages)
- Key commits that define the epoch
- What was the development focus

Write: {{DOCS_DIR}}/builder/.scratch/history-epochs.md
```

### 3. Comprehend Per Epoch

For each epoch (or the most significant ones if `--granularity major`):

```
Study epoch "{{EPOCH_NAME}}" ({{DATE_RANGE}}).

Read the actual diffs for key commits in this epoch (not just commit messages).
Run these structured loops:

LOOP 1 — INVENTORY CHANGES
- What files were added, removed, renamed, moved?
- What new directories/components appeared?
- What dependencies changed?

LOOP 2 — SEMANTIC CHANGES
- What do the code changes actually DO? (read diffs, not just filenames)
- What features were built, what bugs were fixed, what was refactored?
- What design decisions are visible in the code?

LOOP 3 — INTEGRATION IMPACT
- Did component boundaries change?
- Did data flows change?
- Did deployment or infrastructure change?
- How did this epoch change the system's shape?

Write: {{DOCS_DIR}}/builder/.scratch/history-epoch-{{N}}-{{SLUG}}.md
```

### 4. Write Changelog

```
Synthesise all epoch notes into a narrative changelog.

Read: all history epoch scratchpads

Write {{DOCS_DIR}}/CHANGELOG.md (or append if exists):

# Project Evolution

## {{Epoch Name}} ({{date range}})
- 2-5 sentences describing what happened and why
- Key changes as bullet points
- Notable decisions or pivots

Order: chronological (earliest first)
Tone: factual narrative, not commit messages
Length: proportional to significance (major epochs get more space)

Do NOT include:
- Individual commit hashes (unless truly landmark)
- Routine maintenance or dependency updates
- Speculation about intent — only what the code shows
```

### 5. Review

Changelog review is DIFFERENT from init mode review. Spawn a review sub-agent:

```
Review the generated changelog for accuracy against git history.

Read:
- {{DOCS_DIR}}/CHANGELOG.md
- Git log for the covered date range

Verify:
1. DATE ACCURACY — epoch date ranges match actual commit dates
2. ATTRIBUTION — changes attributed to the correct epoch
3. COMPLETENESS — no significant epochs omitted (compare against git activity)
4. NARRATIVE ACCURACY — descriptions match what the diffs actually show
5. NO SPECULATION — changelog states facts, not inferred intent

Do NOT check: file path existence, env var accuracy, function signatures
(those are init review concerns, not changelog concerns).

Fix any inaccuracies. Output REVIEW_CLEAN or REVIEW_ISSUES: N unresolved.
```

Loop up to 3 iterations, same as init mode.

Note: history mode does NOT update `last-run.md` — it is a read-only analysis
that produces a changelog without affecting future update runs.
