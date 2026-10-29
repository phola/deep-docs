#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1': ${3:-}"; }
assert_file() { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_no_file() { [[ ! -e "$1" ]] || fail "unexpected file: $1"; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
assert_success() { "$@" || fail "command failed: $*"; }
assert_failure() { if "$@"; then fail "command unexpectedly succeeded: $*"; fi; }

SRC="$TMP/source"
DOCS="$TMP/docs"
mkdir -p "$SRC" "$DOCS/builder/specs" "$DOCS/builder/.scratch"
git -C "$SRC" init -q
git -C "$SRC" config user.email test@example.com
git -C "$SRC" config user.name Test
printf 'one\n' > "$SRC/file.txt"
git -C "$SRC" add file.txt
GIT_AUTHOR_DATE='2026-01-01T10:00:00Z' GIT_COMMITTER_DATE='2026-01-01T10:00:00Z' git -C "$SRC" commit -qm one
C1="$(git -C "$SRC" rev-parse HEAD)"
printf 'two\n' >> "$SRC/file.txt"
git -C "$SRC" add file.txt
GIT_AUTHOR_DATE='2026-01-02T10:00:00Z' GIT_COMMITTER_DATE='2026-01-02T10:00:00Z' git -C "$SRC" commit -qm two
C2="$(git -C "$SRC" rev-parse HEAD)"
mkdir -p "$SRC/packages/a" "$SRC/packages/b" "$SRC/packages/b_new"

export DEEP_DOCS_TEST_MODE=1
# shellcheck disable=SC1090
source "$ROOT/scripts/orchestrate.sh" __test__ "$SRC" "$DOCS" test/model

# Exact recorded commit wins over date fallback.
cat > "$DOCS/builder/last-run.md" <<EOF
commit: $C1
date: 2026-01-02T12:00:00Z
mode: update
EOF
assert_eq "$(resolve_baseline_commit)" "$C1" "recorded baseline commit"

# Legacy date-only records select the last commit at/before the timestamp.
cat > "$DOCS/builder/last-run.md" <<'EOF'
date: 2026-01-01T12:00:00Z
mode: update
EOF
assert_eq "$(resolve_baseline_commit)" "$C1" "date fallback must not omit the first later commit"

# An explicit but invalid commit must fail closed; date fallback is legacy-only.
cat > "$DOCS/builder/last-run.md" <<'EOF'
commit: not-a-commit
date: 2026-01-01T12:00:00Z
mode: update
EOF
assert_failure resolve_baseline_commit
cat > "$DOCS/builder/last-run.md" <<EOF
commit: $C1
date: 2026-01-02T12:00:00Z
mode: update
EOF

# Scratch state is invalidated when the source range changes and retained for an exact resume.
BASE_COMMIT="$C1"
printf 'old\n' > "$SCRATCH/update-diff.md"
printf 'old\n' > "$SCRATCH/git-diff-raw.md"
printf 'old\n' > "$SCRATCH/update-comprehend-alpha-summary.md"
printf 'keep\n' > "$SCRATCH/comprehend-alpha-summary.md"
printf 'different-range\n' > "$SCRATCH/update-run-state"
prepare_update_run_state
assert_no_file "$SCRATCH/update-diff.md"
assert_no_file "$SCRATCH/git-diff-raw.md"
assert_no_file "$SCRATCH/update-comprehend-alpha-summary.md"
assert_file "$SCRATCH/comprehend-alpha-summary.md"
RUN_KEY="$(cat "$SCRATCH/update-run-state")"
assert_eq "$RUN_KEY" "${C1}..${C2}" "run identity"
assert_eq "$HEAD_COMMIT" "$C2" "target commit must be pinned"
printf 'resume\n' > "$SCRATCH/update-diff.md"
prepare_update_run_state
assert_file "$SCRATCH/update-diff.md"

# A moving source HEAD invalidates the run instead of widening the pinned range.
printf 'three\n' >> "$SRC/file.txt"
git -C "$SRC" add file.txt
git -C "$SRC" commit -qm three
assert_failure assert_update_head_unchanged
git -C "$SRC" checkout -q --detach "$C2"
assert_success assert_update_head_unchanged

# Source identity must reject dirty source state but may ignore an in-repo docs output tree.
printf 'dirty\n' > "$SRC/untracked-source.txt"
assert_failure validate_reproducible_source
rm "$SRC/untracked-source.txt"
ORIGINAL_DOCS_DIR="$DOCS_DIR"
mkdir -p "$SRC/generated-docs"
DOCS_DIR="$SRC/generated-docs"
printf 'generated\n' > "$DOCS_DIR/untracked-doc.md"
assert_success validate_reproducible_source
DOCS_DIR="$ORIGINAL_DOCS_DIR"
rm -rf "$SRC/generated-docs"

write_inventory() {
  local path="$1" rows="$2"
  cat > "$path" <<EOF
| # | Component | Slug | Path | Source Files | Language | Purpose | Key Files | Dependencies |
|---|-----------|------|------|--------------|----------|---------|-----------|--------------|
${rows}
EOF
}

# Existing slugs are preserved by path; new slugs are deterministic; additions/removals are explicit.
OLD_INV="$TMP/old-inventory.md"
write_inventory "$OLD_INV" '| 1 | Alpha | `stable-alpha` | `packages/a` | 1 | TS | A | index.ts | — |'
write_inventory "$INVENTORY" $'| 1 | Alpha renamed | `agent-changed-alpha` | `packages/a` | 1 | TS | A | index.ts | — |\n| 2 | Beta | `agent-beta` | `packages/b_new` | 1 | TS | B | index.ts | — |'
reconcile_inventory_slugs "$OLD_INV" "$INVENTORY"
assert_contains "$INVENTORY" '`stable-alpha`'
assert_contains "$INVENTORY" '`b-new`'
write_inventory_delta "$OLD_INV" "$INVENTORY" "$SCRATCH/inventory-delta.md"
assert_contains "$SCRATCH/inventory-delta.md" '| `b-new` | NEW |'
assert_success validate_inventory "$INVENTORY"

write_inventory "$INVENTORY" '| 1 | Alpha | `same` | `packages/a` | 1 | TS | A | index.ts | — |
| 2 | Beta | `same` | `packages/b` | 1 | TS | B | index.ts | — |'
assert_failure validate_inventory "$INVENTORY"

# A same-identity path move is one STRUCTURAL delta, not contradictory NEW/REMOVED rows.
mkdir -p "$SRC/packages/foo" "$SRC/services/foo"
MOVE_OLD="$TMP/move-old.md"
MOVE_NEW="$TMP/move-new.md"
write_inventory "$MOVE_OLD" '| 1 | Foo | `foo` | `packages/foo` | 1 | TS | F | index.ts | — |'
write_inventory "$MOVE_NEW" '| 1 | Foo | `agent-foo` | `services/foo` | 1 | TS | F | index.ts | — |'
reconcile_inventory_slugs "$MOVE_OLD" "$MOVE_NEW"
write_inventory_delta "$MOVE_OLD" "$MOVE_NEW" "$SCRATCH/move-delta.md"
assert_contains "$SCRATCH/move-delta.md" '| `foo` | STRUCTURAL |'
if grep -Eq '\| (NEW|REMOVED) \|' "$SCRATCH/move-delta.md"; then
  fail "same-slug move emitted contradictory inventory delta rows"
fi

# Complete diff validation rejects impossible/extra/conflicting affected rows.
write_inventory "$SCRATCH/inventory-before-update.md" '| 1 | Alpha | `alpha` | `packages/a` | 1 | TS | A | index.ts | — |'
write_inventory "$INVENTORY" $'| 1 | Alpha | `alpha` | `packages/a` | 1 | TS | A | index.ts | — |\n| 2 | Beta | `beta` | `packages/b` | 1 | TS | B | index.ts | — |'
write_inventory_delta "$SCRATCH/inventory-before-update.md" "$INVENTORY" "$SCRATCH/inventory-delta.md"
cat > "$SCRATCH/update-diff.md" <<'EOF'
## Affected Components
| Slug | Classification | What Changed |
|------|----------------|--------------|
| beta | NEW | added |
EOF
assert_success validate_diff_inventory_delta
printf '| alpha | REMOVED | impossible |\n' >> "$SCRATCH/update-diff.md"
assert_failure validate_diff_inventory_delta
cat > "$SCRATCH/update-diff.md" <<'EOF'
## Affected Components
| Slug | Classification | What Changed |
|------|----------------|--------------|
| beta | NEW | added |
| ghost | MODIFIED | unknown |
EOF
assert_failure validate_diff_inventory_delta
cat > "$SCRATCH/update-diff.md" <<'EOF'
## Affected Components
| Slug | Classification | What Changed |
|------|----------------|--------------|
| beta | NEW | first |
| beta | NEW | duplicate |
EOF
assert_failure validate_diff_inventory_delta
cp "$INVENTORY" "$SCRATCH/inventory-before-update.md"
write_inventory_delta "$SCRATCH/inventory-before-update.md" "$INVENTORY" "$SCRATCH/inventory-delta.md"
cat > "$SCRATCH/update-diff.md" <<'EOF'
NO_CHANGES_DETECTED
trailing prose invalidates the marker
EOF
assert_failure validate_diff_inventory_delta
printf 'NO_CHANGES_DETECTED\n' > "$SCRATCH/update-diff.md"
assert_success validate_diff_inventory_delta

# Review accounting is scoped, exact, and fail-closed for malformed or issue results.
write_inventory "$INVENTORY" $'| 1 | Alpha | `alpha` | `packages/a` | 1 | TS | A | index.ts | — |\n| 2 | Beta | `beta` | `packages/b` | 1 | TS | B | index.ts | — |'
for slug in alpha beta; do
  mkdir -p "$DOCS/L2" "$DOCS/L3" "$DOCS/L4"
  printf '# %s\n' "$slug" > "$DOCS/L2/${slug}.md"
  printf '# %s\n' "$slug" > "$DOCS/L3/${slug}.md"
  printf '# %s\n' "$slug" > "$DOCS/L4/${slug}.md"
done
cat > "$SCRATCH/update-diff.md" <<'EOF'
## Affected Components
| Slug | Classification | What Changed |
|------|----------------|--------------|
| alpha | MODIFIED | changed |
| beta | NEW | added |
EOF
REVIEW_SCOPE="$SCRATCH/review-scope.psv"
build_review_scope "$REVIEW_SCOPE"
assert_eq "$(wc -l < "$REVIEW_SCOPE" | xargs)" "2" "affected review scope"
printf 'details\nCOMPONENT_CLEAN\n' > "$SCRATCH/review-alpha.md"
printf 'details without terminal status\n' > "$SCRATCH/review-beta.md"
assert_failure verify_review_scope "$REVIEW_SCOPE"
printf 'details\nCOMPONENT_ISSUES: 1 unresolved\n' > "$SCRATCH/review-beta.md"
assert_failure verify_review_scope "$REVIEW_SCOPE"
printf 'COMPONENT_ISSUES: 1 unresolved\nCOMPONENT_CLEAN\n' > "$SCRATCH/review-beta.md"
assert_failure verify_review_scope "$REVIEW_SCOPE"
printf 'details\nCOMPONENT_CLEAN\n' > "$SCRATCH/review-beta.md"
review_input_fingerprint alpha > "$SCRATCH/review-alpha.fingerprint"
review_input_fingerprint beta > "$SCRATCH/review-beta.fingerprint"
assert_success verify_review_scope "$REVIEW_SCOPE"
# A stale issue outside the current scope must not contaminate this run.
printf 'COMPONENT_ISSUES: 9 unresolved\n' > "$SCRATCH/review-old-component.md"
assert_success verify_review_scope "$REVIEW_SCOPE"

# The real review phase invalidates prior-run files and preserves accepted files
# only while the reviewed document fingerprint remains unchanged.
for slug in alpha beta; do
  mkdir -p "$DOCS/L2" "$DOCS/L3" "$DOCS/L4"
  printf '# %s\n' "$slug" > "$DOCS/L2/${slug}.md"
  printf '# %s\n' "$slug" > "$DOCS/L3/${slug}.md"
  printf '# %s\n' "$slug" > "$DOCS/L4/${slug}.md"
  printf 'stale\nCOMPONENT_CLEAN\n' > "$SCRATCH/review-${slug}.md"
done
PHASE=update
UPDATE_RUN_KEY='review-range'
printf 'different-review-range\n' > "$REVIEW_STATE_FILE"
STUB_REVIEW_MODE=clean
STUB_AGGREGATE_MODE=clean
REVIEW_CALLS="$TMP/reviewer-calls"
: > "$REVIEW_CALLS"
spawn_agent() {
  local task="$1" label="$2"
  if [[ "$label" == "review-aggregate" ]]; then
    [[ "$STUB_AGGREGATE_MODE" == "clean" ]] || return 1
    printf '# aggregate\n' > "$DOCS/REVIEW.md"
    printf 'REVIEW_AGGREGATE_COMPLETE\n' > "$SCRATCH/review-aggregate-complete.md"
    return 0
  fi
  local review_file
  review_file=$(printf '%s\n' "$task" | grep -oE '/[^ ]+/review-[^ ]+\.md' | head -1)
  [[ -n "$review_file" ]] || return 1
  printf '%s\n' "$label" >> "$REVIEW_CALLS"
  if [[ "$STUB_REVIEW_MODE" == "clean" || "$STUB_REVIEW_MODE" == "failed-clean" ]]; then
    printf 'fresh review body\nCOMPONENT_CLEAN\n' > "$review_file"
    printf 'COMPONENT_CLEAN\n'
    [[ "$STUB_REVIEW_MODE" != "failed-clean" ]] || return 72
  else
    printf 'malformed review body\n' > "$review_file"
    printf 'COMPONENT_CLEAN\n'
  fi
}
assert_success phase_review
assert_contains "$SCRATCH/review-alpha.md" 'fresh review body'
assert_contains "$SCRATCH/review-alpha.md" 'COMPONENT_CLEAN'
assert_file "$SCRATCH/review-alpha.fingerprint"
printf 'resume-preserved\nCOMPONENT_CLEAN\n' > "$SCRATCH/review-alpha.md"
CALLS_BEFORE=$(wc -l < "$REVIEW_CALLS" | xargs)
assert_success phase_review
assert_contains "$SCRATCH/review-alpha.md" 'resume-preserved'
assert_eq "$(wc -l < "$REVIEW_CALLS" | xargs)" "$CALLS_BEFORE" "unchanged docs should reuse current-run review"

# Same-range doc mutation invalidates only that component's clean review.
printf '# alpha changed after review\n' > "$DOCS/L2/alpha.md"
assert_success phase_review
CALLS_AFTER=$(wc -l < "$REVIEW_CALLS" | xargs)
assert_eq "$CALLS_AFTER" "$((CALLS_BEFORE + 1))" "changed docs must trigger a fresh component review"
assert_contains "$SCRATCH/review-alpha.md" 'fresh review body'

STUB_AGGREGATE_MODE=fail
printf '# changed aggregate requires regeneration\n' > "$DOCS/REVIEW.md"
assert_failure phase_review
STUB_AGGREGATE_MODE=clean

STUB_REVIEW_MODE=malformed
printf 'new-review-range\n' > "$REVIEW_STATE_FILE"
assert_failure phase_review
STUB_REVIEW_MODE=clean

# A nonzero process must never acquire a clean review fingerprint from its marker.
STUB_REVIEW_MODE=failed-clean
printf 'failed-clean-range\n' > "$REVIEW_STATE_FILE"
assert_failure phase_review
assert_no_file "$SCRATCH/review-alpha.fingerprint"
assert_no_file "$SCRATCH/review-alpha.md"
STUB_REVIEW_MODE=clean

# Standalone review ignores stale update-diff scope and reviews the full inventory.
PHASE=review
cat > "$SCRATCH/update-diff.md" <<'EOF'
| alpha | MODIFIED | old update only |
EOF
build_review_scope "$REVIEW_SCOPE"
assert_eq "$(wc -l < "$REVIEW_SCOPE" | xargs)" "2" "standalone review scope"
assert_success phase_review
CALLS_BEFORE=$(wc -l < "$REVIEW_CALLS" | xargs)
REVIEW_KEY_BEFORE=$(<"$REVIEW_STATE_FILE")
assert_success phase_review
assert_eq "$(wc -l < "$REVIEW_CALLS" | xargs)" "$CALLS_BEFORE" "standalone same-source resume"
assert_eq "$(<"$REVIEW_STATE_FILE")" "$REVIEW_KEY_BEFORE" "stable standalone review key"
PHASE=__test__
rm -f "$DOCS/L2/beta.md" "$DOCS/L3/beta.md" "$DOCS/L4/beta.md" "$DOCS/REVIEW.md"

# Group validation applies even to one group and enforces exact, unique membership.
GROUPS_FILE="$DOCS/builder/specs/component-groups.md"
cat > "$GROUPS_FILE" <<'EOF'
| # | Group | Slug | Path Prefix | Components | Purpose |
|---|-------|------|-------------|------------|---------|
| 1 | Only | `only` | `packages` | `alpha` | one group |
EOF
assert_failure validate_component_groups
cat > "$GROUPS_FILE" <<'EOF'
| # | Group | Slug | Path Prefix | Components | Purpose |
|---|-------|------|-------------|------------|---------|
| 1 | Only | `only` | `packages` | `alpha, beta` | one group |
EOF
assert_success validate_component_groups
mkdir -p "$DOCS/L2/groups"
printf '# only\n' > "$DOCS/L2/groups/only.md"
printf '# stale\n' > "$DOCS/L2/groups/stale.md"
remove_stale_group_docs
assert_file "$DOCS/L2/groups/only.md"
[[ ! -e "$DOCS/L2/groups/stale.md" ]] || fail "stale group page was not removed"
cat > "$GROUPS_FILE" <<'EOF'
| # | Group | Slug | Path Prefix | Components | Purpose |
|---|-------|------|-------------|------------|---------|
| 1 | One | `one` | `packages/a` | `alpha, beta` | first |
| 2 | Two | `two` | `packages/b` | `beta` | duplicate membership |
EOF
assert_failure validate_component_groups
rm -rf "$DOCS/L2/groups"

# Package navigation must include every generated page and all configured targets must exist.
mkdir -p "$DOCS/L1" "$DOCS/L2" "$DOCS/L3" "$DOCS/L4" "$DOCS/diagrams"
printf '# home\n' > "$DOCS/index.md"
printf '# executive\n' > "$DOCS/L1/executive-summary.md"
printf '# alpha\n' > "$DOCS/L2/alpha.md"
printf '# alpha\n' > "$DOCS/L3/alpha.md"
printf '# alpha\n' > "$DOCS/L4/alpha.md"
printf '# diagrams\n' > "$DOCS/diagrams/INDEX.md"
cat > "$DOCS/mkdocs.yml" <<'EOF'
nav:
  - Home: index.md
  - Executive: L1/executive-summary.md
  - Alpha L2: L2/alpha.md
  - Alpha L3: L3/alpha.md
  - Diagrams: diagrams/INDEX.md
EOF
assert_failure validate_site_navigation
printf '  - Alpha L4: L4/alpha.md\n' >> "$DOCS/mkdocs.yml"
assert_success validate_site_navigation
# Mentioning a page outside nav must not count as navigation coverage.
cat > "$DOCS/mkdocs.yml" <<'EOF'
nav:
  - Home: index.md
  - Executive: L1/executive-summary.md
  - Alpha L2: L2/alpha.md
  - Alpha L3: L3/alpha.md
  - Diagrams: diagrams/INDEX.md
exclude_docs: L4/alpha.md
EOF
assert_failure validate_site_navigation
cat > "$DOCS/mkdocs.yml" <<'EOF'
nav:
  - Home: index.md
  - Executive: L1/executive-summary.md
  - Alpha L2: L2/alpha.md
  - Alpha L3: L3/alpha.md
  - Alpha L4: L4/alpha.md
  - Diagrams: diagrams/INDEX.md
  - Missing: L3/missing.md
EOF
assert_failure validate_site_navigation

printf 'PASS: orchestrate update regression tests\n'
