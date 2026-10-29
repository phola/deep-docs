#!/usr/bin/env bash
set -uo pipefail
# Note: not using set -e so we can handle errors per-component

# deep-docs orchestrator — drives the per-component loop mechanically
# Usage: ./orchestrate.sh <phase> <repo_path> <docs_dir> [model]
#
# Phases: discover, comprehend, write, review
# The script reads component-inventory.md, loops through each component,
# and spawns one OpenClaw sub-agent per component.

PHASE="${1:?Usage: orchestrate.sh <phase> <repo_path> <docs_dir> [model] [-- history options]}"
REPO_PATH="${2:?Missing repo_path}"
DOCS_DIR="${3:?Missing docs_dir}"
MODEL="${4:-anthropic/claude-opus-4-6}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROGRESS="${DOCS_DIR}/builder/progress.md"
INVENTORY="${DOCS_DIR}/builder/specs/component-inventory.md"
SCRATCH="${DOCS_DIR}/builder/.scratch"
TIMEOUT=1800  # 30 min per sub-agent
LAST_RUN_FILE="${DOCS_DIR}/builder/last-run.md"
UPDATE_STATE_FILE="${SCRATCH}/update-run-state"
REVIEW_SCOPE_FILE="${SCRATCH}/review-scope.psv"
REVIEW_STATE_FILE="${SCRATCH}/review-run-state"
BASE_COMMIT=""
HEAD_COMMIT=""
UPDATE_RUN_KEY=""

# Model routing strategy:
# - QUALITY_MODEL  : comprehend, synthesise, write (accuracy matters most)
# - ECONOMY_MODEL  : discover, review pass 1, diagram (mechanical/structural tasks)
# Override ECONOMY_MODEL to "" to use QUALITY_MODEL everywhere (max quality mode).
QUALITY_MODEL="${MODEL}"
ECONOMY_MODEL="${DEEP_DOCS_ECONOMY_MODEL-anthropic/claude-sonnet-4-6}"
AGENT_ADAPTER="${DEEP_DOCS_AGENT_ADAPTER:-openclaw}"

# Helper: pick model based on quality requirement
model_for() {
  local quality="${1:-high}"  # high | economy
  if [[ -z "$ECONOMY_MODEL" || "$quality" == "high" ]]; then
    echo "$QUALITY_MODEL"
  else
    echo "$ECONOMY_MODEL"
  fi
}

HARD_RULES='HARD RULES:
1. NEVER modify, fix, or suggest changes to source code
2. NEVER include "consider refactoring", "this could be improved", or similar
3. Document ACTUAL behaviour, not intended or ideal behaviour
4. If something looks like a bug, describe the actual behaviour neutrally
5. Use <!-- UNVERIFIED --> for anything not confirmed by reading source
6. All file paths relative to repo root
7. No secrets, credentials, or .env values in output'

log() {
  local ts
  ts=$(date +"%H:%M")
  echo "[${ts}] $1" | tee -a "$PROGRESS"
}

# Parse component-inventory.md table rows
# Expected format: | # | Component | Slug | Path | Source Files | Language | Purpose | Key Files | Dependencies |
trim() {
  # Trim whitespace and backticks using bash builtins only
  local val="$1"
  val="${val#"${val%%[![:space:]]*}"}"  # trim leading
  val="${val%"${val##*[![:space:]]}"}"  # trim trailing
  val="${val//\`/}"                      # remove backticks
  echo "$val"
}

parse_components_file() {
  local inventory_file="$1"
  # Pre-extract with awk to avoid subshell PATH issues
  /usr/bin/awk -F'|' '/^\| [0-9]/ {
    gsub(/`/, "", $4); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4);  # slug
    gsub(/`/, "", $3); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);  # name
    gsub(/`/, "", $5); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5);  # path
    gsub(/`/, "", $6); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6);  # files
    if ($4 != "") print $4 "|" $3 "|" $5 "|" $6
  }' "$inventory_file"
}

parse_components() {
  parse_components_file "$INVENTORY"
}

# Derive a deterministic slug from a component path.
# Takes the last path segment (directory name), converts underscores to hyphens,
# and lowercases. Same path always produces the same slug.
# Examples:
#   workspaces/modules/delivery_manager/delivery_manager_fun_api → delivery-manager-fun-api
#   workspaces/libs/buzz_lib_db → buzz-lib-db
deterministic_slug() {
  local path="$1"
  # Strip trailing slashes, take basename, underscore→hyphen, lowercase
  local base
  base=$(basename "${path%/}")
  echo "$base" | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

# Post-process component-inventory.md to rewrite slugs deterministically.
# Called once after discover phase. Reads the Path column, derives slug, rewrites Slug column.
stabilise_slugs() {
  local inv="$1"
  [[ -f "$inv" ]] || return 1

  local tmp="${inv}.tmp"
  while IFS= read -r line; do
    # Only process table data rows (start with "| <number>")
    if [[ "$line" =~ ^[[:space:]]*\|[[:space:]]*[0-9] ]]; then
      # Extract path (column 5, 1-indexed from |)
      local path_col
      path_col=$(echo "$line" | /usr/bin/awk -F'|' '{gsub(/`/, "", $5); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5); print $5}')
      if [[ -n "$path_col" ]]; then
        local new_slug
        new_slug=$(deterministic_slug "$path_col")
        # Replace the slug column (column 4) with the deterministic slug
        # Preserve the rest of the line
        line=$(echo "$line" | /usr/bin/awk -F'|' -v slug="$new_slug" '{
          OFS="|"
          # Rebuild: $4 is the slug column
          $4 = " `" slug "` "
          print
        }')
      fi
    fi
    echo "$line"
  done < "$inv" > "$tmp"
  mv "$tmp" "$inv"
  log "SLUGS — stabilised (deterministic slugs from paths)"
}

count_components() {
  parse_components | wc -l | xargs
}

read_last_run_field() {
  local field="$1"
  [[ -f "$LAST_RUN_FILE" ]] || return 0
  /usr/bin/awk -F':' -v key="$field" '$1 == key {
    sub(/^[^:]*:[[:space:]]*/, ""); print; exit
  }' "$LAST_RUN_FILE"
}

# Resolve the source baseline used by every update sub-phase. New records pin the
# exact source commit; legacy date-only records fall back to the last commit at
# or before the timestamp so the first later commit is not omitted.
resolve_baseline_commit() {
  local recorded_commit last_run_date
  recorded_commit=$(read_last_run_field commit)
  if [[ -n "$recorded_commit" ]]; then
    if git -C "$REPO_PATH" cat-file -e "${recorded_commit}^{commit}" 2>/dev/null; then
      git -C "$REPO_PATH" rev-parse "${recorded_commit}^{commit}"
      return 0
    fi
    echo "Recorded last-run commit is not available: $recorded_commit" >&2
    return 1
  fi

  last_run_date=$(read_last_run_field date)
  if [[ -n "$last_run_date" ]]; then
    local legacy_commit
    legacy_commit=$(git -C "$REPO_PATH" rev-list -1 --before="$last_run_date" HEAD 2>/dev/null || true)
    if [[ -n "$legacy_commit" ]]; then
      printf '%s\n' "$legacy_commit"
      return 0
    fi
    echo "No source commit exists at or before legacy last-run date: $last_run_date" >&2
    return 1
  fi
  echo "Missing usable commit/date baseline in $LAST_RUN_FILE" >&2
  return 1
}

validate_reproducible_source() {
  local repo_root docs_real docs_rel=""
  repo_root=$(git -C "$REPO_PATH" rev-parse --show-toplevel 2>/dev/null) || return 1
  docs_real=$(cd "$DOCS_DIR" 2>/dev/null && pwd -P) || return 1
  repo_root=$(cd "$repo_root" && pwd -P)
  if [[ "$docs_real" == "$repo_root"/* ]]; then
    docs_rel=${docs_real#"${repo_root}/"}
  fi

  local pathspecs=(.)
  if [[ -n "$docs_rel" ]]; then
    pathspecs+=(":(exclude)${docs_rel}/**")
  fi
  if ! git -C "$repo_root" diff --quiet HEAD -- "${pathspecs[@]}" ||
     ! git -C "$repo_root" diff --cached --quiet HEAD -- "${pathspecs[@]}"; then
    echo "Source repository has tracked changes outside the documentation output: $repo_root" >&2
    return 1
  fi

  local untracked
  untracked=$(git -C "$repo_root" ls-files --others --exclude-standard | while IFS= read -r source_path; do
    if [[ -z "$docs_rel" || ( "$source_path" != "$docs_rel" && "$source_path" != "$docs_rel"/* ) ]]; then
      printf '%s\n' "$source_path"
    fi
  done)
  if [[ -n "$untracked" ]]; then
    echo "Source repository has untracked files outside the documentation output:" >&2
    printf '%s\n' "$untracked" >&2
    return 1
  fi
}

# Clear only source-range-specific update artifacts. Re-running the exact same
# baseline..target range keeps them for resume; a different range cannot reuse them.
prepare_update_run_state() {
  mkdir -p "$SCRATCH"
  validate_reproducible_source || {
    log "UPDATE_STATE — ❌ source is not a reproducible clean Git tree"
    return 1
  }
  local existing_key
  HEAD_COMMIT=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null) || {
    log "UPDATE_STATE — ❌ source repository has no readable HEAD"
    return 1
  }
  if [[ -z "$BASE_COMMIT" ]]; then
    BASE_COMMIT=$(resolve_baseline_commit) || {
      log "UPDATE_STATE — ❌ no trustworthy update baseline"
      return 1
    }
  fi
  if ! git -C "$REPO_PATH" merge-base --is-ancestor "$BASE_COMMIT" "$HEAD_COMMIT" 2>/dev/null; then
    log "UPDATE_STATE — ❌ baseline ${BASE_COMMIT} is not an ancestor of target ${HEAD_COMMIT}"
    return 1
  fi
  UPDATE_RUN_KEY="${BASE_COMMIT}..${HEAD_COMMIT}"
  existing_key=""
  [[ -f "$UPDATE_STATE_FILE" ]] && existing_key=$(<"$UPDATE_STATE_FILE")

  if [[ "$existing_key" != "$UPDATE_RUN_KEY" ]]; then
    # These are successful-baseline snapshots, not target-range caches. A failed
    # A..B refresh must not become the old inventory when retrying A..C.
    if [[ "${existing_key%%..*}" == "$BASE_COMMIT" && -f "${SCRATCH}/inventory-before-update.md" ]]; then
      cp "${SCRATCH}/inventory-before-update.md" "$INVENTORY" || return 1
      if [[ -f "${SCRATCH}/component-groups-before-update.md" ]]; then
        cp "${SCRATCH}/component-groups-before-update.md" "${DOCS_DIR}/builder/specs/component-groups.md" || return 1
      else
        rm -f "${DOCS_DIR}/builder/specs/component-groups.md"
      fi
    else
      rm -f "${SCRATCH}/inventory-before-update.md" \
        "${SCRATCH}/component-groups-before-update.md"
    fi
    rm -f \
      "${SCRATCH}/update-diff.md" \
      "${SCRATCH}/git-diff-raw.md" \
      "${SCRATCH}/inventory-refresh-complete.md" \
      "${SCRATCH}/inventory-delta.md" \
      "${REVIEW_SCOPE_FILE}" \
      "${REVIEW_STATE_FILE}" \
      "${SCRATCH}"/update-comprehend-*-summary.md
    printf '%s\n' "$UPDATE_RUN_KEY" > "$UPDATE_STATE_FILE"
    log "UPDATE_STATE — fresh source range (${UPDATE_RUN_KEY}); stale update artifacts invalidated"
  else
    log "UPDATE_STATE — resuming source range (${UPDATE_RUN_KEY})"
  fi
}

assert_update_head_unchanged() {
  local live_head
  [[ -n "$HEAD_COMMIT" ]] || {
    echo "Update target commit has not been pinned" >&2
    return 1
  }
  live_head=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null) || return 1
  if [[ "$live_head" != "$HEAD_COMMIT" ]]; then
    echo "Source HEAD changed during update: expected $HEAD_COMMIT, found $live_head" >&2
    return 1
  fi
  validate_reproducible_source
}

# Preserve established slugs for surviving component paths and unique same-name
# path moves; derive slugs only for genuinely new component identities.
reconcile_inventory_slugs() {
  local old_inventory="$1"
  local new_inventory="$2"
  local tmp="${new_inventory}.tmp" mapping="${new_inventory}.slug-map.tmp"
  : > "$mapping"
  /usr/bin/awk -F'|' -v mapping="$mapping" '
    BEGIN { OFS = "|" }
    function clean(v) { gsub(/`/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
    NR == FNR {
      if ($0 ~ /^\| [0-9]/) {
        old_slug[clean($5)] = clean($4)
        old_name = clean($3)
        old_name_count[old_name]++
        old_slug_by_name[old_name] = clean($4)
      }
      next
    }
    /^\| [0-9]/ {
      path = clean($5)
      component_name = clean($3)
      if (path in old_slug) {
        slug = old_slug[path]
      } else if (old_name_count[component_name] == 1) {
        # A unique same-name component at a new path is a move; keep its identity.
        slug = old_slug_by_name[component_name]
      } else if (path == "." || path == "./") {
        slug = "repository-root"
      } else {
        n = split(path, parts, "/")
        slug = tolower(parts[n])
        gsub(/_/, "-", slug)
      }
      candidate = clean($4)
      if (candidate != slug) print candidate "|" slug >> mapping
      $4 = " `" slug "` "
      print
      next
    }
    { print }
  ' "$old_inventory" "$new_inventory" > "$tmp" && mv "$tmp" "$new_inventory" || {
    rm -f "$tmp" "$mapping"; return 1;
  }
  # The inventory and its membership references are one identity graph. Agent
  # choices of temporary slugs must not leave groups pointing at replaced IDs.
  local groups_file="${DOCS_DIR}/builder/specs/component-groups.md"
  if [[ -s "$mapping" && -f "$groups_file" ]]; then
    /usr/bin/awk -F'|' '
      BEGIN { OFS="|" }
      function clean(v) { gsub(/`/, "", v); gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); return v }
      FILENAME == ARGV[1] { renamed[$1]=$2; next }
      /^##[[:space:]]/ { standalone=(tolower($0) ~ /^## (singleton|standalone)/) }
      /^\| [0-9]/ {
        n=split(clean($6), members, ","); value=""
        for (i=1;i<=n;i++) {
          member=clean(members[i]); if (member in renamed) member=renamed[member]
          value=value (i>1 ? ", " : "") member
        }
        $6=" " value " "
      }
      standalone && /^\|/ { member=clean($2); if (member in renamed) $2=" `" renamed[member] "` " }
      { print }
    ' "$mapping" "$groups_file" > "${groups_file}.tmp" && mv "${groups_file}.tmp" "$groups_file" || {
      rm -f "$mapping" "${groups_file}.tmp"; return 1;
    }
  fi
  rm -f "$mapping"
}

write_inventory_delta() {
  local old_inventory="$1"
  local new_inventory="$2"
  local output="$3"
  local tmp
  tmp=$(mktemp)
  declare -A old_slug_by_path=() old_name_by_path=() old_path_by_slug=()
  declare -A new_slug_by_path=() new_name_by_path=() moved_slugs=()
  local slug name path files old_path
  while IFS='|' read -r slug name path files; do
    old_slug_by_path["$path"]="$slug"
    old_name_by_path["$path"]="$name"
    old_path_by_slug["$slug"]="$path"
  done < <(parse_components_file "$old_inventory")
  while IFS='|' read -r slug name path files; do
    new_slug_by_path["$path"]="$slug"
    new_name_by_path["$path"]="$name"
  done < <(parse_components_file "$new_inventory")

  for path in "${!new_slug_by_path[@]}"; do
    if [[ -z "${old_slug_by_path[$path]+x}" ]]; then
      slug=${new_slug_by_path[$path]}
      old_path=${old_path_by_slug[$slug]:-}
      if [[ -n "$old_path" && -z "${new_slug_by_path[$old_path]+x}" ]]; then
        printf '| `%s` | STRUCTURAL | %s | `%s` → `%s` |\n' "$slug" "${new_name_by_path[$path]}" "$old_path" "$path" >> "$tmp"
        moved_slugs["$slug"]=1
      else
        printf '| `%s` | NEW | %s | `%s` |\n' "$slug" "${new_name_by_path[$path]}" "$path" >> "$tmp"
      fi
    fi
  done
  for path in "${!old_slug_by_path[@]}"; do
    slug=${old_slug_by_path[$path]}
    if [[ -z "${new_slug_by_path[$path]+x}" && -z "${moved_slugs[$slug]+x}" ]]; then
      printf '| `%s` | REMOVED | %s | `%s` |\n' "$slug" "${old_name_by_path[$path]}" "$path" >> "$tmp"
    fi
  done

  {
    echo "# Component Inventory Delta"
    echo
    echo "| Slug | Classification | Component | Path |"
    echo "|------|----------------|-----------|------|"
    sort "$tmp"
  } > "$output"
  rm -f "$tmp"
}

validate_inventory() {
  local inventory_file="${1:-$INVENTORY}"
  local count=0
  declare -A seen_slugs=() seen_paths=()
  local slug name path files
  while IFS='|' read -r slug name path files; do
    count=$((count + 1))
    if [[ ! "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ || -z "$path" ]]; then
      echo "Invalid inventory row: malformed slug or missing path" >&2
      return 1
    fi
    if [[ -n "${seen_slugs[$slug]+x}" ]]; then
      echo "Duplicate inventory slug: $slug" >&2
      return 1
    fi
    if [[ -n "${seen_paths[$path]+x}" ]]; then
      echo "Duplicate inventory path: $path" >&2
      return 1
    fi
    seen_slugs["$slug"]=1
    seen_paths["$path"]=1
    if [[ "${DEEP_DOCS_SKIP_PATH_VALIDATION:-0}" != "1" && ! -e "${REPO_PATH}/${path}" ]]; then
      echo "Inventory path does not exist in source: $path" >&2
      return 1
    fi
  done < <(parse_components_file "$inventory_file")
  if (( count == 0 )); then
    echo "Inventory contains no components: $inventory_file" >&2
    return 1
  fi
}

build_review_scope() {
  local output="${1:-$REVIEW_SCOPE_FILE}"
  local tmp="${output}.tmp"
  : > "$tmp"
  if [[ -f "${SCRATCH}/update-diff.md" && "$PHASE" == "update" ]]; then
    local slug classification component
    while IFS='|' read -r slug classification; do
      [[ "$classification" == "REMOVED" ]] && continue
      component=$(parse_components | /usr/bin/awk -F'|' -v wanted="$slug" '$1 == wanted { print; exit }')
      if [[ -z "$component" ]]; then
        echo "Affected component is missing from inventory: $slug" >&2
        rm -f "$tmp"
        return 1
      fi
      printf '%s\n' "$component" >> "$tmp"
    done < <(parse_affected_components)
  else
    parse_components > "$tmp"
  fi
  /usr/bin/awk '!seen[$1]++' "$tmp" > "$output"
  rm -f "$tmp"
}

review_status() {
  local review_file="$1"
  [[ -f "$review_file" ]] || return 1
  /usr/bin/awk '
    {
      line = $0
      gsub(/\r$/, "", line)
      if (line == "COMPONENT_CLEAN" || line ~ /^COMPONENT_ISSUES: [0-9]+ unresolved$/) markers++
      if (line ~ /[^[:space:]]/) last = line
    }
    END {
      if (markers != 1) exit 1
      if (last == "COMPONENT_CLEAN") print "clean"
      else if (last ~ /^COMPONENT_ISSUES: [0-9]+ unresolved$/) print "issues"
      else exit 1
    }
  ' "$review_file"
}

review_input_fingerprint() {
  local slug="$1"
  local source_commit="${HEAD_COMMIT:-}"
  [[ -n "$source_commit" ]] || source_commit=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null || echo no-head)
  local tier file
  for tier in L2 L3 L4; do
    [[ -f "${DOCS_DIR}/${tier}/${slug}.md" ]] || return 1
  done
  {
    printf 'slug=%s\nsource=%s\n' "$slug" "$source_commit"
    for tier in L2 L3 L4; do
      file="${DOCS_DIR}/${tier}/${slug}.md"
      /usr/bin/sha256sum "$file"
    done
  } | /usr/bin/sha256sum | /usr/bin/awk '{print $1}'
}

review_fingerprint_matches() {
  local slug="$1"
  local fingerprint_file="${SCRATCH}/review-${slug}.fingerprint"
  [[ -f "$fingerprint_file" ]] || return 1
  [[ "$(<"$fingerprint_file")" == "$(review_input_fingerprint "$slug")" ]]
}

review_scope_counts() {
  local scope_file="$1"
  local clean=0 issues=0 unknown=0 total=0
  local slug name path files status
  while IFS='|' read -r slug name path files; do
    [[ -z "$slug" ]] && continue
    total=$((total + 1))
    status=$(review_status "${SCRATCH}/review-${slug}.md" 2>/dev/null || true)
    if [[ "$status" == "clean" ]] && ! review_fingerprint_matches "$slug"; then
      status=""
    fi
    case "$status" in
      clean) clean=$((clean + 1)) ;;
      issues) issues=$((issues + 1)) ;;
      *) unknown=$((unknown + 1)) ;;
    esac
  done < "$scope_file"
  printf '%s|%s|%s|%s\n' "$clean" "$issues" "$unknown" "$total"
}

review_aggregate_fingerprint() {
  [[ -s "${DOCS_DIR}/REVIEW.md" ]] || return 1
  {
    /usr/bin/sha256sum "$REVIEW_SCOPE_FILE" "$REVIEW_STATE_FILE" "${DOCS_DIR}/REVIEW.md"
    local slug name path files
    while IFS='|' read -r slug name path files; do
      /usr/bin/sha256sum "${SCRATCH}/review-${slug}.md" "${SCRATCH}/review-${slug}.fingerprint" || return 1
      review_input_fingerprint "$slug" || return 1
    done < "$REVIEW_SCOPE_FILE"
  } | /usr/bin/sha256sum | /usr/bin/awk '{print $1}'
}

verify_review_scope() {
  local scope_file="${1:-$REVIEW_SCOPE_FILE}"
  [[ -f "$scope_file" ]] || return 1
  local counts clean issues unknown total
  counts=$(review_scope_counts "$scope_file")
  IFS='|' read -r clean issues unknown total <<< "$counts"
  if (( total == 0 )); then
    is_removal_only_update && validate_update_outputs &&
      system_review_is_clean &&
      [[ -s "${SCRATCH}/review-system.fingerprint" &&
         "$(<"${SCRATCH}/review-system.fingerprint")" == "$(system_review_fingerprint)" ]]
    return $?
  fi
  if (( clean != total || issues > 0 || unknown > 0 )); then
    echo "Review scope incomplete: clean=${clean}, issues=${issues}, unknown=${unknown}, total=${total}" >&2
    return 1
  fi
}

extract_mkdocs_nav_targets() {
  local mkdocs_file="$1"
  /usr/bin/awk '
    /^nav:[[:space:]]*$/ { in_nav=1; next }
    in_nav && /^[^[:space:]#]/ { exit }
    in_nav && /\.md/ { print }
  ' "$mkdocs_file" | while IFS= read -r line; do
    local target="${line##*: }"
    target="${target%%#*}"
    target=$(printf '%s' "$target" | xargs)
    target="${target#\"}"; target="${target%\"}"
    target="${target#\'}"; target="${target%\'}"
    [[ "$target" == *.md ]] && printf '%s\n' "$target"
  done
}

validate_site_navigation() {
  local mkdocs_file="${DOCS_DIR}/mkdocs.yml"
  [[ -f "$mkdocs_file" ]] || {
    echo "Missing mkdocs.yml" >&2
    return 1
  }

  local nav_targets="${SCRATCH}/mkdocs-nav-targets.txt"
  mkdir -p "$SCRATCH"
  extract_mkdocs_nav_targets "$mkdocs_file" | /usr/bin/sort -u > "$nav_targets"
  [[ -s "$nav_targets" ]] || {
    echo "mkdocs.yml has no parseable nav targets" >&2
    return 1
  }

  local doc relative target
  while IFS= read -r doc; do
    relative="${doc#${DOCS_DIR}/}"
    if ! /usr/bin/grep -Fxq -- "$relative" "$nav_targets"; then
      echo "Documentation file missing from MkDocs navigation: $relative" >&2
      return 1
    fi
  done < <(
    {
      [[ -f "${DOCS_DIR}/index.md" ]] && printf '%s\n' "${DOCS_DIR}/index.md"
      find "${DOCS_DIR}/L1" "${DOCS_DIR}/L2" "${DOCS_DIR}/L3" "${DOCS_DIR}/L4" "${DOCS_DIR}/diagrams" -type f -name '*.md' 2>/dev/null
      [[ -f "${DOCS_DIR}/CHANGELOG.md" ]] && printf '%s\n' "${DOCS_DIR}/CHANGELOG.md"
      [[ -f "${DOCS_DIR}/REVIEW.md" ]] && printf '%s\n' "${DOCS_DIR}/REVIEW.md"
    } | sort -u
  )

  while IFS= read -r target; do
    if [[ ! -f "${DOCS_DIR}/${target}" ]]; then
      echo "MkDocs navigation target does not exist: $target" >&2
      return 1
    fi
  done < "$nav_targets"
}

# Discovery permits standalone components, represented separately from groups.
parse_standalone_components() {
  local groups_file="${DOCS_DIR}/builder/specs/component-groups.md"
  [[ -f "$groups_file" ]] || return 0
  /usr/bin/awk -F'|' '
    /^##[[:space:]]/ { standalone = (tolower($0) ~ /^## (singleton|standalone)/) }
    standalone && /^\|/ {
      slug=$2; gsub(/`/, "", slug); gsub(/^[[:space:]]+|[[:space:]]+$/, "", slug)
      if (slug != "" && tolower(slug) != "component" && slug !~ /^[-:]+$/) print slug
    }
  ' "$groups_file"
}

validate_component_groups() {
  local groups_file="${DOCS_DIR}/builder/specs/component-groups.md"
  [[ -f "$groups_file" ]] || return 0
  local group_total all_standalone=false
  group_total=$(count_groups)
  if (( group_total == 0 )) && grep -Fxq 'No component groups detected — all components are standalone.' "$groups_file"; then
    all_standalone=true
  fi

  declare -A inventory_slugs=() grouped_slugs=() group_slugs=()
  local slug name path files group_slug group_name path_prefix components member member_count
  local -a members
  while IFS='|' read -r slug name path files; do inventory_slugs["$slug"]=1; done < <(parse_components)
  while IFS='|' read -r group_slug group_name path_prefix components; do
    if [[ ! "$group_slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ || -n "${group_slugs[$group_slug]+x}" ]]; then
      echo "Invalid or duplicate component-group slug: $group_slug" >&2
      return 1
    fi
    group_slugs["$group_slug"]=1
    IFS=',' read -ra members <<< "$components"
    member_count=0
    for member in "${members[@]}"; do
      member=$(printf '%s' "$member" | tr -d '\140' | xargs)
      [[ -z "$member" ]] && continue
      if [[ -z "${inventory_slugs[$member]+x}" ]]; then
        echo "Component group references unknown slug: $member" >&2
        return 1
      fi
      if [[ -n "${grouped_slugs[$member]+x}" ]]; then
        echo "Component appears more than once in group membership: $member" >&2
        return 1
      fi
      grouped_slugs["$member"]="$group_slug"
      member_count=$((member_count + 1))
    done
    if (( member_count == 0 )); then
      echo "Component group has no members: $group_slug" >&2
      return 1
    fi
  done < <(parse_groups)
  while IFS= read -r member; do
    if [[ -z "${inventory_slugs[$member]+x}" || -n "${grouped_slugs[$member]+x}" ]]; then
      echo "Unknown or duplicate standalone component: $member" >&2
      return 1
    fi
    grouped_slugs["$member"]="standalone"
  done < <(parse_standalone_components)
  for slug in "${!inventory_slugs[@]}"; do
    if [[ "$all_standalone" != true && -z "${grouped_slugs[$slug]+x}" ]]; then
      echo "Current component is neither grouped nor explicitly standalone: $slug" >&2
      return 1
    fi
  done
}

# Unlike affected-output checks, no-change must inspect the entire inherited site.
validate_current_docs() {
  validate_inventory "$INVENTORY" && validate_component_groups || return 1
  local slug name path files tier required
  while IFS='|' read -r slug name path files; do
    for tier in L2 L3 L4; do
      [[ -s "${DOCS_DIR}/${tier}/${slug}.md" ]] || {
        echo "Current component has missing or empty ${tier} documentation: $slug" >&2
        return 1
      }
    done
  done < <(parse_components)
  for required in L1/executive-summary.md L2/overview.md L4/OVERVIEW.md diagrams/INDEX.md index.md; do
    [[ -s "${DOCS_DIR}/${required}" ]] || { echo "Missing required documentation: $required" >&2; return 1; }
  done
  while IFS='|' read -r slug name path files; do
    [[ -s "${DOCS_DIR}/L2/groups/${slug}.md" ]] || { echo "Missing group documentation: $slug" >&2; return 1; }
  done < <(parse_groups)
}

prepare_mkdocs_source_view() {
  # Keep authoritative root docs in place. MkDocs requires a child source tree;
  # relative symlinks expose only published roots, never builder/.git/scratch.
  local config="${DOCS_DIR}/mkdocs.yml" docs_path site_path
  docs_path=$(/usr/bin/awk '/^docs_dir:/ {sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); print; exit}' "$config" | xargs)
  site_path=$(/usr/bin/awk '/^site_dir:/ {sub(/^[^:]*:[[:space:]]*/, ""); sub(/[[:space:]]*#.*/, ""); print; exit}' "$config" | xargs)
  if [[ "${docs_path:-docs}" != "docs" || "${site_path:-site}" != "site" ]]; then
    log "PACKAGE — ❌ require docs_dir: docs and site_dir: site; root/outside-output build paths are unsafe or invalid"
    return 1
  fi
  local view="${DOCS_DIR}/docs" entry name
  if [[ -L "$view" || ( -e "$view" && ! -d "$view" ) || -L "${DOCS_DIR}/site" ]]; then
    log "PACKAGE — ❌ publishing directories must not redirect outside the docs output"
    return 1
  fi
  local -a published=(L1 L2 L3 L4 diagrams assets index.md CHANGELOG.md REVIEW.md)
  declare -A allowed=()
  for name in "${published[@]}"; do allowed["$name"]=1; done
  # Refuse conflicts before changing the view. Never overwrite user-owned files.
  if [[ -d "$view" ]]; then
    while IFS= read -r -d '' entry; do
      name=${entry##*/}
      if [[ -z "${allowed[$name]+x}" || ! -L "$entry" || "$(readlink "$entry")" != "../${name}" ]]; then
        log "PACKAGE — ❌ conflicting user-owned publish-view entry: $entry"
        return 1
      fi
    done < <(find "$view" -mindepth 1 -maxdepth 1 -print0)
  fi
  mkdir -p "$view" || return 1
  for name in "${published[@]}"; do
    if [[ -e "${DOCS_DIR}/${name}" ]]; then
      [[ -L "${view}/${name}" ]] || ln -s "../${name}" "${view}/${name}" || return 1
    elif [[ -L "${view}/${name}" ]]; then
      rm "${view}/${name}" || return 1
    fi
  done
}

validate_site_build() {
  prepare_mkdocs_source_view || return 1
  if command -v mkdocs &>/dev/null; then
    log "PACKAGE — building site..."
    local build_output
    rm -rf "${DOCS_DIR}/site"
    if ! build_output=$(cd "${DOCS_DIR}" && mkdocs build --strict 2>&1); then
      log "PACKAGE — ❌ mkdocs build failed. Output: ${build_output}"
      return 1
    fi
    local page_count
    page_count=$(find "${DOCS_DIR}/site" -name "*.html" | wc -l | xargs)
    log "PACKAGE — site built (${page_count} pages in ${DOCS_DIR}/site/)"
  else
    log "PACKAGE — mkdocs not installed; navigation validated, site build NOT VERIFIED"
  fi
}

validate_update_outputs() {
  local slug classification tier
  while IFS='|' read -r slug classification; do
    case "$classification" in
      NEW|MODIFIED|STRUCTURAL)
        for tier in L2 L3 L4; do
          if [[ ! -f "${DOCS_DIR}/${tier}/${slug}.md" ]]; then
            echo "Affected component is missing ${tier} documentation: $slug" >&2
            return 1
          fi
        done
        ;;
      REMOVED)
        for tier in L2 L3 L4; do
          if [[ -e "${DOCS_DIR}/${tier}/${slug}.md" ]]; then
            echo "Removed component still has ${tier} documentation: $slug" >&2
            return 1
          fi
        done
        ;;
    esac
  done < <(parse_affected_components)
  validate_inventory "$INVENTORY" && validate_component_groups
}

# Never label a default-config OpenClaw invocation as a requested model.
# Hermes chat has documented --model support; no global agent config is changed.
validate_agent_adapter() {
  if [[ "$AGENT_ADAPTER" != "hermes" ]]; then
    echo "AGENT — adapter '$AGENT_ADAPTER' cannot enforce requested per-call models. The legacy openclaw agent --local path is not model-routed here; explicitly select DEEP_DOCS_AGENT_ADAPTER=hermes (see references/legacy-safety-fixes.md)." >&2
    return 78
  fi
  command -v python3 >/dev/null && command -v hermes >/dev/null || {
    echo 'AGENT — python3 and hermes are required for the selected adapter' >&2
    return 78
  }
  local help
  help=$(hermes chat --help 2>&1) &&
    [[ "$help" == *--model* && "$help" == *--query* && "$help" == *--quiet* ]] || {
    echo 'AGENT — installed Hermes lacks the required chat --model/--query/--quiet interface' >&2
    return 78
  }
}

# One journal per docs output, across phases, source revisions and shell restarts.
# Reserve before dispatch; abandoned reservations never become free retries.
spawn_agent() {
  local task="$1" label="$2" agent_timeout="${3:-$TIMEOUT}" agent_model="${4:-$QUALITY_MODEL}"
  [[ "$AGENT_ADAPTER" == "hermes" ]] || { validate_agent_adapter; return 78; }
  python3 - "$SCRATCH" "$label" "$agent_timeout" "$agent_model" "$task" <<'PY'
import fcntl, json, math, os, pathlib, signal, subprocess, sys, tempfile, time

root, label, requested_timeout, model, task = sys.argv[1:]
root = pathlib.Path(root)
root.mkdir(parents=True, exist_ok=True)
os.umask(0o077)

def stop(message, code=75):
    print('AGENT — ' + message, file=sys.stderr)
    raise SystemExit(code)

def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise ValueError('expected a positive finite limit')
    return number

lock = (root / 'agent-budget.lock').open('a')
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    stop('another agent invocation owns this output budget')
ledger = root / 'agent-budget.json'
try:
    state = json.loads(ledger.read_text()) if ledger.exists() else {
        'version': 1, 'limits': {'max_invocations': 200, 'max_agent_seconds': 14400}, 'attempts': []}
    if state['version'] != 1 or not isinstance(state['attempts'], list):
        raise ValueError('invalid ledger schema')
    if type(state['limits']['max_invocations']) is not int or state['limits']['max_invocations'] <= 0:
        raise ValueError('invalid saved invocation limit')
    positive(state['limits']['max_agent_seconds'])
    for row in state['attempts']:
        if row['status'] not in ('running', 'finished') or not math.isfinite(row['charged_seconds']) or row['charged_seconds'] < 0:
            raise ValueError('invalid reservation')
except (ValueError, KeyError, TypeError):
    stop('invalid durable budget ledger; refusing to reset it')
try:
    calls_limit = int(os.environ.get('DEEP_DOCS_MAX_INVOCATIONS', state['limits']['max_invocations']))
    seconds_limit = positive(os.environ.get('DEEP_DOCS_MAX_AGENT_SECONDS', state['limits']['max_agent_seconds']))
    call_timeout = min(positive(requested_timeout), positive(os.environ.get('DEEP_DOCS_AGENT_TIMEOUT_SECONDS', requested_timeout)))
    if calls_limit <= 0 or not model.strip():
        raise ValueError('invalid call limit/model')
except ValueError:
    stop('invalid invocation/time budget or empty model', 78)

def persist():
    fd, tmp = tempfile.mkstemp(prefix='.agent-budget-', dir=root)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(state, out, indent=2, allow_nan=False)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(tmp, ledger)
        directory_fd = os.open(root, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

limits = dict(max_invocations=calls_limit, max_agent_seconds=seconds_limit)
if limits != state['limits']:
    state['limits'] = limits
    persist()
if any(row['status'] == 'running' for row in state['attempts']):
    stop('unreconciled interrupted invocation; reservation retained, inspect agent-budget.json before retry')
used_seconds = sum(row['charged_seconds'] for row in state['attempts'])
if len(state['attempts']) >= calls_limit or used_seconds >= seconds_limit:
    stop('durable invocation/time budget exhausted; limits may be raised explicitly, usage is not reset')
allowance = min(call_timeout, seconds_limit - used_seconds)
row = dict(label=label, requested_model=model, actual_model=None, adapter='hermes',
           status='running', reserved_seconds=allowance, charged_seconds=allowance,
           started_at=time.time(), elapsed_seconds=None, returncode=None)
state['attempts'].append(row)
persist()
command = ['hermes', 'chat', '--model', model, '--query', task, '--quiet']
if os.environ.get('DEEP_DOCS_HERMES_PROVIDER'):
    command += ['--provider', os.environ['DEEP_DOCS_HERMES_PROVIDER']]
child = None
started = time.monotonic()
code = 1
cancelled = None

def interrupted(signum, frame):
    # Do not throw between OS process creation and binding its cleanup handle.
    global cancelled
    cancelled = signum

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    # No shell, no approval bypass, and no in-memory buffering of agent output.
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True,
                             env=dict(os.environ, DEEP_DOCS_AGENT_LABEL=label))
    while True:
        if cancelled is not None:
            raise InterruptedError(cancelled)
        remaining = allowance - (time.monotonic() - started)
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, allowance)
        try:
            code = child.wait(timeout=min(0.1, remaining))
            break
        except subprocess.TimeoutExpired:
            continue
except subprocess.TimeoutExpired:
    code = 124
    print('AGENT — hard invocation timeout: ' + label, file=sys.stderr)
except InterruptedError as exc:
    code = 128 + exc.args[0]
except OSError as exc:
    print('AGENT — adapter launch failed: ' + type(exc).__name__, file=sys.stderr)
    code = 78
finally:
    if child is not None:
        # Also terminate descendants left behind after the parent exits.
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
    elapsed = time.monotonic() - started
    row.update(status='finished', elapsed_seconds=elapsed, charged_seconds=elapsed,
               returncode=code, finished_at=time.time())
    persist()
sys.exit(code if 0 <= code <= 255 else 1)
PY
}

# ============================================================
# PHASE: comprehend
# ============================================================
phase_comprehend() {
  local total
  total=$(count_components)
  log "COMPREHEND — started (${total} components)"

  local i=0
  while IFS='|' read -r slug name path files; do
    i=$((i + 1))
    
    # Check if summary already exists (resume support)
    if [[ -f "${SCRATCH}/comprehend-${slug}-summary.md" ]]; then
      log "COMPREHEND/${slug} — skipped (summary exists, ${i}/${total})"
      continue
    fi

    local files_int="${files//[^0-9]/}"
    files_int="${files_int:-0}"

    # Minimal/config-only packages: ≤3 source files → simplified single-pass comprehension
    if (( files_int <= 3 )); then
      log "COMPREHEND/${slug} — started (minimal package, ${files_int} files, ${i}/${total})"

      local mini_task="You are studying the '${name}' component at ${REPO_PATH}/${path}.
This is a minimal/config-only package with ${files_int} source files.

Read all source files in the component directory.
Write a brief summary scratchpad to:
${SCRATCH}/comprehend-${slug}-summary.md

Include:
- What the package exports (list each export)
- What config/conventions it enforces
- Which other packages consume it (check dependents in ${INVENTORY})
- Any version constraints or peer dependencies

This is a THIN PACKAGE — do not run multiple comprehension loops.
Keep the summary under 50 lines.

${HARD_RULES}"

      spawn_agent "$mini_task" "comprehend-${slug}" "$TIMEOUT" "$(model_for economy)" > /dev/null

      if [[ -f "${SCRATCH}/comprehend-${slug}-summary.md" ]]; then
        log "COMPREHEND/${slug} — complete (minimal, ${i}/${total})"
      else
        log "COMPREHEND/${slug} — ❌ SKIPPED minimal package (${i}/${total})"
        echo "- ${name} (${slug}): minimal package, no summary produced" >> "${DOCS_DIR}/builder/skipped-components.md"
      fi
      continue
    fi

    local mode="single-agent"
    local num_loops=3
    if (( files_int > 30 )); then
      mode="per-loop (${files_int} files)"
      num_loops=7
    fi

    log "COMPREHEND/${slug} — started (${mode}, ${i}/${total})"

    # Collect dependency summaries
    local dep_summaries="None — check component-inventory.md for dependencies and read their summaries from ${SCRATCH}/ if needed."

    if (( num_loops <= 3 )); then
      # ---- SMALL PROFILE: single agent, 3 loops ----
      local task="You are studying the '${name}' component of a codebase at ${REPO_PATH}.
Your job is to BUILD UNDERSTANDING through iterative study. Do NOT write documentation.

Read these first:
- ${DOCS_DIR}/builder/interview-notes.md (user context)
- ${DOCS_DIR}/builder/specs/component-inventory.md (find your component's entry)

Component path: ${REPO_PATH}/${path}
Component slug: ${slug}

Read the comprehension loop instructions at ${SKILL_DIR}/references/comprehend.md.
Use the SMALL PROFILE (3 loops) for this component.

Dependency context: ${dep_summaries}
Read any relevant dependency summaries from ${SCRATCH}/comprehend-*-summary.md

After ALL loops, write a summary scratchpad to:
${SCRATCH}/comprehend-${slug}-summary.md

On completion, append a progress line to ${PROGRESS}

${HARD_RULES}"

      spawn_agent "$task" "comprehend-${slug}" "$TIMEOUT" "$(model_for high)"

    else
      # ---- LARGE PROFILE: per-loop chain, 7 sequential agents ----
      # Each loop is a separate sub-agent to avoid context overflow on large components.
      # Define loop names and instructions
      local -a loop_names=("01-inventory" "02-data" "03-functions" "04-flow" "05-deps" "06-state" "07-errors")
      local -a loop_instructions=(
        "LOOP 1 — INVENTORY: List every file in ${REPO_PATH}/${path}: path, language, line count, rough purpose. Note entry points, config files, test files."
        "LOOP 2 — DATA SHAPES: Schemas, types, interfaces, dataclasses, models, config structures. Input/output data formats (JSON, CSV, API payloads). Database tables, columns, relationships."
        "LOOP 3 — FUNCTIONS: Key function/method signatures with parameters and return types. What each does (read the implementation, don't guess from name). Note side effects explicitly."
        "LOOP 4 — INTERNAL FLOW: Call graph: what calls what, in what order. Control flow: conditionals, loops, error paths. Execution lifecycle: startup → processing → cleanup."
        "LOOP 5 — DEPENDENCIES: External packages: what, why, version constraints. Inter-component imports: what does this component use from others? External services: APIs, databases, file systems, cloud services."
        "LOOP 6 — STATE & SIDE EFFECTS: What does this component read? (files, DB, env vars, API responses). What does it write/mutate? (files, DB, API calls, stdout). Concurrency concerns, shared state, locking."
        "LOOP 7 — ERROR HANDLING: What can fail? How does it fail? (exceptions, return codes, silent failures). Recovery mechanisms: retries, fallbacks, circuit breakers. Edge cases: empty inputs, missing config, network failures, race conditions."
      )

      local loop_ok=true
      for li in $(seq 0 6); do
        local loop_name="${loop_names[$li]}"
        local loop_instr="${loop_instructions[$li]}"
        local scratchpad_path="${SCRATCH}/comprehend-${slug}-${loop_name}.md"

        # Skip if this loop's scratchpad already exists (resume support)
        if [[ -f "$scratchpad_path" ]]; then
          continue
        fi

        # Build list of prior loop scratchpads
        local prior_pads="None — first loop."
        if (( li > 0 )); then
          prior_pads=""
          for pi in $(seq 0 $((li - 1))); do
            local prior_file="${SCRATCH}/comprehend-${slug}-${loop_names[$pi]}.md"
            if [[ -f "$prior_file" ]]; then
              prior_pads="${prior_pads}
- ${prior_file}"
            fi
          done
          [[ -z "$prior_pads" ]] && prior_pads="None — prior loops not found."
        fi

        local loop_task="You are studying the '${name}' component of a codebase at ${REPO_PATH}.
This is loop $((li + 1)) of 7 for a large component (${files} source files).

Read:
- ${DOCS_DIR}/builder/specs/component-inventory.md (your component's entry)
- Previous loop outputs for THIS component: ${prior_pads}
- Dependency summaries from ${SCRATCH}/comprehend-*-summary.md (if relevant)
- Source code at ${REPO_PATH}/${path}

Run ONLY this loop:
${loop_instr}

Write scratchpad to: ${scratchpad_path}

${HARD_RULES}"

        spawn_agent "$loop_task" "comprehend-${slug}-loop-$((li + 1))" "$TIMEOUT" "$(model_for high)"

        if [[ ! -f "$scratchpad_path" ]]; then
          log "COMPREHEND/${slug} — ⚠️ loop $((li + 1)) (${loop_name}) failed, retrying"
          spawn_agent "$loop_task" "comprehend-${slug}-loop-$((li + 1))-retry" "$TIMEOUT" "$(model_for high)"
          if [[ ! -f "$scratchpad_path" ]]; then
            log "COMPREHEND/${slug} — ❌ loop $((li + 1)) (${loop_name}) failed after retry"
            loop_ok=false
            break
          fi
        fi
      done

      # Final summary agent — reads all loop outputs and writes the summary
      if [[ "$loop_ok" == true ]]; then
        local all_pads=""
        for li in $(seq 0 6); do
          all_pads="${all_pads}
- ${SCRATCH}/comprehend-${slug}-${loop_names[$li]}.md"
        done

        local summary_task="You are writing the comprehension summary for '${name}' (${files} source files).

Read ALL loop scratchpads: ${all_pads}

Also read:
- ${DOCS_DIR}/builder/specs/component-inventory.md (your component's entry)
- Dependency summaries from ${SCRATCH}/comprehend-*-summary.md (if relevant)

Write a comprehensive summary to:
${SCRATCH}/comprehend-${slug}-summary.md

Include:
- Key insights and surprises
- Architecture overview (entry points, main flows, data model)
- Relationships to other components discovered
- Open questions or things that remain unclear (mark <!-- UNVERIFIED -->)

${HARD_RULES}"

        spawn_agent "$summary_task" "comprehend-${slug}-summary" "$TIMEOUT" "$(model_for high)"
      fi
    fi

    # Verify output (works for both small and large profiles)
    if [[ -f "${SCRATCH}/comprehend-${slug}-summary.md" ]]; then
      log "COMPREHEND/${slug} — complete (${i}/${total})"
    else
      if (( num_loops <= 3 )); then
        # Only retry single-agent mode (per-loop already has per-loop retries above)
        log "COMPREHEND/${slug} — ❌ no summary produced, retrying (${i}/${total})"
        local task="You are studying the '${name}' component of a codebase at ${REPO_PATH}.
Your job is to BUILD UNDERSTANDING through iterative study. Do NOT write documentation.

Read these first:
- ${DOCS_DIR}/builder/interview-notes.md (user context)
- ${DOCS_DIR}/builder/specs/component-inventory.md (find your component's entry)

Component path: ${REPO_PATH}/${path}
Component slug: ${slug}

Read the comprehension loop instructions at ${SKILL_DIR}/references/comprehend.md.
Use the SMALL PROFILE (3 loops) for this component.

Dependency context: ${dep_summaries}
Read any relevant dependency summaries from ${SCRATCH}/comprehend-*-summary.md

After ALL loops, write a summary scratchpad to:
${SCRATCH}/comprehend-${slug}-summary.md

On completion, append a progress line to ${PROGRESS}

${HARD_RULES}"
        spawn_agent "$task" "comprehend-${slug}-retry" "$TIMEOUT" "$(model_for high)"
        if [[ -f "${SCRATCH}/comprehend-${slug}-summary.md" ]]; then
          log "COMPREHEND/${slug} — complete on retry (${i}/${total})"
        else
          log "COMPREHEND/${slug} — ❌ SKIPPED after retry (${i}/${total})"
          echo "- ${name} (${slug}): no summary produced after 2 attempts" >> "${DOCS_DIR}/builder/skipped-components.md"
        fi
      else
        log "COMPREHEND/${slug} — ❌ SKIPPED (per-loop chain failed, ${i}/${total})"
        echo "- ${name} (${slug}): per-loop chain failed" >> "${DOCS_DIR}/builder/skipped-components.md"
      fi
    fi
  done < <(parse_components)

  local summaries
  summaries=$(find "$SCRATCH" -name "comprehend-*-summary.md" | wc -l | xargs)
  log "COMPREHEND — complete (${summaries}/${total} summaries)"
}

# ============================================================
# PHASE: write_groups
# ============================================================

# Parse component-groups.md table rows
# Expected format: | # | Group | Slug | Path Prefix | Components | Purpose |
parse_groups() {
  local groups_file="${DOCS_DIR}/builder/specs/component-groups.md"
  [[ -f "$groups_file" ]] || return
  /usr/bin/awk -F'|' '/^\| [0-9]/ {
    gsub(/`/, "", $4); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4);  # slug
    gsub(/`/, "", $3); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);  # name
    gsub(/`/, "", $5); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5);  # path prefix
    gsub(/`/, "", $6); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6);  # components
    if ($4 != "" && $4 != "Slug") print $4 "|" $3 "|" $5 "|" $6
  }' "$groups_file"
}

count_groups() {
  parse_groups | wc -l | xargs
}

remove_stale_group_docs() {
  local groups_dir="${DOCS_DIR}/L2/groups"
  [[ -d "$groups_dir" ]] || return 0
  declare -A expected_groups=()
  local slug name path_prefix components page page_slug
  while IFS='|' read -r slug name path_prefix components; do expected_groups["$slug"]=1; done < <(parse_groups)
  while IFS= read -r page; do
    page_slug=${page##*/}; page_slug=${page_slug%.md}
    if [[ -z "${expected_groups[$page_slug]+x}" ]]; then
      rm -f "$page"
      log "WRITE_GROUPS/${page_slug} — removed stale group page"
    fi
  done < <(find "$groups_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null)
}

phase_write_groups() {
  local groups_file="${DOCS_DIR}/builder/specs/component-groups.md"
  if [[ ! -f "$groups_file" ]]; then
    remove_stale_group_docs
    log "WRITE_GROUPS — skipped (no component-groups.md)"
    return
  fi

  local total
  total=$(count_groups)
  validate_component_groups || return 1
  if (( total == 0 )); then
    remove_stale_group_docs
    log "WRITE_GROUPS — skipped (all components are standalone)"
    return 0
  fi

  mkdir -p "${DOCS_DIR}/L2/groups"
  remove_stale_group_docs
  log "WRITE_GROUPS — started (${total} groups)"

  local i=0
  local failures=0
  while IFS='|' read -r slug name path_prefix components; do
    i=$((i + 1))

    # Resume support. Update mode forces regeneration so membership changes are
    # reflected even when a group page already exists from a prior run.
    if [[ "${DEEP_DOCS_FORCE_GROUP_REFRESH:-0}" != "1" && -f "${DOCS_DIR}/L2/groups/${slug}.md" ]]; then
      log "WRITE_GROUPS/${slug} — skipped (exists, ${i}/${total})"
      continue
    fi

    log "WRITE_GROUPS/${slug} — started (${i}/${total})"
    local group_marker="${SCRATCH}/write-group-${slug}-complete.md"
    rm -f "$group_marker"

    # Build list of member L2/L3 files from the components field
    local member_l2_files=""
    local member_l3_files=""
    IFS=',' read -ra member_slugs <<< "$components"
    for msraw in "${member_slugs[@]}"; do
      local ms
      ms=$(echo "$msraw" | xargs)  # trim whitespace
      [[ -z "$ms" ]] && continue
      [[ -f "${DOCS_DIR}/L2/${ms}.md" ]] && member_l2_files="${member_l2_files}
- ${DOCS_DIR}/L2/${ms}.md"
      [[ -f "${DOCS_DIR}/L3/${ms}.md" ]] && member_l3_files="${member_l3_files}
- ${DOCS_DIR}/L3/${ms}.md"
    done

    local task="Write a module/subsystem overview for the '${name}' group.

Read these inputs:
- ${groups_file} (find your group's entry and member list)
- L2 docs for member components: ${member_l2_files}
- L3 docs for member components (for architecture context): ${member_l3_files}
- Synthesis notes: ${SCRATCH}/synthesise-*.md (for cross-component flows)
- Diagrams: ${DOCS_DIR}/diagrams/ (embed relevant ones)

Write ONE file: ${DOCS_DIR}/L2/groups/${slug}.md

Structure:
1. Overview — What this module/subsystem does as a unit (2-3 paragraphs)
2. Component Map — Table: Package | Type | Purpose (categorise by: API, UI, Database, Integration, Infrastructure, Contracts/Models, Search, etc.)
3. Internal Architecture — Mermaid diagram showing how packages within the group relate. Show data flow direction.
4. Data Model — Key entities/schemas owned by this group. Simple ER diagram if >3 entity types.
5. Integration Points — Events published, events consumed, contracts exposed, cross-module dependencies.
6. Key Business Rules — Important domain logic in plain language.
7. Operational Notes — Deployment units, infra dependencies, monitoring.

Audience: architects, tech leads, BAs, new team members.
Length: 3-6 pages. Use mermaid diagrams liberally.

After the group page is complete, write ${group_marker} with the final non-empty line:
GROUP_WRITE_COMPLETE

${HARD_RULES}"

    if spawn_agent "$task" "write-group-${slug}" "$TIMEOUT" "$(model_for high)" > /dev/null &&
       [[ -s "${DOCS_DIR}/L2/groups/${slug}.md" && -f "$group_marker" ]] &&
       [[ "$(/usr/bin/awk 'NF{line=$0} END{print line}' "$group_marker")" == "GROUP_WRITE_COMPLETE" ]]; then
      log "WRITE_GROUPS/${slug} — complete (${i}/${total})"
    else
      log "WRITE_GROUPS/${slug} — ❌ retrying (${i}/${total})"
      rm -f "$group_marker"
      if spawn_agent "$task" "write-group-${slug}-retry" "$TIMEOUT" "$(model_for high)" > /dev/null &&
         [[ -s "${DOCS_DIR}/L2/groups/${slug}.md" && -f "$group_marker" ]] &&
         [[ "$(/usr/bin/awk 'NF{line=$0} END{print line}' "$group_marker")" == "GROUP_WRITE_COMPLETE" ]]; then
        log "WRITE_GROUPS/${slug} — complete on retry (${i}/${total})"
      else
        log "WRITE_GROUPS/${slug} — ❌ SKIPPED (${i}/${total})"
        echo "- Group: ${name} (${slug}): no group doc produced" >> "${DOCS_DIR}/builder/skipped-components.md"
        failures=$((failures + 1))
      fi
    fi
  done < <(parse_groups)

  local group_count
  group_count=$(find "${DOCS_DIR}/L2/groups" -name "*.md" 2>/dev/null | wc -l | xargs)
  log "WRITE_GROUPS — complete (${group_count}/${total} group docs)"
  (( failures == 0 ))
}

# ============================================================
# PHASE: write
# ============================================================
phase_write() {
  local total
  total=$(count_components)
  log "WRITE — started (${total} components)"

  local i=0
  while IFS='|' read -r slug name path files; do
    i=$((i + 1))

    # Check if all three files exist (resume support)
    if [[ -f "${DOCS_DIR}/L2/${slug}.md" && -f "${DOCS_DIR}/L3/${slug}.md" && -f "${DOCS_DIR}/L4/${slug}.md" ]]; then
      log "WRITE/${slug} — skipped (L2/L3/L4 exist, ${i}/${total})"
      continue
    fi

    log "WRITE/${slug} — started (${i}/${total})"

    local task="Write documentation for the '${name}' component.

Read these inputs:
- ${SCRATCH}/comprehend-${slug}-summary.md (comprehension summary)
- Any relevant loop scratchpads: ${SCRATCH}/comprehend-${slug}-*.md
- Synthesis notes: ${SCRATCH}/synthesise-*.md
- Diagrams: ${DOCS_DIR}/diagrams/ (embed by copying .mmd source into \`\`\`mermaid fences)
- Source code at ${REPO_PATH}/${path} (for verification only)

Write THREE files:

${DOCS_DIR}/L2/${slug}.md
- Audience: BAs, PMs, non-engineers
- What this component does and why it exists
- Data flows with mermaid diagrams
- Business rules and logic in plain language
- 2-4 pages

${DOCS_DIR}/L3/${slug}.md
- Audience: developers, maintainers
- Architecture and design decisions
- Code structure with file references
- Patterns, configuration, error handling, gotchas
- Include code snippets where helpful

${DOCS_DIR}/L4/${slug}.md
- Audience: AI agents
- NO PROSE — headings, tables, and code blocks only
- File inventory, function signatures, schemas
- Env vars, CLI flags, constants, dependencies

${HARD_RULES}"

    local result
    result=$(spawn_agent "$task" "write-${slug}" "$TIMEOUT" "$(model_for high)")

    # Verify outputs
    local written=0
    [[ -f "${DOCS_DIR}/L2/${slug}.md" ]] && written=$((written + 1))
    [[ -f "${DOCS_DIR}/L3/${slug}.md" ]] && written=$((written + 1))
    [[ -f "${DOCS_DIR}/L4/${slug}.md" ]] && written=$((written + 1))

    if (( written == 3 )); then
      log "WRITE/${slug} — complete (L2+L3+L4, ${i}/${total})"
    elif (( written > 0 )); then
      log "WRITE/${slug} — partial (${written}/3 files, ${i}/${total})"
    else
      log "WRITE/${slug} — ❌ no files produced, retrying (${i}/${total})"
      result=$(spawn_agent "$task" "write-${slug}-retry" "$TIMEOUT" "$(model_for high)")
      written=0
      [[ -f "${DOCS_DIR}/L2/${slug}.md" ]] && written=$((written + 1))
      [[ -f "${DOCS_DIR}/L3/${slug}.md" ]] && written=$((written + 1))
      [[ -f "${DOCS_DIR}/L4/${slug}.md" ]] && written=$((written + 1))
      if (( written > 0 )); then
        log "WRITE/${slug} — complete on retry (${written}/3, ${i}/${total})"
      else
        log "WRITE/${slug} — ❌ SKIPPED after retry (${i}/${total})"
        echo "- ${name} (${slug}): no docs produced after 2 attempts" >> "${DOCS_DIR}/builder/skipped-components.md"
      fi
    fi
  done < <(parse_components)

  # Write group overviews (after all per-component docs)
  phase_write_groups

  # Write overviews and L1
  log "WRITE/overviews — started"

  spawn_agent "Write the system-level L2 overview. Read all L2 docs in ${DOCS_DIR}/L2/ and synthesis notes in ${SCRATCH}/synthesise-*.md. Write ${DOCS_DIR}/L2/overview.md covering system architecture, component relationships, end-to-end flows. Embed relevant diagrams from ${DOCS_DIR}/diagrams/. ${HARD_RULES}" "write-l2-overview" "$TIMEOUT" "$(model_for high)" > /dev/null
  log "WRITE/L2/overview.md — complete"

  spawn_agent "Write the L4 system overview for AI agents. Read the first 20 lines of each L4 file in ${DOCS_DIR}/L4/ plus ${DOCS_DIR}/diagrams/dependencies.mmd. Write ${DOCS_DIR}/L4/OVERVIEW.md — NO PROSE, only headings, tables, code blocks. Include: full file inventory, dependency graph, all env vars, all CLI entry points. ${HARD_RULES}" "write-l4-overview" "$TIMEOUT" "$(model_for high)" > /dev/null
  log "WRITE/L4/OVERVIEW.md — complete"

  spawn_agent "Write the executive summary (LAST document). Read all L2 docs in ${DOCS_DIR}/L2/ and ${DOCS_DIR}/builder/interview-notes.md. Write ${DOCS_DIR}/L1/executive-summary.md — 1 page max, no code, no jargon. What the project does, business value, key components, current status, key risks. ${HARD_RULES}" "write-l1" "$TIMEOUT" "$(model_for high)" > /dev/null
  log "WRITE/L1/executive-summary.md — complete"

  local l2_count l3_count l4_count
  l2_count=$(find "${DOCS_DIR}/L2" -name "*.md" | wc -l | xargs)
  l3_count=$(find "${DOCS_DIR}/L3" -name "*.md" | wc -l | xargs)
  l4_count=$(find "${DOCS_DIR}/L4" -name "*.md" | wc -l | xargs)
  log "WRITE — complete (L2: ${l2_count}, L3: ${l3_count}, L4: ${l4_count} files)"
}

# ============================================================
# PHASE: discover
# ============================================================
phase_discover() {
  log "DISCOVER — started"
  
  local task="You are running Phase 2 (DISCOVER) of deep-docs.

Read ${DOCS_DIR}/builder/interview-notes.md for context.

Explore the repository at ${REPO_PATH} thoroughly.
Exclusions: node_modules, bin, obj, dist, .git, __pycache__, .vscode, plus any from interview notes.

1. INVENTORY — Walk the entire file tree (respecting exclusions). Catalogue languages, frameworks, package managers. Count files per directory.

2. COMPONENT DETECTION — Component boundaries MUST be structural, not judgement-based:
   a) PACKAGE-MANAGER ANCHORED: Run \`find ${REPO_PATH} -name 'package.json' -o -name 'Cargo.toml' -o -name 'pyproject.toml' -o -name 'go.mod' -o -name '*.csproj' -o -name 'pom.xml'\` (excluding node_modules etc). Each match = one component.
   b) MONOREPO WORKSPACES: If root defines workspaces (package.json workspaces, pnpm-workspace.yaml, Cargo workspace), enumerate every workspace entry. Each = one component.
   c) INFRASTRUCTURE: Directories with Dockerfile, Bicep/ARM, Terraform/CDKTF, or CI pipelines = components (unless inside a package from rule a).
   d) FALLBACK: If no package managers, each top-level source directory = one component.
   DETERMINISM: Use find/ls to enumerate exhaustively. Do NOT sample. Same repo state must produce the same components on every run.
   For each: directory, SOURCE FILE COUNT, language, entry points, purpose. Detect inter-component dependencies.

3. EXISTING DOCS — Find .md files, doc comments, OpenAPI specs. Assess quality.

4. STACK DETECTION — Languages, frameworks, infrastructure, data stores.

OUTPUT two files:

${DOCS_DIR}/builder/specs/scope-and-goals.md
${DOCS_DIR}/builder/specs/component-inventory.md

Use this table format for the inventory:
| # | Component | Slug | Path | Source Files | Language | Purpose | Key Files | Dependencies |

IMPORTANT: Each package/workspace is its own component. Do NOT collapse multiple packages into one 'module' entry. If a module has 6 packages (contracts, cosmos, app, api, ui, infra), that's 6 components.

${HARD_RULES}"

  spawn_agent "$task" "discover" 600 "$(model_for economy)" > /dev/null

  if [[ -f "$INVENTORY" ]]; then
    # Rewrite slugs deterministically from paths (LLM-generated slugs are non-deterministic)
    stabilise_slugs "$INVENTORY"
    local count
    count=$(count_components)
    log "DISCOVER — complete (${count} components, slugs stabilised)"
  else
    log "DISCOVER — ❌ failed"
    exit 1
  fi
}

# ============================================================
# PHASE: update_inventory (update mode)
# ============================================================
phase_update_inventory() {
  log "UPDATE_INVENTORY — started"
  mkdir -p "$SCRATCH" "${DOCS_DIR}/builder/specs"

  local old_inventory="${SCRATCH}/inventory-before-update.md"
  local refresh_marker="${SCRATCH}/inventory-refresh-complete.md"
  local groups_file="${DOCS_DIR}/builder/specs/component-groups.md"
  local old_groups="${SCRATCH}/component-groups-before-update.md"

  if [[ -f "$refresh_marker" && -f "$old_inventory" && -f "${SCRATCH}/inventory-delta.md" ]]; then
    if validate_inventory "$INVENTORY" && validate_component_groups; then
      log "UPDATE_INVENTORY — resumed (validated current inventory and groups)"
      return 0
    fi
    log "UPDATE_INVENTORY — prior refresh invalid; regenerating"
    rm -f "$refresh_marker" "${SCRATCH}/inventory-delta.md"
  fi

  [[ -f "$INVENTORY" ]] || {
    log "UPDATE_INVENTORY — ❌ missing component inventory"
    return 1
  }
  # Capture inventory and groups together once. Absence of old_groups means the
  # successful baseline had no group file; never capture a partially refreshed one.
  if [[ ! -f "$old_inventory" ]]; then
    if [[ -f "$groups_file" ]]; then
      cp "$groups_file" "$old_groups" || return 1
    else
      rm -f "$old_groups"
    fi
    cp "$INVENTORY" "$old_inventory" || return 1
  fi

  local task="Refresh the component inventory for an incremental documentation update.

Read:
- Existing inventory: ${old_inventory}
- Existing groups: ${groups_file} (if present)
- Discovery rules: ${SKILL_DIR}/references/discover.md
- Source repository: ${REPO_PATH}

Re-enumerate component boundaries exhaustively from the CURRENT source tree. Package-manager
anchors and declared monorepo workspaces are mandatory components; do not sample. Update
${INVENTORY} in place so it contains every current component and no removed component.

Rules:
- Preserve each surviving component's existing slug by matching its Path from the old inventory.
- Derive a hyphenated deterministic slug only for genuinely new paths.
- Keep the exact inventory table schema used by the existing file.
- Recount source files and refresh names, languages, purpose, key files and dependencies.
- If ${groups_file} exists, reconcile groups and standalone components; remove deleted slugs.
  Preserve established group slugs. Every current slug must occur exactly once: either in a group
  or in a '## Standalone Components' table with columns '| Component | Path | Reason |'.
  Do NOT invent singleton groups. If no groups exist, use an empty group table and the note
  'No component groups detected — all components are standalone.'
- Do not modify any source file.

After writing the inventory and groups, write ${refresh_marker} with the final non-empty line:
INVENTORY_REFRESH_COMPLETE

${HARD_RULES}"

  local refresh_ok=false refresh_attempt
  for refresh_attempt in 1 2; do
    rm -f "$refresh_marker"
    if spawn_agent "$task" "update-inventory-${refresh_attempt}" "$TIMEOUT" "$(model_for high)" > /dev/null &&
       [[ -f "$refresh_marker" ]] &&
       [[ "$(/usr/bin/awk 'NF{line=$0} END{print line}' "$refresh_marker")" == "INVENTORY_REFRESH_COMPLETE" ]]; then
      refresh_ok=true
      break
    fi
    log "UPDATE_INVENTORY — refresh attempt ${refresh_attempt}/2 incomplete"
  done

  if [[ "$refresh_ok" != "true" ]]; then
    cp "$old_inventory" "$INVENTORY"
    if [[ -f "$old_groups" ]]; then
      cp "$old_groups" "$groups_file"
    else
      rm -f "$groups_file"
    fi
    rm -f "$refresh_marker" "${SCRATCH}/inventory-delta.md"
    log "UPDATE_INVENTORY — ❌ refresh agent did not produce a completion marker"
    return 1
  fi

  if ! reconcile_inventory_slugs "$old_inventory" "$INVENTORY" || ! validate_inventory "$INVENTORY"; then
    cp "$old_inventory" "$INVENTORY"
    if [[ -f "$old_groups" ]]; then
      cp "$old_groups" "$groups_file"
    else
      rm -f "$groups_file"
    fi
    rm -f "$refresh_marker" "${SCRATCH}/inventory-delta.md"
    log "UPDATE_INVENTORY — ❌ refreshed inventory failed validation"
    return 1
  fi
  write_inventory_delta "$old_inventory" "$INVENTORY" "${SCRATCH}/inventory-delta.md"
  if ! validate_component_groups; then
    cp "$old_inventory" "$INVENTORY"
    if [[ -f "$old_groups" ]]; then
      cp "$old_groups" "$groups_file"
    else
      rm -f "$groups_file"
    fi
    rm -f "$refresh_marker" "${SCRATCH}/inventory-delta.md"
    log "UPDATE_INVENTORY — ❌ refreshed component groups failed validation"
    return 1
  fi

  local new_count removed_count total
  new_count=$(grep -c '| NEW |' "${SCRATCH}/inventory-delta.md" 2>/dev/null || true)
  removed_count=$(grep -c '| REMOVED |' "${SCRATCH}/inventory-delta.md" 2>/dev/null || true)
  total=$(count_components)
  log "UPDATE_INVENTORY — complete (${total} current, ${new_count} new, ${removed_count} removed)"
}

# ============================================================
# PHASE: review
# ============================================================
is_removal_only_update() {
  [[ "$PHASE" == "update" ]] || return 1
  validate_diff_inventory_delta || return 1
  local slug classification count=0
  while IFS='|' read -r slug classification; do
    [[ "$classification" == "REMOVED" ]] || return 1
    count=$((count + 1))
  done < <(parse_affected_components)
  (( count > 0 ))
}

system_review_is_clean() {
  [[ -f "${SCRATCH}/review-system.md" ]] || return 1
  /usr/bin/awk '
    {
      sub(/\r$/, "")
      if ($0 == "SYSTEM_REVIEW_CLEAN" || $0 ~ /^SYSTEM_REVIEW_ISSUES: [0-9]+ unresolved$/) markers++
      if (NF) last=$0
    }
    END { exit !(markers == 1 && last == "SYSTEM_REVIEW_CLEAN") }
  ' "${SCRATCH}/review-system.md"
}

system_review_fingerprint() {
  # Package owns index/nav, so these are checked by package validation, not this
  # semantic review. Bind the review to the remaining documentation and delta.
  {
    printf 'range=%s\n' "$UPDATE_RUN_KEY"
    /usr/bin/sha256sum "$INVENTORY" "${SCRATCH}/inventory-delta.md" "${SCRATCH}/update-diff.md"
    [[ ! -f "${DOCS_DIR}/builder/specs/component-groups.md" ]] || /usr/bin/sha256sum "${DOCS_DIR}/builder/specs/component-groups.md"
    find "${DOCS_DIR}/L1" "${DOCS_DIR}/L2" "${DOCS_DIR}/L3" "${DOCS_DIR}/L4" "${DOCS_DIR}/diagrams" -type f -print0 2>/dev/null |
      sort -z | xargs -0 -r /usr/bin/sha256sum
  } | /usr/bin/sha256sum | /usr/bin/awk '{print $1}'
}

phase_review_removed_only() {
  is_removal_only_update && validate_update_outputs && validate_current_docs || return 1
  local review_file="${SCRATCH}/review-system.md"
  rm -f "$review_file" "${SCRATCH}/review-system.fingerprint"
  local task="Review this removal-only documentation update against pinned source ${HEAD_COMMIT}.
Read ${SCRATCH}/update-diff.md, ${SCRATCH}/inventory-delta.md, ${INVENTORY}, and
${DOCS_DIR}/builder/specs/component-groups.md if present. Verify the removed components are
absent from source and current inventory/groups; their L2/L3/L4 pages must be absent.
Review ${DOCS_DIR}/L1/, L2/, L3/, L4/, diagrams/ for stale references to removed components,
incorrect counts, broken cross-references, and obsolete system descriptions. Check surviving
components still have all three tiers. Fix documentation errors, never source; preserve HUMAN blocks.
Index and MkDocs navigation will be regenerated and mechanically validated after this review.
Write ${review_file} documenting the checks and unresolved issues. The final non-empty line must
be exactly SYSTEM_REVIEW_CLEAN or SYSTEM_REVIEW_ISSUES: N unresolved. Emit exactly one outcome.
Do not claim any removed component received a current-component review.
${HARD_RULES}"
  spawn_agent "$task" "review-system" "$TIMEOUT" "$(model_for high)" > /dev/null || return 1
  system_review_is_clean && validate_update_outputs && validate_current_docs || return 1
  system_review_fingerprint > "${SCRATCH}/review-system.fingerprint" || return 1
  {
    printf '# Removal-only Review\n\nCurrent affected component scope: 0. System-level removal review follows.\n\n'
    cat "$review_file"
  } > "${DOCS_DIR}/REVIEW.md"
  verify_review_scope || return 1
  log "REVIEW — removal-only system review complete (0 current affected components)"
}

phase_review() {
  log "REVIEW — started"
  mkdir -p "$SCRATCH"
  validate_reproducible_source || return 1
  if [[ -z "$HEAD_COMMIT" ]]; then
    HEAD_COMMIT=$(git -C "$REPO_PATH" rev-parse HEAD) || return 1
  fi
  assert_update_head_unchanged || return 1

  if ! build_review_scope "$REVIEW_SCOPE_FILE"; then
    log "REVIEW — ❌ could not build review scope"
    return 1
  fi

  local total
  total=$(wc -l < "$REVIEW_SCOPE_FILE" | xargs)
  if (( total == 0 )); then
    if is_removal_only_update; then
      phase_review_removed_only
      return $?
    fi
    log "REVIEW — ❌ empty review scope without validated removal-only changes"
    return 1
  fi

  # A selection limits dispatch, NEVER the acceptance/coverage scope.
  local selection="${DEEP_DOCS_REVIEW_SLUGS:-}" selected
  if [[ -n "$selection" ]]; then
    [[ "$selection" =~ ^[a-z0-9]+(-[a-z0-9]+)*(,[a-z0-9]+(-[a-z0-9]+)*)*$ ]] || {
      log "REVIEW — ❌ DEEP_DOCS_REVIEW_SLUGS must be comma-separated exact slugs"
      return 1
    }
    local -a selected_slugs
    IFS=',' read -ra selected_slugs <<< "$selection"
    for selected in "${selected_slugs[@]}"; do
      /usr/bin/awk -F'|' -v wanted="$selected" '$1 == wanted {found=1} END {exit !found}' "$REVIEW_SCOPE_FILE" || {
        log "REVIEW — ❌ selected slug not in required scope: $selected"
        return 1
      }
    done
  fi
  local review_key existing_review_key=""
  if [[ "$PHASE" == "update" ]]; then
    if [[ -z "$UPDATE_RUN_KEY" && -f "$UPDATE_STATE_FILE" ]]; then
      UPDATE_RUN_KEY=$(<"$UPDATE_STATE_FILE")
    fi
    review_key="v2:update:${UPDATE_RUN_KEY}:$(/usr/bin/sha256sum "$REVIEW_SCOPE_FILE" | /usr/bin/awk '{print $1}')"
  else
    review_key="v2:${PHASE}:${HEAD_COMMIT}:$(/usr/bin/sha256sum "$REVIEW_SCOPE_FILE" | /usr/bin/awk '{print $1}')"
  fi
  [[ -f "$REVIEW_STATE_FILE" ]] && existing_review_key=$(<"$REVIEW_STATE_FILE")
  if [[ "$existing_review_key" != "$review_key" ]]; then
    local reset_slug reset_name reset_path reset_files
    while IFS='|' read -r reset_slug reset_name reset_path reset_files; do
      rm -f "${SCRATCH}/review-${reset_slug}.md" "${SCRATCH}/review-${reset_slug}.fingerprint" "${SCRATCH}/review-${reset_slug}.previous.md"
    done < "$REVIEW_SCOPE_FILE"
    printf '%s\n' "$review_key" > "$REVIEW_STATE_FILE"
    log "REVIEW — fresh scope (${total} components); stale scoped reviews invalidated"
  else
    log "REVIEW — resuming current scope (${total} components)"
  fi

  local iteration=1
  local max_iterations="${DEEP_DOCS_REVIEW_MAX_ITERATIONS:-3}"
  [[ "$max_iterations" =~ ^[1-3]$ ]] || { log "REVIEW — ❌ max iterations must be 1, 2 or 3"; return 1; }
  local review_clean=false

  while (( iteration <= max_iterations )); do
    local review_model
    if (( iteration == 1 )); then
      review_model="$(model_for economy)"
    else
      review_model="$(model_for high)"
    fi
    log "REVIEW — iteration ${iteration}/${max_iterations} (model: ${review_model})"

    local i=0
    local slug name path files
    while IFS='|' read -r slug name path files; do
      i=$((i + 1))
      local review_file="${SCRATCH}/review-${slug}.md"
      local status
      status=$(review_status "$review_file" 2>/dev/null || true)
      if [[ "$status" == "clean" ]] && review_fingerprint_matches "$slug"; then
        log "REVIEW/${slug} — accepted current-run clean result (${i}/${total})"
        continue
      fi
      if [[ -n "$selection" && ",${selection}," != *",${slug},"* ]]; then
        log "REVIEW/${slug} — pending, outside retry selection (${i}/${total})"
        continue
      fi
      local previous_review="${SCRATCH}/review-${slug}.previous.md" component_model="$review_model"
      if [[ "$status" == "issues" ]]; then
        cp "$review_file" "$previous_review" || return 1
        component_model="$(model_for high)"
      fi
      rm -f "$review_file" "${SCRATCH}/review-${slug}.fingerprint"

      local missing_tiers=""
      [[ -f "${DOCS_DIR}/L2/${slug}.md" ]] || missing_tiers="${missing_tiers} L2"
      [[ -f "${DOCS_DIR}/L3/${slug}.md" ]] || missing_tiers="${missing_tiers} L3"
      [[ -f "${DOCS_DIR}/L4/${slug}.md" ]] || missing_tiers="${missing_tiers} L4"
      if [[ -n "$missing_tiers" ]]; then
        cat > "$review_file" << EOF
# Component Review: ${name}

| File | Issue Found | Severity | Action Taken |
|------|-------------|----------|--------------|
| ${slug} | Missing required documentation tiers:${missing_tiers} | Error | Not reviewable |

COMPONENT_ISSUES: 1 unresolved
EOF
        log "REVIEW/${slug} — COMPONENT_ISSUES missing${missing_tiers} (${i}/${total})"
        continue
      fi

      log "REVIEW/${slug} — started (${i}/${total})"
      local task="Review documentation for '${name}' against source code.

Read these component documents:
- ${DOCS_DIR}/L2/${slug}.md
- ${DOCS_DIR}/L3/${slug}.md
- ${DOCS_DIR}/L4/${slug}.md

Source repository (absolute, read-only): ${REPO_PATH}
Start with source at ${REPO_PATH}/${path}.
Follow specific imports, referenced schemas, root configuration and relevant consumer/infrastructure wiring
elsewhere inside this source repository when needed to verify a documented claim. Use targeted reads,
not a whole-repository dump. Read-only Git inspection of this repository is allowed.
Read permissions are repository-wide; documentation writes remain component-scoped.
Modify only the three component documents above and the named review file below.

Verify: file paths exist, function signatures match, env vars correct, described behaviour matches implementation, schemas match.

For errors/warnings: FIX the documentation (not source code).
Resolve repository-answerable questions with the permitted targeted source reads.
For generated claims that cannot be supported, remove the unsupported assertion or state precisely
the source-confirmed behaviour and its evidence boundary. Keep genuinely unknown external context
explicitly labelled <!-- UNVERIFIED --> and report it separately as an evidence limitation.
Lack of runtime execution or an optional automated check is not itself a documentation error;
do not imply those checks ran. Do not install dependencies, access live services or bypass command approvals.
A marker alone never resolves an unsupported material claim.
Preserve HUMAN blocks verbatim. Material unsupported HUMAN claims remain unresolved; do not edit or waive them.
COMPONENT_ISSUES counts remaining factual errors, misleading/incomplete material claims and missing
required verification of such claims, not merely accurately stated limits of this source-only review.
Never obtain clean status by relabelling a remaining material issue as a limitation.

Write ${review_file} with:
| File | Issue Found | Severity | Action Taken |

The FINAL NON-EMPTY LINE of the review file and your response MUST be exactly one of:
COMPONENT_CLEAN
COMPONENT_ISSUES: N unresolved

Never omit the marker. Never report clean while any issue remains.

${HARD_RULES}"

      if [[ -s "$previous_review" ]]; then
        component_model="$(model_for high)"
        task+=$'\n'"Previous unresolved findings: ${previous_review}. Read these first, resolve or retain each material finding against source; do not repeat an unfocused full audit or erase findings by relabelling them."
      fi
      local attempt=1
      local agent_status
      while (( attempt <= 2 )); do
        status=""
        spawn_agent "$task" "review-${slug}-attempt-${attempt}" "$TIMEOUT" "$component_model" > /dev/null
        agent_status=$?
        if (( agent_status == 0 )); then
          assert_update_head_unchanged || { rm -f "$review_file"; return 1; }
          status=$(review_status "$review_file" 2>/dev/null || true)
        fi
        [[ -n "$status" ]] && break
        log "REVIEW/${slug} — failed process (${agent_status}) or malformed/missing result (${i}/${total})"
        rm -f "$review_file" "${SCRATCH}/review-${slug}.fingerprint"
        (( agent_status == 75 || agent_status == 78 || agent_status == 130 || agent_status == 143 )) && return "$agent_status"
        attempt=$((attempt + 1))
      done

      case "$status" in
        clean)
          if review_input_fingerprint "$slug" > "${SCRATCH}/review-${slug}.fingerprint"; then
            log "REVIEW/${slug} — complete: COMPONENT_CLEAN (${i}/${total})"
          else
            rm -f "${SCRATCH}/review-${slug}.fingerprint"
            status=""
            log "REVIEW/${slug} — ❌ could not fingerprint reviewed inputs (${i}/${total})"
          fi
          ;;
        issues)
          rm -f "${SCRATCH}/review-${slug}.fingerprint"
          local n_issues
          n_issues=$(tail -1 "$review_file" | /usr/bin/grep -oE '[0-9]+' | tail -1 || echo "?")
          log "REVIEW/${slug} — complete: COMPONENT_ISSUES ${n_issues} unresolved (${i}/${total})"
          ;;
        *)
          log "REVIEW/${slug} — ❌ missing or malformed result after retry (${i}/${total})"
          ;;
      esac
    done < "$REVIEW_SCOPE_FILE"

    local counts clean issues unknown counted_total
    counts=$(review_scope_counts "$REVIEW_SCOPE_FILE")
    IFS='|' read -r clean issues unknown counted_total <<< "$counts"

    if (( clean == total && issues == 0 && unknown == 0 )); then
      review_clean=true
      log "REVIEW — iteration ${iteration}: REVIEW_CLEAN (${clean}/${total} required components clean)"
      break
    fi

    log "REVIEW — iteration ${iteration}: incomplete (${clean}/${total} clean, ${issues} issues, ${unknown} missing/malformed)"
    iteration=$((iteration + 1))
  done

  if [[ "$review_clean" != "true" ]]; then
    printf '# Documentation Review\n\nIncomplete scoped result: `%s`\n' "$(review_scope_counts "$REVIEW_SCOPE_FILE")" > "${DOCS_DIR}/REVIEW.md"
    log "REVIEW — ❌ incomplete; successful fingerprints retained, retry pending slugs with DEEP_DOCS_REVIEW_SLUGS"
    return 1
  fi
  log "REVIEW/aggregate — started"
  local aggregate_marker="${SCRATCH}/review-aggregate-complete.md"
  local aggregate_fingerprint="${SCRATCH}/review-aggregate.fingerprint"
  local aggregate_ok=false
  if [[ -s "$aggregate_fingerprint" && -s "$aggregate_marker" &&
        "$(/usr/bin/awk 'NF{line=$0} END{print line}' "$aggregate_marker")" == "REVIEW_AGGREGATE_COMPLETE" &&
        "$(<"$aggregate_fingerprint")" == "$(review_aggregate_fingerprint)" ]] &&
     verify_review_scope && assert_update_head_unchanged; then
    log "REVIEW — complete (unchanged aggregate and successful scoped results reused)"
    return 0
  fi
  rm -f "$aggregate_fingerprint"
  rm -f "$aggregate_marker"
  if spawn_agent "Aggregate the component reviews listed in ${REVIEW_SCOPE_FILE} into ${DOCS_DIR}/REVIEW.md. Read exactly the corresponding ${SCRATCH}/review-<slug>.md files. Summarise clean, unresolved, missing and malformed results. Do not treat absent markers as clean. Then write ${aggregate_marker} with the final non-empty line REVIEW_AGGREGATE_COMPLETE. ${HARD_RULES}" "review-aggregate" "$TIMEOUT" "$(model_for high)" > /dev/null &&
     [[ -f "${DOCS_DIR}/REVIEW.md" && -f "$aggregate_marker" ]] &&
     [[ "$(/usr/bin/awk 'NF{line=$0} END{print line}' "$aggregate_marker" 2>/dev/null)" == "REVIEW_AGGREGATE_COMPLETE" ]]; then
    aggregate_ok=true
  else
    local final_counts
    final_counts=$(review_scope_counts "$REVIEW_SCOPE_FILE")
    printf '# Documentation Review\n\nAutomated scoped result: `%s`\n' "$final_counts" > "${DOCS_DIR}/REVIEW.md"
    log "REVIEW/aggregate — ❌ aggregation failed or omitted its completion marker"
  fi
  log "REVIEW/aggregate — complete"

  if [[ "$review_clean" != "true" ]] || ! verify_review_scope "$REVIEW_SCOPE_FILE"; then
    log "REVIEW — ❌ incomplete after ${max_iterations} iterations"
    return 1
  fi
  if [[ "$aggregate_ok" != "true" ]]; then
    return 1
  fi

  assert_update_head_unchanged || return 1
  review_aggregate_fingerprint > "$aggregate_fingerprint" || return 1
  log "REVIEW — complete"
}

# ============================================================
# PHASE: diff_discovery (update mode)
# ============================================================
phase_diff_discovery() {
  log "DIFF_DISCOVERY — started"

  local last_run_date
  last_run_date=$(read_last_run_field date)
  if [[ -n "$BASE_COMMIT" ]]; then
    log "DIFF_DISCOVERY — baseline commit: ${BASE_COMMIT} (last run: ${last_run_date:-unknown})"
  else
    log "DIFF_DISCOVERY — no usable baseline commit; comparing current inventory and source directly"
  fi

  # Pre-compute one immutable commit range for every later update phase.
  local git_diff_file="${SCRATCH}/git-diff-raw.md"
  mkdir -p "$SCRATCH"
  if [[ -n "$BASE_COMMIT" ]]; then
    {
      echo "# Git Changes: ${BASE_COMMIT}..${HEAD_COMMIT}"
      echo
      echo "## Commits"
      git -C "$REPO_PATH" log --oneline "${BASE_COMMIT}..${HEAD_COMMIT}" -- .
      echo
      echo "## Files Changed (name-status)"
      git -C "$REPO_PATH" diff --name-status "${BASE_COMMIT}..${HEAD_COMMIT}" -- .
      echo
      echo "## Diffstat"
      git -C "$REPO_PATH" diff --stat "${BASE_COMMIT}..${HEAD_COMMIT}" -- .
    } > "$git_diff_file"
    log "DIFF_DISCOVERY — git diff pre-computed to ${git_diff_file}"
  else
    echo "# No usable Git baseline — full source/documentation comparison required" > "$git_diff_file"
  fi

  local task="You are running DIFF DISCOVERY for a documentation update.

Source repository (absolute, read-only): ${REPO_PATH}
Pinned source comparison: ${BASE_COMMIT}..${HEAD_COMMIT}
Resolve changed source paths relative to that repository, not the documentation directory.

Map git changes to documented components. Do NOT read L4 docs — use the
component inventory to map file paths to component slugs.

Read ONLY these files:
- ${INVENTORY} (current component list with paths — use this to map changed files to components)
- ${SCRATCH}/inventory-before-update.md (inventory from the prior successful run)
- ${SCRATCH}/inventory-delta.md (mechanically derived NEW, REMOVED and STRUCTURAL component paths)
- ${LAST_RUN_FILE} (last run metadata)
- ${git_diff_file} (pre-computed git diff — already generated, just read it)

For MODIFIED components, you may read the specific changed source files listed in
the git diff to understand WHAT changed (not just that it changed). But do NOT read
L4 docs or any other documentation files.

Mapping rules:
- A changed file at path X belongs to the component whose Path column in the
  inventory is a prefix of X
- If a changed file doesn't match any component path, note it as unmapped
- Every NEW row in inventory-delta.md MUST appear in Affected Components as NEW.
- Every REMOVED row in inventory-delta.md MUST appear in Affected Components as REMOVED.
- Every STRUCTURAL row in inventory-delta.md MUST appear in Affected Components as STRUCTURAL.
- Never classify a component still present in the current inventory as REMOVED.
- Do not introduce NEW, REMOVED or STRUCTURAL rows absent from inventory-delta.md.
- STRUCTURAL is reserved for component Path changes recorded in inventory-delta.md.
- File moves between components whose Path values are unchanged are MODIFIED
  for each affected existing component; describe the moved files in What Changed and Detail.
  Internal file renames, extracted helpers and transferred exports do not make a component STRUCTURAL.

Produce ${SCRATCH}/update-diff.md with this structure:

## Summary
- Total components: N
- Changed: N (NEW: N, MODIFIED: N, REMOVED: N, STRUCTURAL: N)
- Unchanged: N

## Affected Components
| Slug | Classification | What Changed |
|------|---------------|--------------|
| ... | NEW/MODIFIED/REMOVED/STRUCTURAL | Specific description |

## Unchanged Components
| Slug | Status |
|------|--------|
| ... | UNCHANGED |

## Detail
For each MODIFIED component, describe specifically what changed:
- Which source files were added/removed/modified
- Brief description of the nature of changes (read the actual changed files)

Classifications:
- NEW: component paths present in the current inventory but absent from inventory-before-update.md
- MODIFIED: source files changed since last run within a documented component
- REMOVED: component paths present in inventory-before-update.md but absent from the current inventory
- STRUCTURAL: an existing component's Path changed, with an exact matching STRUCTURAL inventory-delta row
- UNCHANGED: no git changes in the component's directory

List affected components in dependency order.

If NO changes detected: output NO_CHANGES_DETECTED as the final line.

${HARD_RULES}"

  # A new invocation requires a fresh artifact AND a successful agent exit.
  rm -f "${SCRATCH}/update-diff.md"
  if ! spawn_agent "$task" "diff-discovery" "$TIMEOUT" "$(model_for high)" > /dev/null; then
    rm -f "${SCRATCH}/update-diff.md"
    log "DIFF_DISCOVERY — ❌ diff agent failed"
    return 2  # 1 is reserved for validated no-change, never an agent failure.
  fi

  if [[ -f "${SCRATCH}/update-diff.md" ]]; then
    if ! validate_diff_inventory_delta; then
      log "DIFF_DISCOVERY — ❌ affected-component classifications do not match inventory delta"
      return 2
    fi
    if diff_reports_no_changes; then
      log "DIFF_DISCOVERY — complete: NO_CHANGES_DETECTED"
      return 1  # Signal no changes
    fi
    local affected
    affected=$(grep -cE '^\| .+ \| (NEW|MODIFIED|REMOVED|STRUCTURAL)' "${SCRATCH}/update-diff.md" 2>/dev/null || true)
    affected=${affected:-0}
    log "DIFF_DISCOVERY — complete (${affected} affected components)"
    return 0
  else
    log "DIFF_DISCOVERY — ❌ failed (no update-diff.md produced)"
    return 2
  fi
}

# Parse all rows from the affected-components section before validating classes.
parse_all_affected_rows() {
  [[ -f "${SCRATCH}/update-diff.md" ]] || return
  /usr/bin/awk -F'|' '
    /^## Affected Components[[:space:]]*$/ { in_affected=1; next }
    in_affected && /^##[[:space:]]/ { exit }
    in_affected && /^\|/ {
      slug=$2; classification=$3
      gsub(/`/, "", slug)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", slug)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", classification)
      if (slug != "" && slug != "Slug" && slug !~ /^-+$/ &&
          classification != "" && classification != "Classification" && classification !~ /^-+$/) {
        print slug "|" classification
      }
    }
  ' "${SCRATCH}/update-diff.md"
}

# Returns validated-class candidates as pipe-delimited lines: slug|classification
parse_affected_components() {
  parse_all_affected_rows | /usr/bin/awk -F'|' '$2 ~ /^(NEW|MODIFIED|REMOVED|STRUCTURAL)$/ { print $1 "|" $2 }'
}

diff_reports_no_changes() {
  local diff_file="${SCRATCH}/update-diff.md"
  [[ -f "$diff_file" ]] || return 1
  [[ "$(/usr/bin/awk 'NF { last=$0 } END { print last }' "$diff_file")" == "NO_CHANGES_DETECTED" ]]
}

validate_diff_inventory_delta() {
  local delta_file="${SCRATCH}/inventory-delta.md"
  local old_inventory="${SCRATCH}/inventory-before-update.md"
  [[ -f "$delta_file" && -f "$old_inventory" && -f "${SCRATCH}/update-diff.md" ]] || return 1

  declare -A old_paths=() current_paths=() expected=() seen=()
  local slug name path files classification expected_class affected_count=0 delta_count=0
  while IFS='|' read -r slug name path files; do old_paths["$slug"]="$path"; done < <(parse_components_file "$old_inventory")
  while IFS='|' read -r slug name path files; do current_paths["$slug"]="$path"; done < <(parse_components)
  while IFS='|' read -r slug classification; do
    [[ -z "$slug" ]] && continue
    if [[ -n "${expected[$slug]+x}" ]]; then
      echo "Duplicate inventory delta slug: $slug" >&2
      return 1
    fi
    expected["$slug"]="$classification"
    delta_count=$((delta_count + 1))
  done < <(/usr/bin/awk -F'|' '/^\| `[^`]+` \| (NEW|REMOVED|STRUCTURAL) \|/ {
    gsub(/`/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
    print $2 "|" $3
  }' "$delta_file")

  while IFS='|' read -r slug classification; do
    [[ -z "$slug" ]] && continue
    affected_count=$((affected_count + 1))
    if [[ -n "${seen[$slug]+x}" ]]; then
      echo "Duplicate/conflicting affected component row: $slug" >&2
      return 1
    fi
    seen["$slug"]="$classification"
    expected_class=${expected[$slug]:-}
    case "$classification" in
      NEW)
        [[ -n "${current_paths[$slug]+x}" && -z "${old_paths[$slug]+x}" && "$expected_class" == "NEW" ]] || {
          echo "Impossible NEW classification for component: $slug" >&2; return 1;
        }
        ;;
      REMOVED)
        [[ -n "${old_paths[$slug]+x}" && -z "${current_paths[$slug]+x}" && "$expected_class" == "REMOVED" ]] || {
          echo "Impossible REMOVED classification for component: $slug" >&2; return 1;
        }
        ;;
      STRUCTURAL)
        [[ -n "${old_paths[$slug]+x}" && -n "${current_paths[$slug]+x}" &&
           "${old_paths[$slug]}" != "${current_paths[$slug]}" && "$expected_class" == "STRUCTURAL" ]] || {
          echo "Impossible STRUCTURAL classification for component: $slug" >&2; return 1;
        }
        ;;
      MODIFIED)
        [[ -n "${old_paths[$slug]+x}" && -n "${current_paths[$slug]+x}" && -z "$expected_class" ]] || {
          echo "Impossible MODIFIED classification for component: $slug" >&2; return 1;
        }
        ;;
      *)
        echo "Unknown affected classification for ${slug}: ${classification}" >&2
        return 1
        ;;
    esac
  done < <(parse_all_affected_rows)

  for slug in "${!expected[@]}"; do
    if [[ "${seen[$slug]:-}" != "${expected[$slug]}" ]]; then
      echo "Inventory delta mismatch for ${slug}: expected ${expected[$slug]}, got ${seen[$slug]:-missing}" >&2
      return 1
    fi
  done

  if diff_reports_no_changes; then
    (( affected_count == 0 && delta_count == 0 )) || {
      echo "NO_CHANGES_DETECTED conflicts with affected or inventory-delta rows" >&2
      return 1
    }
  elif (( affected_count == 0 )); then
    echo "Diff report has neither affected components nor an exact terminal NO_CHANGES_DETECTED marker" >&2
    return 1
  fi
}

# Check if a slug is in the affected list
is_affected() {
  local slug="$1"
  parse_affected_components | grep -q "^${slug}|"
}

# Get classification for a slug
get_classification() {
  local slug="$1"
  parse_affected_components | grep "^${slug}|" | head -1 | cut -d'|' -f2
}

# ============================================================
# PHASE: update_comprehend (update mode)
# ============================================================
phase_update_comprehend() {
  local affected_count
  affected_count=$(parse_affected_components | grep -cE '\|(NEW|MODIFIED|STRUCTURAL)$' || true)
  affected_count=${affected_count:-0}
  log "UPDATE_COMPREHEND — started (${affected_count} components to re-comprehend)"

  if (( affected_count == 0 )); then
    log "UPDATE_COMPREHEND — skipped (no NEW, MODIFIED or STRUCTURAL components)"
    return
  fi

  local total
  total=$(count_components)
  local i=0
  local failures=0

  while IFS='|' read -r slug name path files; do
    i=$((i + 1))

    local classification
    classification=$(get_classification "$slug")

    # Re-comprehend every current affected component.
    if [[ "$classification" != "NEW" && "$classification" != "MODIFIED" && "$classification" != "STRUCTURAL" ]]; then
      continue
    fi

    # Resume support
    if [[ -f "${SCRATCH}/update-comprehend-${slug}-summary.md" ]]; then
      log "UPDATE_COMPREHEND/${slug} — skipped (summary exists)"
      continue
    fi

    local files_int="${files//[^0-9]/}"
    files_int="${files_int:-0}"

    # ── Trivial change detection ──────────────────────────────
    # Use git log directly to check what actually changed in this component.
    # Structural check — doesn't depend on how the diff agent worded things.
    local is_trivial=false
    if [[ -n "$BASE_COMMIT" && -n "$path" ]]; then
      local changed_files=""
      changed_files=$(git -C "$REPO_PATH" diff --name-only "${BASE_COMMIT}..${HEAD_COMMIT}" -- "$path" | /usr/bin/sort -u | /usr/bin/grep '[^[:space:]]' || true)
      local changed_count=0
      changed_count=$(echo "$changed_files" | /usr/bin/grep -c '[^[:space:]]' || true)
      changed_count=${changed_count:-0}

      # Count source code files (exclude config: json, yaml, yml, md, env, etc.)
      local code_files=0
      if [[ -n "$changed_files" ]]; then
        code_files=$(echo "$changed_files" | /usr/bin/grep -cvE '\.(json|yaml|yml|config|env|md)$|package-lock' || true)
        code_files=${code_files:-0}
      fi

      # Trivial if: files changed but none are source code (config-only)
      if [[ "$changed_count" -gt 0 && "$code_files" -eq 0 ]] 2>/dev/null; then
        is_trivial=true
      fi

      # Also trivial if: ≤1 file changed AND ≤5 net lines
      if [[ "$changed_count" -le 1 ]] 2>/dev/null; then
        local net_lines=0
        net_lines=$(git -C "$REPO_PATH" diff --numstat "${BASE_COMMIT}..${HEAD_COMMIT}" -- "$path" | /usr/bin/awk '{a+=$1;d+=$2}END{print a+d+0}')
        if [[ "$net_lines" -le 5 && "$net_lines" -gt 0 ]] 2>/dev/null; then
          is_trivial=true
        fi
      fi
    fi

    if [[ "$is_trivial" == "true" ]]; then
      log "UPDATE_COMPREHEND/${slug} — trivial change, writing minimal summary"
      # Extract the "What Changed" description from the affected components table
      local what_changed=""
      what_changed=$(awk -F'|' "/\`${slug}\`.*MODIFIED/ {gsub(/^[[:space:]]+|[[:space:]]+\$/,\"\",\$4); print \$4}" "${SCRATCH}/update-diff.md" 2>/dev/null | head -1)
      cat > "${SCRATCH}/update-comprehend-${slug}-summary.md" << TRIVIAL_EOF
# Updated Comprehend Summary: ${name}

## Changes Since Last Run

**Classification:** MODIFIED (trivial/config-only)

### What Changed
${what_changed:-Minor configuration change — see update-diff.md for details.}

### Impact
No functional code changes. Documentation impact is minimal — config values or settings updated.
TRIVIAL_EOF
      log "UPDATE_COMPREHEND/${slug} — complete (trivial)"
      continue
    fi

    # Minimal packages
    if (( files_int <= 3 )); then
      log "UPDATE_COMPREHEND/${slug} — started (minimal package, ${classification})"

      local mini_task="You are re-studying the '${name}' component at ${REPO_PATH}/${path} for a documentation UPDATE.
This is a minimal/config-only package with ${files_int} source files.
Classification: ${classification}

Read:
- The change details from ${SCRATCH}/update-diff.md (find your component)
- All source files in the component directory
- Previous comprehension summary: ${SCRATCH}/comprehend-${slug}-summary.md (if it exists)

Write a brief updated summary scratchpad to:
${SCRATCH}/update-comprehend-${slug}-summary.md

Focus on what CHANGED since the last documentation run.
Keep the summary under 50 lines.

${HARD_RULES}"

      if spawn_agent "$mini_task" "update-comprehend-${slug}" "$TIMEOUT" "$(model_for economy)" > /dev/null &&
         [[ -s "${SCRATCH}/update-comprehend-${slug}-summary.md" ]]; then
        log "UPDATE_COMPREHEND/${slug} — complete (minimal)"
      else
        rm -f "${SCRATCH}/update-comprehend-${slug}-summary.md"
        log "UPDATE_COMPREHEND/${slug} — ❌ SKIPPED"
        echo "- ${name} (${slug}): update comprehend failed" >> "${DOCS_DIR}/builder/skipped-components.md"
        failures=$((failures + 1))
      fi
      continue
    fi

    local mode="single-agent"
    if (( files_int > 30 )); then
      mode="per-loop (${files_int} files)"
    fi

    log "UPDATE_COMPREHEND/${slug} — started (${mode}, ${classification})"

    local task="You are re-studying the '${name}' component of a codebase at ${REPO_PATH} for a documentation UPDATE.
Your job is to BUILD UNDERSTANDING of what CHANGED. Do NOT write documentation.

Read these first:
- ${SCRATCH}/update-diff.md (find your component — what changed)
- ${DOCS_DIR}/builder/interview-notes.md (user context)
- ${INVENTORY} (find your component's entry)
- Previous comprehension summary: ${SCRATCH}/comprehend-${slug}-summary.md (if it exists — this is your baseline)

Component path: ${REPO_PATH}/${path}
Component slug: ${slug}
Classification: ${classification}

Read the comprehension loop instructions at ${SKILL_DIR}/references/comprehend.md.
Based on the file count (${files} source files), use the appropriate profile:
- ≤30 files: SMALL PROFILE (3 loops)
- >30 files: LARGE PROFILE (7 loops)

FOCUS: You are updating, not starting from scratch. Pay attention to:
- What is NEW or DIFFERENT compared to the previous summary
- Changed function signatures, schemas, behaviours
- New dependencies or removed dependencies
- Changed error handling or data flows

After ALL loops, write an UPDATED summary scratchpad to:
${SCRATCH}/update-comprehend-${slug}-summary.md

Include a 'Changes Since Last Run' section at the top.

${HARD_RULES}"

    local result
    if result=$(spawn_agent "$task" "update-comprehend-${slug}" "$TIMEOUT" "$(model_for high)") &&
       [[ -s "${SCRATCH}/update-comprehend-${slug}-summary.md" ]]; then
      log "UPDATE_COMPREHEND/${slug} — complete"
    else
      log "UPDATE_COMPREHEND/${slug} — ❌ no summary produced, retrying"
      rm -f "${SCRATCH}/update-comprehend-${slug}-summary.md"
      if result=$(spawn_agent "$task" "update-comprehend-${slug}-retry" "$TIMEOUT" "$(model_for high)") &&
         [[ -s "${SCRATCH}/update-comprehend-${slug}-summary.md" ]]; then
        log "UPDATE_COMPREHEND/${slug} — complete on retry"
      else
        rm -f "${SCRATCH}/update-comprehend-${slug}-summary.md"
        log "UPDATE_COMPREHEND/${slug} — ❌ SKIPPED after retry"
        echo "- ${name} (${slug}): update comprehend failed after 2 attempts" >> "${DOCS_DIR}/builder/skipped-components.md"
        failures=$((failures + 1))
      fi
    fi
  done < <(parse_components)

  local summaries
  summaries=$(find "$SCRATCH" -name "update-comprehend-*-summary.md" 2>/dev/null | wc -l | xargs)
  log "UPDATE_COMPREHEND — complete (${summaries} summaries)"
  (( failures == 0 ))
}

# ============================================================
# PHASE: update_docs (update mode)
# ============================================================
phase_update_docs() {
  local affected_count
  affected_count=$(parse_affected_components | wc -l | xargs)
  log "UPDATE_DOCS — started (${affected_count} affected components)"

  local total
  total=$(count_components)
  local i=0
  local updated=0
  local has_system_changes=false

  # Removed components are absent from the refreshed inventory, so process them
  # directly from the mechanically checked affected-component list.
  local removed_slug removed_classification
  while IFS='|' read -r removed_slug removed_classification; do
    [[ "$removed_classification" == "REMOVED" ]] || continue
    log "UPDATE_DOCS/${removed_slug} — removing docs (REMOVED)"
    rm -f \
      "${DOCS_DIR}/L2/${removed_slug}.md" \
      "${DOCS_DIR}/L3/${removed_slug}.md" \
      "${DOCS_DIR}/L4/${removed_slug}.md" \
      "${SCRATCH}/review-${removed_slug}.md"
    updated=$((updated + 1))
    has_system_changes=true
  done < <(parse_affected_components)

  while IFS='|' read -r slug name path files; do
    i=$((i + 1))

    local classification
    classification=$(get_classification "$slug")

    # Skip unchanged
    if [[ -z "$classification" || "$classification" == "UNCHANGED" ]]; then
      continue
    fi

    case "$classification" in
      REMOVED)
        log "UPDATE_DOCS/${slug} — removing docs (${classification})"
        rm -f "${DOCS_DIR}/L2/${slug}.md" "${DOCS_DIR}/L3/${slug}.md" "${DOCS_DIR}/L4/${slug}.md"
        log "UPDATE_DOCS/${slug} — removed L2/L3/L4"
        has_system_changes=true
        ;;
      NEW)
        log "UPDATE_DOCS/${slug} — writing new docs (${classification}, ${i}/${total})"

        # Use the same full write task as init mode
        local comprehend_file="${SCRATCH}/update-comprehend-${slug}-summary.md"
        if [[ ! -f "$comprehend_file" ]]; then
          comprehend_file="${SCRATCH}/comprehend-${slug}-summary.md"
        fi

        local task="Write documentation for the NEW '${name}' component.

Read these inputs:
- ${comprehend_file} (comprehension summary)
- Source code at ${REPO_PATH}/${path} (for verification)

Write THREE files:

${DOCS_DIR}/L2/${slug}.md
- Audience: BAs, PMs, non-engineers
- What this component does and why it exists
- Data flows with mermaid diagrams
- Business rules and logic in plain language

${DOCS_DIR}/L3/${slug}.md
- Audience: developers, maintainers
- Architecture and design decisions
- Code structure with file references
- Patterns, configuration, error handling, gotchas

${DOCS_DIR}/L4/${slug}.md
- Audience: AI agents
- NO PROSE — headings, tables, and code blocks only
- File inventory, function signatures, schemas

${HARD_RULES}"

        if ! spawn_agent "$task" "update-write-${slug}" "$TIMEOUT" "$(model_for high)" > /dev/null; then
          log "UPDATE_DOCS/${slug} — ❌ documentation agent failed"
          return 1
        fi

        local written=0
        [[ -f "${DOCS_DIR}/L2/${slug}.md" ]] && written=$((written + 1))
        [[ -f "${DOCS_DIR}/L3/${slug}.md" ]] && written=$((written + 1))
        [[ -f "${DOCS_DIR}/L4/${slug}.md" ]] && written=$((written + 1))
        log "UPDATE_DOCS/${slug} — complete (${written}/3 files written)"
        has_system_changes=true
        ;;
      MODIFIED|STRUCTURAL)
        log "UPDATE_DOCS/${slug} — updating docs (${classification}, ${i}/${total})"

        local comprehend_file="${SCRATCH}/update-comprehend-${slug}-summary.md"
        if [[ ! -f "$comprehend_file" ]]; then
          comprehend_file="${SCRATCH}/comprehend-${slug}-summary.md"
        fi

        # Skip trivial changes — no doc update needed for config-only changes
        # Check: if comprehend summary says trivial, OR if git shows only config files changed
        local skip_trivial=false
        if grep -q "trivial/config-only" "$comprehend_file" 2>/dev/null; then
          skip_trivial=true
        else
          if [[ -n "$BASE_COMMIT" && -n "$path" ]]; then
            local changed_code=0
            changed_code=$(git -C "$REPO_PATH" diff --name-only "${BASE_COMMIT}..${HEAD_COMMIT}" -- "$path" | /usr/bin/sort -u | /usr/bin/grep '[^[:space:]]' | /usr/bin/grep -cvE '\.(json|yaml|yml|config|env|md)$|package-lock' || true)
            changed_code=${changed_code:-0}
            local changed_any=0
            changed_any=$(git -C "$REPO_PATH" diff --name-only "${BASE_COMMIT}..${HEAD_COMMIT}" -- "$path" | /usr/bin/sort -u | /usr/bin/grep -c '[^[:space:]]' || true)
            changed_any=${changed_any:-0}
            if [[ "$changed_any" -gt 0 && "$changed_code" -eq 0 ]] 2>/dev/null; then
              skip_trivial=true
            fi
          fi
        fi
        if [[ "$skip_trivial" == "true" ]]; then
          log "UPDATE_DOCS/${slug} — trivial change, skipping doc update (${i}/${total})"
          continue
        fi

        local task="SURGICALLY update documentation for '${name}' based on detected changes.
Classification: ${classification}

Read:
- ${SCRATCH}/update-diff.md (what changed for this component)
- ${comprehend_file} (fresh comprehension notes)
- Existing docs:
  - ${DOCS_DIR}/L2/${slug}.md
  - ${DOCS_DIR}/L3/${slug}.md
  - ${DOCS_DIR}/L4/${slug}.md
- Source code at ${REPO_PATH}/${path} (for verification)

IMPORTANT:
- Do NOT rewrite from scratch. Update ONLY the sections affected by the changes.
- Preserve sections marked with <!-- HUMAN --> ... <!-- /HUMAN --> VERBATIM.
  These are human-authored additions that must not be overwritten.
- All other content is deep-docs generated and may be updated freely.
- For STRUCTURAL changes: update paths and references throughout.
- For MODIFIED changes: update the specific sections that describe changed behaviour.
- Add a <!-- UPDATED: $(date -u +%Y-%m-%dT%H:%M:%SZ) --> comment at the top of each updated file.

${HARD_RULES}"

        if ! spawn_agent "$task" "update-write-${slug}" "$TIMEOUT" "$(model_for high)" > /dev/null; then
          log "UPDATE_DOCS/${slug} — ❌ documentation agent failed"
          return 1
        fi
        log "UPDATE_DOCS/${slug} — complete"
        ;;
    esac
    updated=$((updated + 1))
  done < <(parse_components)

  # Regenerate group docs from the refreshed membership on every update.
  if ! DEEP_DOCS_FORCE_GROUP_REFRESH=1 phase_write_groups; then
    log "UPDATE_DOCS/groups — ❌ one or more group pages failed to refresh"
    return 1
  fi

  # Regenerate overviews and L1 if there were system-level changes
  if [[ "$has_system_changes" == "true" ]] || (( updated > 0 )); then
    log "UPDATE_DOCS/overviews — regenerating"

    spawn_agent "Update the system-level L2 overview. Read all L2 docs in ${DOCS_DIR}/L2/ and the change summary in ${SCRATCH}/update-diff.md. Update ${DOCS_DIR}/L2/overview.md to reflect current state. Preserve <!-- HUMAN --> blocks. ${HARD_RULES}" "update-l2-overview" "$TIMEOUT" "$(model_for high)" > /dev/null || return 1
    log "UPDATE_DOCS/L2/overview.md — updated"

    spawn_agent "Update the L4 system overview. Read L4 files in ${DOCS_DIR}/L4/ plus ${DOCS_DIR}/diagrams/dependencies.mmd. Update ${DOCS_DIR}/L4/OVERVIEW.md. NO PROSE. ${HARD_RULES}" "update-l4-overview" "$TIMEOUT" "$(model_for high)" > /dev/null || return 1
    log "UPDATE_DOCS/L4/OVERVIEW.md — updated"

    spawn_agent "Update the executive summary. Read L2 docs in ${DOCS_DIR}/L2/ and ${SCRATCH}/update-diff.md. Update ${DOCS_DIR}/L1/executive-summary.md. 1 page max, no code, no jargon. ${HARD_RULES}" "update-l1" "$TIMEOUT" "$(model_for high)" > /dev/null || return 1
    log "UPDATE_DOCS/L1/executive-summary.md — updated"
  fi

  log "UPDATE_DOCS — complete (${updated} components updated)"
}

# ============================================================
# PHASE: changelog (update mode)
# ============================================================
phase_changelog() {
  log "CHANGELOG — started"
  local changelog_marker="${SCRATCH}/changelog-complete.md"
  rm -f "$changelog_marker"

  local task="Generate a changelog entry for this documentation update.

Read:
- ${SCRATCH}/update-diff.md (what changed in source code)
- All update comprehension notes: ${SCRATCH}/update-comprehend-*-summary.md
- The current docs in ${DOCS_DIR}/L2/ and ${DOCS_DIR}/L3/ (to see what was updated)

Write a changelog entry. If ${DOCS_DIR}/CHANGELOG.md exists, PREPEND the new entry
after the title line. If it doesn't exist, create it.

Use this format:

## $(date -u +%Y-%m-%d)

### Code Changes Detected
- Bullet list of meaningful source changes (not every file — grouped logically)

### Documentation Updates
- What was added/updated/removed in docs
- Which components were re-documented
- Which diagrams were regenerated (if any)

### Impact Summary
- 1-2 sentences: what this means for users of the codebase

After the changelog is complete, write ${changelog_marker} with the final non-empty line:
CHANGELOG_COMPLETE

${HARD_RULES}"

  spawn_agent "$task" "changelog" "$TIMEOUT" "$(model_for high)" > /dev/null || return 1

  if [[ -f "${DOCS_DIR}/CHANGELOG.md" && -f "$changelog_marker" ]] &&
     [[ "$(/usr/bin/awk 'NF{line=$0} END{print line}' "$changelog_marker")" == "CHANGELOG_COMPLETE" ]]; then
    log "CHANGELOG — complete"
  else
    log "CHANGELOG — ❌ output or completion marker missing"
    return 1
  fi
}

# ============================================================
# PHASE: record (write last-run.md)
# ============================================================
phase_record() {
  local mode="${1:-init}"
  local components_list

  if [[ "$mode" == "update" ]]; then
    components_list=$(parse_affected_components | cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g')
  else
    components_list=$(parse_components | cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g')
  fi

  local profile="large"  # Default; could be read from calibration.md if it existed
  local source_commit
  if [[ "$mode" == "update" ]]; then
    assert_update_head_unchanged || return 1
    source_commit="$HEAD_COMMIT"
  else
    source_commit=$(git -C "$REPO_PATH" rev-parse HEAD 2>/dev/null || true)
  fi

  cat > "${DOCS_DIR}/builder/last-run.md" << EOF
date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
commit: ${source_commit}
mode: ${mode}
profile: ${profile}
components: ${components_list}
EOF

  log "RECORD — last-run.md written (mode: ${mode})"
}

# ============================================================
# PHASE: history_harvest
# ============================================================
phase_history_harvest() {
  local since="${1:-}"
  local last="${2:-}"
  local granularity="${3:-major}"

  log "HISTORY_HARVEST — started"

  local git_range_instruction=""
  if [[ -n "$since" ]]; then
    git_range_instruction="Filter commits to those after ${since}. Use: git log --since='${since}' in ${REPO_PATH}."
  elif [[ -n "$last" ]]; then
    git_range_instruction="Only analyse the last ${last} commits. Use: git log -n ${last} in ${REPO_PATH}."
  else
    git_range_instruction="Analyse the full git history of ${REPO_PATH}."
  fi

  local task="Analyse git history for ${REPO_PATH}.

${git_range_instruction}

Collect for each commit: hash (short), date, author, message, files changed, insertions/deletions.

Auto-filter OUT:
- Merge commits (unless they represent significant branch merges)
- Dependency-only updates (package-lock.json, yarn.lock, requirements.txt ONLY changes)
- Formatting/linting-only commits (detected by: only whitespace/style changes)
- CI config tweaks (unless substantial pipeline changes)
- .gitignore updates

Write: ${SCRATCH}/history-harvest.md

Format:
## Filtered Commits
| Date | Hash | Author | Message | Files Changed | +/- |
|------|------|--------|---------|---------------|-----|

## Excluded Commits (summary)
- N merge commits filtered
- N dependency-only commits filtered
- N formatting-only commits filtered

## Statistics
- Total commits analysed: N
- Filtered to: N meaningful commits
- Date range: YYYY-MM-DD to YYYY-MM-DD
- Active authors: list

${HARD_RULES}"

  rm -f "${SCRATCH}/history-harvest.md" || return 1
  if ! spawn_agent "$task" "history-harvest" 600 "$(model_for economy)" > /dev/null ||
     ! assert_update_head_unchanged; then
    rm -f "${SCRATCH}/history-harvest.md"
    return 1
  fi

  if [[ -s "${SCRATCH}/history-harvest.md" ]]; then
    log "HISTORY_HARVEST — complete"
  else
    log "HISTORY_HARVEST — ❌ failed"
    return 1
  fi
}

# ============================================================
# PHASE: history_epochs
# ============================================================
phase_history_epochs() {
  local granularity="${1:-major}"

  log "HISTORY_EPOCHS — started (granularity: ${granularity})"

  local granularity_instruction=""
  if [[ "$granularity" == "major" ]]; then
    granularity_instruction="Use AGGRESSIVE epoch detection — only significant epochs (new components, architectural shifts, major features). Fold small changes into neighbouring epochs. Aim for 5-15 epochs for a mature repo."
  else
    granularity_instruction="Use DETAILED epoch detection — every meaningful period of development gets an entry. Sub-divide large epochs into feature-level entries. Include minor but noteworthy changes. Aim for 2-5x more entries than a major-only view."
  fi

  local task="Read the harvest data at ${SCRATCH}/history-harvest.md.

Identify natural epochs — periods of coherent development focus separated by shifts in direction.

${granularity_instruction}

Signals for epoch boundaries:
- New top-level directories appearing (new component/service)
- Large refactors (many files renamed/moved in one commit)
- Significant dependency changes (new framework, major version bumps)
- Gaps in commit activity (>2 weeks)
- Shifts in which directories are being changed
- Explicit version tags or release commits

For each epoch produce:
- Date range
- Descriptive name (inferred from changes, not commit messages)
- Key commits that define the epoch (hashes)
- What was the development focus
- Approximate magnitude (files changed, lines added/removed)

Write: ${SCRATCH}/history-epochs.md

Format:
## Epoch 1: {{Descriptive Name}} (YYYY-MM-DD — YYYY-MM-DD)
**Focus:** one-line summary
**Key commits:** hash1, hash2, hash3
**Magnitude:** N files changed, +N/-N lines
**Description:** 2-3 sentences on what this epoch represents

${HARD_RULES}"

  rm -f "${SCRATCH}/history-epochs.md" || return 1
  if ! spawn_agent "$task" "history-epochs" "$TIMEOUT" "$(model_for high)" > /dev/null ||
     ! assert_update_head_unchanged; then
    rm -f "${SCRATCH}/history-epochs.md"
    return 1
  fi

  if [[ -f "${SCRATCH}/history-epochs.md" ]]; then
    local epoch_count
    epoch_count=$(grep -c '^## Epoch' "${SCRATCH}/history-epochs.md" 2>/dev/null || true)
    epoch_count=${epoch_count:-0}
    (( epoch_count > 0 )) || { log "HISTORY_EPOCHS — ❌ no epochs produced"; return 1; }
    log "HISTORY_EPOCHS — complete (${epoch_count} epochs detected)"
  else
    log "HISTORY_EPOCHS — ❌ failed"
    return 1
  fi
}

# ============================================================
# PHASE: history_comprehend
# ============================================================
phase_history_comprehend() {
  log "HISTORY_COMPREHEND — started"

  # Extract epoch slugs from epochs file
  local epoch_count
  epoch_count=$(grep -c '^## Epoch' "${SCRATCH}/history-epochs.md" 2>/dev/null || true)
  epoch_count=${epoch_count:-0}
  (( epoch_count > 0 )) || return 1

  local i=0
  while (( i < epoch_count )); do
    i=$((i + 1))
    local slug="epoch-$(printf '%02d' "$i")"

    # History has no source-bound resume receipt; existence is not acceptance.
    rm -f "${SCRATCH}/history-${slug}.md" || return 1

    log "HISTORY_COMPREHEND/${slug} — started (${i}/${epoch_count})"

    local task="Study epoch ${i} from ${SCRATCH}/history-epochs.md.

Read:
- ${SCRATCH}/history-epochs.md (find Epoch ${i})
- ${SCRATCH}/history-harvest.md (for commit details)
- The actual source code diffs for key commits in this epoch.
  Use \`git show <hash> --stat\` and \`git diff <hash>~1..<hash>\` in ${REPO_PATH}
  for the key commits listed in the epoch.

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

Write: ${SCRATCH}/history-${slug}.md

Include a summary section at the end with the key narrative points for this epoch.

${HARD_RULES}"

    if ! spawn_agent "$task" "history-comprehend-${slug}" "$TIMEOUT" "$(model_for high)" > /dev/null ||
       ! assert_update_head_unchanged || [[ ! -s "${SCRATCH}/history-${slug}.md" ]]; then
      rm -f "${SCRATCH}/history-${slug}.md"
      log "HISTORY_COMPREHEND/${slug} — ❌ failed (${i}/${epoch_count})"
      return 1
    fi
    log "HISTORY_COMPREHEND/${slug} — complete (${i}/${epoch_count})"
  done

  local completed
  completed=$(find "$SCRATCH" -name "history-epoch-*.md" 2>/dev/null | wc -l | xargs)
  log "HISTORY_COMPREHEND — complete (${completed}/${epoch_count} epochs)"
}

# ============================================================
# PHASE: history_write
# ============================================================
phase_history_write() {
  log "HISTORY_WRITE — started"
  local marker="${SCRATCH}/history-write-complete.md"
  rm -f "$marker" || return 1

  local task="Synthesise all epoch notes into a narrative changelog.

Read: all history epoch scratchpads at ${SCRATCH}/history-epoch-*.md
Also read: ${SCRATCH}/history-epochs.md for the epoch structure

Write ${DOCS_DIR}/CHANGELOG.md (if it exists, PREPEND the history section before existing entries):

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

After completing the changelog, write ${marker} with the final non-empty line:
HISTORY_WRITE_COMPLETE

${HARD_RULES}"

  if ! spawn_agent "$task" "history-write" "$TIMEOUT" "$(model_for high)" > /dev/null ||
     ! assert_update_head_unchanged; then
    rm -f "$marker"
    return 1
  fi

  if [[ -s "${DOCS_DIR}/CHANGELOG.md" && -f "$marker" ]] &&
     [[ "$(/usr/bin/awk 'NF{line=$0} END{print line}' "$marker")" == "HISTORY_WRITE_COMPLETE" ]]; then
    log "HISTORY_WRITE — complete"
  else
    log "HISTORY_WRITE — ❌ missing changelog or fresh completion marker"
    rm -f "$marker"
    return 1
  fi
}

# ============================================================
# PHASE: history_review
# ============================================================
phase_history_review() {
  log "HISTORY_REVIEW — started"

  local max_iterations=3
  local iteration=1

  while (( iteration <= max_iterations )); do
    log "HISTORY_REVIEW — iteration ${iteration}/${max_iterations}"

    local task="Review the generated changelog for accuracy against git history.

Read:
- ${DOCS_DIR}/CHANGELOG.md
- ${SCRATCH}/history-harvest.md (the raw commit data)
- ${SCRATCH}/history-epochs.md (the epoch structure)

Verify:
1. DATE ACCURACY — epoch date ranges match actual commit dates
2. ATTRIBUTION — changes attributed to the correct epoch
3. COMPLETENESS — no significant epochs omitted (compare against git activity)
4. NARRATIVE ACCURACY — descriptions match what the diffs actually show
5. NO SPECULATION — changelog states facts, not inferred intent

Do NOT check: file path existence, env var accuracy, function signatures.

Fix any inaccuracies directly in ${DOCS_DIR}/CHANGELOG.md.

Write ${SCRATCH}/history-review-${iteration}.md with:
| Issue | Severity | Action Taken |

Output exactly one outcome on the final non-empty line: REVIEW_CLEAN or REVIEW_ISSUES: N unresolved

${HARD_RULES}"

    local review_file="${SCRATCH}/history-review-${iteration}.md"
    rm -f "$review_file" || return 1
    if ! spawn_agent "$task" "history-review-${iteration}" "$TIMEOUT" "$(model_for high)" > /dev/null ||
       ! assert_update_head_unchanged; then
      rm -f "$review_file"
      log "HISTORY_REVIEW — ❌ reviewer failed or source changed"
      return 1
    fi
    if [[ -s "${DOCS_DIR}/CHANGELOG.md" && -f "$review_file" ]] && /usr/bin/awk '
      {
        sub(/\r$/, "")
        if ($0 ~ /REVIEW_(CLEAN|ISSUES)/) markers++
        if (NF) last=$0
      }
      END { exit !(markers == 1 && last == "REVIEW_CLEAN") }
    ' "$review_file"; then
      log "HISTORY_REVIEW — iteration ${iteration}: REVIEW_CLEAN"
      log "HISTORY_REVIEW — complete"
      return 0
    fi
    log "HISTORY_REVIEW — iteration ${iteration}: ❌ missing, malformed or unresolved outcome"
    iteration=$((iteration + 1))
  done

  log "HISTORY_REVIEW — ❌ incomplete after ${max_iterations} iterations"
  return 1
}

# ============================================================
# PHASE: package (generate MkDocs Material site)
# ============================================================
phase_package() {
  log "PACKAGE — started"
  local package_marker="${SCRATCH}/package-complete.md"
  rm -f "$package_marker"

  # Build the project name from interview notes or fallback
  local project_name="Documentation"
  if [[ -f "${DOCS_DIR}/builder/interview-notes.md" ]]; then
    local detected
    detected=$(grep -i -m1 'project\|name\|title' "${DOCS_DIR}/builder/interview-notes.md" | head -1 | sed 's/.*: *//' | xargs)
    [[ -n "$detected" ]] && project_name="$detected"
  fi

  # Collect file listings for the sub-agent
  local l1_files l2_files l2_group_files l3_files l4_files diagram_files extra_files
  l1_files=$(find "${DOCS_DIR}/L1" -name "*.md" 2>/dev/null | sort | sed "s|${DOCS_DIR}/||")
  l2_files=$(find "${DOCS_DIR}/L2" -maxdepth 1 -name "*.md" 2>/dev/null | sort | sed "s|${DOCS_DIR}/||")
  l2_group_files=$(find "${DOCS_DIR}/L2/groups" -name "*.md" 2>/dev/null | sort | sed "s|${DOCS_DIR}/||")
  l3_files=$(find "${DOCS_DIR}/L3" -name "*.md" 2>/dev/null | sort | sed "s|${DOCS_DIR}/||")
  l4_files=$(find "${DOCS_DIR}/L4" -name "*.md" 2>/dev/null | sort | sed "s|${DOCS_DIR}/||")
  diagram_files=$(find "${DOCS_DIR}/diagrams" -name "*.md" 2>/dev/null | sort | sed "s|${DOCS_DIR}/||")
  extra_files=""
  [[ -f "${DOCS_DIR}/CHANGELOG.md" ]] && extra_files="${extra_files}
CHANGELOG.md"
  [[ -f "${DOCS_DIR}/REVIEW.md" ]] && extra_files="${extra_files}
REVIEW.md"

  local task="Generate a MkDocs Material documentation site configuration.

Project name: ${project_name}
Docs directory: ${DOCS_DIR}

Available files:

L1 files:
${l1_files}

L2 files (per-component):
${l2_files}

L2 group files:
${l2_group_files}

L3 files:
${l3_files}

L4 files:
${l4_files}

Diagram files:
${diagram_files}

Extra files:
${extra_files}

Read:
- ${DOCS_DIR}/builder/specs/component-inventory.md (for component names and grouping)
- ${DOCS_DIR}/builder/specs/component-groups.md (if it exists — for module grouping in nav)

Generate TWO files:

1. ${DOCS_DIR}/mkdocs.yml — Full MkDocs Material configuration with:
   - REQUIRED layout: docs_dir: docs and site_dir: site. Never use docs_dir: . or an outside-output site_dir.
     The orchestrator creates docs/ as a relative-symlink view of the authoritative root pages.
     Do NOT move/copy root documents or create the docs/ view yourself.
   - Material theme with navigation.tabs, navigation.sections, search, dark mode toggle
   - Mermaid diagram support via pymdownx.superfences
   - Admonitions, tables, tabbed content, TOC with permalinks
   - Complete nav structure listing EVERY documentation file:
     - Home (index.md)
     - Executive Summary (L1)
     - System Overview section with:
       - Overview (L2/overview.md)
       - Modules subsection (one entry per group from L2/groups/)
       - Components subsection (L2 per-component files, grouped by module if groups exist)
     - Developer Reference section (all L3 files, grouped by module if groups exist)
     - AI Agent Reference section (L4/OVERVIEW.md + all L4 component files)
     - Diagrams (diagrams/INDEX.md)
     - Changelog and Review if they exist
   IMPORTANT: List EVERY file. Do not sample or abbreviate. Count your entries against the file lists above.

2. ${DOCS_DIR}/index.md — Landing page with:
   - Project title and description
   - Table of documentation tiers with links
   - Module overview table (if groups exist) with links to group docs
   - Quick links to diagrams, changelog, review

After both files are complete, write ${package_marker} with the final non-empty line:
PACKAGE_COMPLETE

Use relative paths throughout. Authoritative documents stay in their current root locations.
MkDocs serves the orchestrator-managed ${DOCS_DIR}/docs/ view and writes ${DOCS_DIR}/site/.
A normal mkdocs build --strict must work; do not require stdin configuration or wrapper flags.

${HARD_RULES}"

  if ! spawn_agent "$task" "package" "$TIMEOUT" "$(model_for economy)" > /dev/null; then
    log "PACKAGE — ❌ package agent failed"
    return 1
  fi
  if [[ ! -f "$package_marker" ]] || [[ "$(/usr/bin/awk 'NF{line=$0} END{print line}' "$package_marker")" != "PACKAGE_COMPLETE" ]]; then
    log "PACKAGE — ❌ package agent did not produce a completion marker"
    return 1
  fi

  if [[ -f "${DOCS_DIR}/mkdocs.yml" ]]; then
    log "PACKAGE — mkdocs.yml generated"
  else
    log "PACKAGE — ❌ mkdocs.yml not generated"
    return 1
  fi

  if [[ -f "${DOCS_DIR}/index.md" ]]; then
    log "PACKAGE — index.md generated"
  else
    log "PACKAGE — ❌ index.md not generated"
    return 1
  fi

  if ! validate_site_navigation; then
    log "PACKAGE — ❌ MkDocs navigation is incomplete or has missing targets"
    return 1
  fi
  log "PACKAGE — navigation validated against generated Markdown files"

  validate_site_build || return 1

  log "PACKAGE — complete"
}

# ============================================================
# Main
# ============================================================
if [[ "${DEEP_DOCS_TEST_MODE:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

# Serialize result invalidation as well as durable invocation reservations.
mkdir -p "$SCRATCH" || exit 1
exec 9>"${SCRATCH}/legacy-run.lock"
flock -n 9 || { echo 'Another legacy run owns this docs output' >&2; exit 75; }
validate_agent_adapter || exit $?

case "$PHASE" in
  discover)
    phase_discover
    ;;
  comprehend)
    phase_comprehend
    ;;
  write)
    phase_write
    ;;
  review)
    phase_review
    ;;
  all)
    phase_discover

    # Calibrate (simple — just log it, the comprehend phase handles profile selection)
    log "CALIBRATE — reading inventory"
    total=$(count_components)
    log "CALIBRATE — complete (${total} components, large profile)"

    # Synthesise + Diagram handled by single agents
    phase_comprehend

    log "SYNTHESISE — started"
    spawn_agent "Read ${SKILL_DIR}/references/synthesise.md. Read all summary scratchpads from ${SCRATCH}/comprehend-*-summary.md. Read ${DOCS_DIR}/builder/specs/component-inventory.md. Write synthesis files to ${SCRATCH}/synthesise-01-integration.md, synthesise-02-flows.md, synthesise-03-architecture.md. ${HARD_RULES}" "synthesise" "$TIMEOUT" > /dev/null
    log "SYNTHESISE — complete"

    log "DIAGRAM — started"
    spawn_agent "Read ${SKILL_DIR}/references/diagram.md. Read all synthesis notes from ${SCRATCH}/synthesise-*.md and ${DOCS_DIR}/builder/specs/component-inventory.md. Generate Mermaid diagrams to ${DOCS_DIR}/diagrams/. Write ${DOCS_DIR}/diagrams/INDEX.md. ${HARD_RULES}" "diagram" "$TIMEOUT" "$(model_for economy)" > /dev/null
    log "DIAGRAM — complete"

    phase_write
    phase_review || exit 1
    phase_package || exit 1
    phase_record "init"

    log "COMPLETE — deep-docs init finished"
    ;;
  update)
    prepare_update_run_state || exit 1
    phase_update_inventory || exit 1
    assert_update_head_unchanged || exit 1

    # Diff discovery — detect what changed and distinguish clean no-op from failure.
    phase_diff_discovery
    diff_status=$?
    assert_update_head_unchanged || exit 1
    if (( diff_status == 1 )); then
      # Source classification does not prove the inherited documentation is complete.
      validate_current_docs || exit 1
      if ! validate_site_navigation; then
        log "PACKAGE — missing/stale navigation despite unchanged source; regenerating"
        phase_package || exit 1
      else
        validate_site_build || exit 1
      fi
      validate_current_docs && validate_site_navigation && assert_update_head_unchanged || exit 1
      log "COMPLETE — no source changes; documentation outputs/navigation validated (no new semantic review)"
      # No newly reviewed source baseline is claimed for a no-op.
      exit 0
    elif (( diff_status != 0 )); then
      log "COMPLETE — ❌ diff discovery failed validation"
      exit "$diff_status"
    fi

    # Targeted comprehension for affected components
    phase_update_comprehend || exit 1
    assert_update_head_unchanged || exit 1

    # Re-synthesise if integration points changed
    needs_synthesis=false
    if parse_affected_components | grep -qE '\|(NEW|REMOVED|STRUCTURAL)$'; then
      needs_synthesis=true
    fi
    # Also re-synthesise if >3 components modified (likely cross-cutting change)
    modified_count=$(parse_affected_components | grep -c '|MODIFIED$' || true)
    modified_count=${modified_count:-0}
    if (( modified_count > 3 )); then
      needs_synthesis=true
    fi

    if [[ "$needs_synthesis" == "true" ]]; then
      log "SYNTHESISE — started (integration points changed)"
      spawn_agent "Read ${SKILL_DIR}/references/synthesise.md. Read all summary scratchpads from ${SCRATCH}/update-comprehend-*-summary.md and ${SCRATCH}/comprehend-*-summary.md. Read ${INVENTORY}. Write synthesis files to ${SCRATCH}/synthesise-01-integration.md, synthesise-02-flows.md, synthesise-03-architecture.md. Focus on what CHANGED. ${HARD_RULES}" "update-synthesise" "$TIMEOUT" "$(model_for high)" > /dev/null || exit 1
      log "SYNTHESISE — complete"

      log "DIAGRAM — started (updating)"
      spawn_agent "Read ${SKILL_DIR}/references/diagram.md. Read synthesis notes from ${SCRATCH}/synthesise-*.md and ${INVENTORY}. Update Mermaid diagrams in ${DOCS_DIR}/diagrams/. Update ${DOCS_DIR}/diagrams/INDEX.md. ${HARD_RULES}" "update-diagram" "$TIMEOUT" "$(model_for economy)" > /dev/null || exit 1
      log "DIAGRAM — complete"
      assert_update_head_unchanged || exit 1
    fi

    # Surgical doc updates and hard output postconditions.
    phase_update_docs || exit 1
    assert_update_head_unchanged || exit 1
    validate_update_outputs || {
      log "UPDATE_DOCS — ❌ generated output validation failed"
      exit 1
    }

    phase_changelog || exit 1
    assert_update_head_unchanged || exit 1
    phase_review || exit 1
    assert_update_head_unchanged || exit 1

    # Rebuild navigation/index after added or removed pages, then validate again.
    phase_package || exit 1
    assert_update_head_unchanged || exit 1
    validate_update_outputs && verify_review_scope || exit 1

    # Advance the baseline only after docs, review, navigation and build validation.
    phase_record "update" || exit 1

    log "COMPLETE — deep-docs update finished"
    ;;
  history)
    # Parse history-specific options from remaining args (after $4/model)
    history_since=""
    history_last=""
    history_granularity="major"

    shift 4 2>/dev/null || shift $# 2>/dev/null  # skip phase, repo, docs, model
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --since) history_since="$2"; shift 2 ;;
        --last)  history_last="$2"; shift 2 ;;
        --granularity) history_granularity="$2"; shift 2 ;;
        *) shift ;;
      esac
    done

    log "HISTORY — started (since: ${history_since:-all}, last: ${history_last:-all}, granularity: ${history_granularity})"

    mkdir -p "$SCRATCH" || exit 1
    rm -f "${SCRATCH}/history-harvest.md" "${SCRATCH}/history-epochs.md" \
      "${SCRATCH}"/history-epoch-*.md "${SCRATCH}"/history-review-*.md \
      "${SCRATCH}/history-write-complete.md" || exit 1
    validate_reproducible_source || exit 1
    HEAD_COMMIT=$(git -C "$REPO_PATH" rev-parse HEAD) || exit 1

    phase_history_harvest "$history_since" "$history_last" "$history_granularity" || exit 1
    phase_history_epochs "$history_granularity" || exit 1
    phase_history_comprehend || exit 1
    phase_history_write || exit 1
    phase_history_review || exit 1
    assert_update_head_unchanged || exit 1

    # Note: history mode does NOT update last-run.md (read-only analysis)
    log "COMPLETE — deep-docs history finished"
    ;;
  groups)
    phase_write_groups
    ;;
  package)
    phase_package
    ;;
  *)
    echo "Unknown phase: $PHASE"
    echo "Usage: orchestrate.sh <discover|comprehend|write|groups|review|package|update|history|all> <repo_path> <docs_dir> [model]"
    echo ""
    echo "History options: --since YYYY-MM-DD | --last N | --granularity major|detailed"
    exit 1
    ;;
esac
