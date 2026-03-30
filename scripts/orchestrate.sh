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

# Model routing strategy:
# - QUALITY_MODEL  : comprehend, synthesise, write (accuracy matters most)
# - ECONOMY_MODEL  : discover, review pass 1, diagram (mechanical/structural tasks)
# Override ECONOMY_MODEL to "" to use QUALITY_MODEL everywhere (max quality mode).
QUALITY_MODEL="${MODEL}"
ECONOMY_MODEL="${DEEP_DOCS_ECONOMY_MODEL:-anthropic/claude-sonnet-4-6}"

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

parse_components() {
  # Pre-extract with awk to avoid subshell PATH issues
  /usr/bin/awk -F'|' '/^\| [0-9]/ {
    gsub(/`/, "", $4); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4);  # slug
    gsub(/`/, "", $3); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);  # name
    gsub(/`/, "", $5); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5);  # path
    gsub(/`/, "", $6); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6);  # files
    if ($4 != "") print $4 "|" $3 "|" $5 "|" $6
  }' "$INVENTORY"
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

# Spawn a sub-agent and wait for completion
# Usage: spawn_agent <task> <label> [timeout] [model]
# Note: openclaw agent --local uses agents.defaults.model.primary from openclaw.json.
# Per-invocation model switching is not supported by the CLI.
# To run with Opus: set agents.defaults.model.primary to anthropic/claude-opus-4-6
# in ~/.openclaw/openclaw.json before running the orchestrator.
# The [model] argument is accepted for future compatibility but currently ignored.
spawn_agent() {
  local task="$1"
  local label="$2"
  local agent_timeout="${3:-$TIMEOUT}"
  local agent_model="${4:-$QUALITY_MODEL}"  # logged but not yet actionable

  local session_id="dd-${label}-$(date +%s)"

  openclaw agent \
    --local \
    --session-id "$session_id" \
    --message "$task" \
    --timeout "$agent_timeout" \
    < /dev/null > /dev/null 2>&1 || true
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

phase_write_groups() {
  local groups_file="${DOCS_DIR}/builder/specs/component-groups.md"
  if [[ ! -f "$groups_file" ]]; then
    log "WRITE_GROUPS — skipped (no component-groups.md)"
    return
  fi

  local total
  total=$(count_groups)
  if (( total < 2 )); then
    log "WRITE_GROUPS — skipped (fewer than 2 groups)"
    return
  fi

  mkdir -p "${DOCS_DIR}/L2/groups"
  log "WRITE_GROUPS — started (${total} groups)"

  local i=0
  while IFS='|' read -r slug name path_prefix components; do
    i=$((i + 1))

    # Resume support
    if [[ -f "${DOCS_DIR}/L2/groups/${slug}.md" ]]; then
      log "WRITE_GROUPS/${slug} — skipped (exists, ${i}/${total})"
      continue
    fi

    log "WRITE_GROUPS/${slug} — started (${i}/${total})"

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

${HARD_RULES}"

    spawn_agent "$task" "write-group-${slug}" "$TIMEOUT" "$(model_for high)" > /dev/null

    if [[ -f "${DOCS_DIR}/L2/groups/${slug}.md" ]]; then
      log "WRITE_GROUPS/${slug} — complete (${i}/${total})"
    else
      log "WRITE_GROUPS/${slug} — ❌ retrying (${i}/${total})"
      spawn_agent "$task" "write-group-${slug}-retry" "$TIMEOUT" "$(model_for high)" > /dev/null
      if [[ -f "${DOCS_DIR}/L2/groups/${slug}.md" ]]; then
        log "WRITE_GROUPS/${slug} — complete on retry (${i}/${total})"
      else
        log "WRITE_GROUPS/${slug} — ❌ SKIPPED (${i}/${total})"
        echo "- Group: ${name} (${slug}): no group doc produced" >> "${DOCS_DIR}/builder/skipped-components.md"
      fi
    fi
  done < <(parse_groups)

  local group_count
  group_count=$(find "${DOCS_DIR}/L2/groups" -name "*.md" 2>/dev/null | wc -l | xargs)
  log "WRITE_GROUPS — complete (${group_count}/${total} group docs)"
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
# PHASE: review
# ============================================================
phase_review() {
  log "REVIEW — started"

  local total
  total=$(count_components)
  local iteration=1
  local max_iterations=3

  while (( iteration <= max_iterations )); do
    # Pass 1: economy model (broad sweep across all components)
    # Pass 2+: quality model (focused on known-issues components only — worth full accuracy)
    local review_model
    if (( iteration == 1 )); then
      review_model="$(model_for economy)"
    else
      review_model="$(model_for high)"
    fi
    log "REVIEW — iteration ${iteration}/${max_iterations} (model: ${review_model})"

    local i=0
    while IFS='|' read -r slug name path files; do
      i=$((i + 1))

      # Skip if no docs exist
      if [[ ! -f "${DOCS_DIR}/L2/${slug}.md" && ! -f "${DOCS_DIR}/L3/${slug}.md" && ! -f "${DOCS_DIR}/L4/${slug}.md" ]]; then
        continue
      fi

      # Resume support: skip if review already exists for this iteration
      if [[ -f "${SCRATCH}/review-${slug}.md" ]]; then
        log "REVIEW/${slug} — skipped (review exists, ${i}/${total})"
        continue
      fi

      log "REVIEW/${slug} — started (${i}/${total})"

      local task="Review documentation for '${name}' against source code.

Read ONLY:
- ${DOCS_DIR}/L2/${slug}.md
- ${DOCS_DIR}/L3/${slug}.md
- ${DOCS_DIR}/L4/${slug}.md
- Source code at ${REPO_PATH}/${path}

Verify: file paths exist, function signatures match, env vars correct, described behaviour matches implementation, schemas match.

For errors/warnings: FIX the documentation (not source code).
For uncertainties: add <!-- UNVERIFIED -->.

Write ${SCRATCH}/review-${slug}.md with:
| File | Issue Found | Severity | Action Taken |

Output COMPONENT_CLEAN or COMPONENT_ISSUES: N unresolved

${HARD_RULES}"

      spawn_agent "$task" "review-${slug}" "$TIMEOUT" "$review_model" > /dev/null
      if [[ -f "${SCRATCH}/review-${slug}.md" ]]; then
        # Determine clean vs issues for progress log
        if grep -q "COMPONENT_ISSUES" "${SCRATCH}/review-${slug}.md" 2>/dev/null; then
          local n_issues
          n_issues=$(grep -o "COMPONENT_ISSUES: [0-9]*" "${SCRATCH}/review-${slug}.md" | grep -o "[0-9]*$" || echo "?")
          log "REVIEW/${slug} — complete: COMPONENT_ISSUES ${n_issues} unresolved (${i}/${total})"
        else
          log "REVIEW/${slug} — complete: COMPONENT_CLEAN (${i}/${total})"
        fi
      else
        log "REVIEW/${slug} — ❌ no review file produced, retrying (${i}/${total})"
        spawn_agent "$task" "review-${slug}-retry" "$TIMEOUT" "$review_model" > /dev/null
        if [[ -f "${SCRATCH}/review-${slug}.md" ]]; then
          log "REVIEW/${slug} — complete on retry (${i}/${total})"
        else
          log "REVIEW/${slug} — ❌ SKIPPED after retry (${i}/${total})"
        fi
      fi
    done < <(parse_components)

    # Aggregation
    local issues
    issues=$(grep -l "COMPONENT_ISSUES" "${SCRATCH}"/review-*.md 2>/dev/null | wc -l | xargs)
    local clean
    clean=$(grep -l "COMPONENT_CLEAN" "${SCRATCH}"/review-*.md 2>/dev/null | wc -l | xargs)

    if (( issues == 0 )); then
      log "REVIEW — iteration ${iteration}: REVIEW_CLEAN (${clean}/${total} components clean)"
      break
    else
      log "REVIEW — iteration ${iteration}: ${issues} components with issues, ${clean} clean"
      # Clear review files for components with issues so they get re-reviewed
      grep -l "COMPONENT_ISSUES" "${SCRATCH}"/review-*.md 2>/dev/null | xargs rm -f
      iteration=$((iteration + 1))
    fi
  done

  # Write REVIEW.md — quality model (aggregation requires cross-doc reasoning)
  log "REVIEW/aggregate — started"
  spawn_agent "Aggregate all review files from ${SCRATCH}/review-*.md into ${DOCS_DIR}/REVIEW.md. Read only files with COMPONENT_ISSUES. Write summary table. ${HARD_RULES}" "review-aggregate" "$TIMEOUT" "$(model_for high)" > /dev/null
  log "REVIEW/aggregate — complete"
  log "REVIEW — complete"
}

# ============================================================
# PHASE: diff_discovery (update mode)
# ============================================================
phase_diff_discovery() {
  log "DIFF_DISCOVERY — started"

  local last_run_date=""
  local last_run_file="${DOCS_DIR}/builder/last-run.md"
  if [[ -f "$last_run_file" ]]; then
    last_run_date=$(grep '^date:' "$last_run_file" | sed 's/^date: *//' | xargs)
    log "DIFF_DISCOVERY — last run: ${last_run_date}"
  else
    log "DIFF_DISCOVERY — no last-run.md found, comparing docs vs current source directly"
  fi

  # Pre-compute git diff to avoid agent needing to explore
  local git_diff_file="${SCRATCH}/git-diff-raw.md"
  mkdir -p "$SCRATCH"
  if [[ -n "$last_run_date" ]]; then
    local base_commit
    base_commit=$(cd "$REPO_PATH" && git log --since="$last_run_date" --format=%H -- . | tail -1)
    if [[ -n "$base_commit" ]]; then
      {
        echo "# Git Changes Since ${last_run_date}"
        echo ""
        echo "## Commits"
        (cd "$REPO_PATH" && git log --oneline "${base_commit}..HEAD" -- .)
        echo ""
        echo "## Files Changed (name-status)"
        (cd "$REPO_PATH" && git diff --name-status "${base_commit}..HEAD" -- .)
        echo ""
        echo "## Diffstat"
        (cd "$REPO_PATH" && git diff --stat "${base_commit}..HEAD" -- .)
      } > "$git_diff_file"
    else
      {
        echo "# Git Changes (no commits found since ${last_run_date})"
        echo ""
        echo "## Recent Commits"
        (cd "$REPO_PATH" && git log --oneline -20 -- .)
        echo ""
        echo "## Files Changed (last 20 commits)"
        (cd "$REPO_PATH" && git diff --name-status HEAD~20..HEAD -- . 2>/dev/null || echo "Unable to diff")
      } > "$git_diff_file"
    fi
    log "DIFF_DISCOVERY — git diff pre-computed to ${git_diff_file}"
  else
    echo "# No last-run date — full comparison needed" > "$git_diff_file"
  fi

  local task="You are running DIFF DISCOVERY for a documentation update.

Map git changes to documented components. Do NOT read L4 docs — use the
component inventory to map file paths to component slugs.

Read ONLY these files:
- ${INVENTORY} (component list with paths — use this to map changed files to components)
- ${last_run_file} (last run metadata)
- ${git_diff_file} (pre-computed git diff — already generated, just read it)

For MODIFIED components, you may read the specific changed source files listed in
the git diff to understand WHAT changed (not just that it changed). But do NOT read
L4 docs or any other documentation files.

Mapping rules:
- A changed file at path X belongs to the component whose Path column in the
  inventory is a prefix of X
- If a changed file doesn't match any component path, note it as unmapped

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
- NEW: component directories that exist in source but not in the inventory
- MODIFIED: source files changed since last run within a documented component
- REMOVED: documented components whose directories no longer exist
- STRUCTURAL: renames, moves, reorganisation of component boundaries
- UNCHANGED: no git changes in the component's directory

List affected components in dependency order.

If NO changes detected: output NO_CHANGES_DETECTED as the final line.

${HARD_RULES}"

  spawn_agent "$task" "diff-discovery" "$TIMEOUT" "$(model_for high)" > /dev/null

  if [[ -f "${SCRATCH}/update-diff.md" ]]; then
    if grep -q "NO_CHANGES_DETECTED" "${SCRATCH}/update-diff.md" 2>/dev/null; then
      log "DIFF_DISCOVERY — complete: NO_CHANGES_DETECTED"
      return 1  # Signal no changes
    fi
    local affected
    affected=$(grep -cE '^\| .+ \| (NEW|MODIFIED|REMOVED|STRUCTURAL)' "${SCRATCH}/update-diff.md" 2>/dev/null || echo "0")
    log "DIFF_DISCOVERY — complete (${affected} affected components)"
    return 0
  else
    log "DIFF_DISCOVERY — ❌ failed (no update-diff.md produced)"
    exit 1
  fi
}

# Parse affected component slugs from update-diff.md
# Returns pipe-delimited lines: slug|classification
parse_affected_components() {
  /usr/bin/awk -F'|' '/^\| .+ \| (NEW|MODIFIED|REMOVED|STRUCTURAL)/ {
    gsub(/`/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2);  # slug (strip backticks)
    gsub(/`/, "", $3); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3);  # classification
    if ($2 != "" && $2 != "Slug") print $2 "|" $3
  }' "${SCRATCH}/update-diff.md"
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
  affected_count=$(parse_affected_components | grep -cE '\|(NEW|MODIFIED)$' || echo "0")
  log "UPDATE_COMPREHEND — started (${affected_count} components to re-comprehend)"

  if (( affected_count == 0 )); then
    log "UPDATE_COMPREHEND — skipped (no NEW or MODIFIED components)"
    return
  fi

  local total
  total=$(count_components)
  local i=0

  while IFS='|' read -r slug name path files; do
    i=$((i + 1))

    local classification
    classification=$(get_classification "$slug")

    # Only comprehend NEW and MODIFIED components
    if [[ "$classification" != "NEW" && "$classification" != "MODIFIED" ]]; then
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
    local last_run_date=""
    last_run_date=$(/usr/bin/awk -F': ' '/^date:/{print $2}' "${DOCS_DIR}/builder/last-run.md" 2>/dev/null)

    if [[ -n "$last_run_date" && -n "$path" ]]; then
      local changed_files=""
      changed_files=$(cd "$REPO_PATH" && git log --since="$last_run_date" --name-only --pretty=format: -- "$path" | /usr/bin/sort -u | /usr/bin/grep '[^[:space:]]')
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
        net_lines=$(cd "$REPO_PATH" && git log --since="$last_run_date" --numstat --pretty=format: -- "$path" | /usr/bin/awk '{a+=$1;d+=$2}END{print a+d+0}')
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

      spawn_agent "$mini_task" "update-comprehend-${slug}" "$TIMEOUT" "$(model_for economy)" > /dev/null

      if [[ -f "${SCRATCH}/update-comprehend-${slug}-summary.md" ]]; then
        log "UPDATE_COMPREHEND/${slug} — complete (minimal)"
      else
        log "UPDATE_COMPREHEND/${slug} — ❌ SKIPPED"
        echo "- ${name} (${slug}): update comprehend failed" >> "${DOCS_DIR}/builder/skipped-components.md"
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
    result=$(spawn_agent "$task" "update-comprehend-${slug}" "$TIMEOUT" "$(model_for high)")

    if [[ -f "${SCRATCH}/update-comprehend-${slug}-summary.md" ]]; then
      log "UPDATE_COMPREHEND/${slug} — complete"
    else
      log "UPDATE_COMPREHEND/${slug} — ❌ no summary produced, retrying"
      result=$(spawn_agent "$task" "update-comprehend-${slug}-retry" "$TIMEOUT" "$(model_for high)")
      if [[ -f "${SCRATCH}/update-comprehend-${slug}-summary.md" ]]; then
        log "UPDATE_COMPREHEND/${slug} — complete on retry"
      else
        log "UPDATE_COMPREHEND/${slug} — ❌ SKIPPED after retry"
        echo "- ${name} (${slug}): update comprehend failed after 2 attempts" >> "${DOCS_DIR}/builder/skipped-components.md"
      fi
    fi
  done < <(parse_components)

  local summaries
  summaries=$(find "$SCRATCH" -name "update-comprehend-*-summary.md" 2>/dev/null | wc -l | xargs)
  log "UPDATE_COMPREHEND — complete (${summaries} summaries)"
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

        spawn_agent "$task" "update-write-${slug}" "$TIMEOUT" "$(model_for high)" > /dev/null

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
          local last_run_date=""
          last_run_date=$(/usr/bin/awk -F': ' '/^date:/{print $2}' "${DOCS_DIR}/builder/last-run.md" 2>/dev/null)
          if [[ -n "$last_run_date" && -n "$path" ]]; then
            local changed_code=0
            changed_code=$(cd "$REPO_PATH" && git log --since="$last_run_date" --name-only --pretty=format: -- "$path" | /usr/bin/sort -u | /usr/bin/grep '[^[:space:]]' | /usr/bin/grep -cvE '\.(json|yaml|yml|config|env|md)$|package-lock' || true)
            changed_code=${changed_code:-0}
            local changed_any=0
            changed_any=$(cd "$REPO_PATH" && git log --since="$last_run_date" --name-only --pretty=format: -- "$path" | /usr/bin/sort -u | /usr/bin/grep -c '[^[:space:]]' || true)
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

        spawn_agent "$task" "update-write-${slug}" "$TIMEOUT" "$(model_for high)" > /dev/null
        log "UPDATE_DOCS/${slug} — complete"
        ;;
    esac
    updated=$((updated + 1))
  done < <(parse_components)

  # Regenerate group docs if groups exist and components changed
  phase_write_groups

  # Regenerate overviews and L1 if there were system-level changes
  if [[ "$has_system_changes" == "true" ]] || (( updated > 0 )); then
    log "UPDATE_DOCS/overviews — regenerating"

    spawn_agent "Update the system-level L2 overview. Read all L2 docs in ${DOCS_DIR}/L2/ and the change summary in ${SCRATCH}/update-diff.md. Update ${DOCS_DIR}/L2/overview.md to reflect current state. Preserve <!-- HUMAN --> blocks. ${HARD_RULES}" "update-l2-overview" "$TIMEOUT" "$(model_for high)" > /dev/null
    log "UPDATE_DOCS/L2/overview.md — updated"

    spawn_agent "Update the L4 system overview. Read L4 files in ${DOCS_DIR}/L4/ plus ${DOCS_DIR}/diagrams/dependencies.mmd. Update ${DOCS_DIR}/L4/OVERVIEW.md. NO PROSE. ${HARD_RULES}" "update-l4-overview" "$TIMEOUT" "$(model_for high)" > /dev/null
    log "UPDATE_DOCS/L4/OVERVIEW.md — updated"

    spawn_agent "Update the executive summary. Read L2 docs in ${DOCS_DIR}/L2/ and ${SCRATCH}/update-diff.md. Update ${DOCS_DIR}/L1/executive-summary.md. 1 page max, no code, no jargon. ${HARD_RULES}" "update-l1" "$TIMEOUT" "$(model_for high)" > /dev/null
    log "UPDATE_DOCS/L1/executive-summary.md — updated"
  fi

  log "UPDATE_DOCS — complete (${updated} components updated)"
}

# ============================================================
# PHASE: changelog (update mode)
# ============================================================
phase_changelog() {
  log "CHANGELOG — started"

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

${HARD_RULES}"

  spawn_agent "$task" "changelog" "$TIMEOUT" "$(model_for high)" > /dev/null

  if [[ -f "${DOCS_DIR}/CHANGELOG.md" ]]; then
    log "CHANGELOG — complete"
  else
    log "CHANGELOG — ❌ no CHANGELOG.md produced"
  fi
}

# ============================================================
# PHASE: record (write last-run.md)
# ============================================================
phase_record() {
  local mode="${1:-init}"
  local components_list

  if [[ "$mode" == "update" ]]; then
    components_list=$(parse_affected_components | cut -d'|' -f1 | paste -sd', ' -)
  else
    components_list=$(parse_components | cut -d'|' -f1 | paste -sd', ' -)
  fi

  local profile="large"  # Default; could be read from calibration.md if it existed

  cat > "${DOCS_DIR}/builder/last-run.md" << EOF
date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
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

  spawn_agent "$task" "history-harvest" 600 "$(model_for economy)" > /dev/null

  if [[ -f "${SCRATCH}/history-harvest.md" ]]; then
    log "HISTORY_HARVEST — complete"
  else
    log "HISTORY_HARVEST — ❌ failed"
    exit 1
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

  spawn_agent "$task" "history-epochs" "$TIMEOUT" "$(model_for high)" > /dev/null

  if [[ -f "${SCRATCH}/history-epochs.md" ]]; then
    local epoch_count
    epoch_count=$(grep -c '^## Epoch' "${SCRATCH}/history-epochs.md" 2>/dev/null || echo "0")
    log "HISTORY_EPOCHS — complete (${epoch_count} epochs detected)"
  else
    log "HISTORY_EPOCHS — ❌ failed"
    exit 1
  fi
}

# ============================================================
# PHASE: history_comprehend
# ============================================================
phase_history_comprehend() {
  log "HISTORY_COMPREHEND — started"

  # Extract epoch slugs from epochs file
  local epoch_count
  epoch_count=$(grep -c '^## Epoch' "${SCRATCH}/history-epochs.md" 2>/dev/null || echo "0")

  local i=0
  while (( i < epoch_count )); do
    i=$((i + 1))
    local slug="epoch-$(printf '%02d' "$i")"

    # Resume support
    if [[ -f "${SCRATCH}/history-${slug}.md" ]]; then
      log "HISTORY_COMPREHEND/${slug} — skipped (exists)"
      continue
    fi

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

    spawn_agent "$task" "history-comprehend-${slug}" "$TIMEOUT" "$(model_for high)" > /dev/null

    if [[ -f "${SCRATCH}/history-${slug}.md" ]]; then
      log "HISTORY_COMPREHEND/${slug} — complete (${i}/${epoch_count})"
    else
      log "HISTORY_COMPREHEND/${slug} — ❌ retrying (${i}/${epoch_count})"
      spawn_agent "$task" "history-comprehend-${slug}-retry" "$TIMEOUT" "$(model_for high)" > /dev/null
      if [[ -f "${SCRATCH}/history-${slug}.md" ]]; then
        log "HISTORY_COMPREHEND/${slug} — complete on retry (${i}/${epoch_count})"
      else
        log "HISTORY_COMPREHEND/${slug} — ❌ SKIPPED (${i}/${epoch_count})"
      fi
    fi
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

${HARD_RULES}"

  spawn_agent "$task" "history-write" "$TIMEOUT" "$(model_for high)" > /dev/null

  if [[ -f "${DOCS_DIR}/CHANGELOG.md" ]]; then
    log "HISTORY_WRITE — complete"
  else
    log "HISTORY_WRITE — ❌ no CHANGELOG.md produced"
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

Output on the final line: REVIEW_CLEAN or REVIEW_ISSUES: N unresolved

${HARD_RULES}"

    spawn_agent "$task" "history-review-${iteration}" "$TIMEOUT" "$(model_for high)" > /dev/null

    if [[ -f "${SCRATCH}/history-review-${iteration}.md" ]]; then
      if grep -q "REVIEW_CLEAN" "${SCRATCH}/history-review-${iteration}.md" 2>/dev/null; then
        log "HISTORY_REVIEW — iteration ${iteration}: REVIEW_CLEAN"
        break
      else
        local issues
        issues=$(grep -o "REVIEW_ISSUES: [0-9]*" "${SCRATCH}/history-review-${iteration}.md" | grep -o "[0-9]*$" || echo "?")
        log "HISTORY_REVIEW — iteration ${iteration}: ${issues} issues"
        iteration=$((iteration + 1))
      fi
    else
      log "HISTORY_REVIEW — iteration ${iteration}: ❌ no review file, retrying"
      iteration=$((iteration + 1))
    fi
  done

  log "HISTORY_REVIEW — complete"
}

# ============================================================
# PHASE: package (generate MkDocs Material site)
# ============================================================
phase_package() {
  log "PACKAGE — started"

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

Use relative paths throughout. All files stay in their current locations —
MkDocs serves directly from ${DOCS_DIR}/.

${HARD_RULES}"

  spawn_agent "$task" "package" "$TIMEOUT" "$(model_for economy)" > /dev/null

  if [[ -f "${DOCS_DIR}/mkdocs.yml" ]]; then
    log "PACKAGE — mkdocs.yml generated"
  else
    log "PACKAGE — ❌ mkdocs.yml not generated"
    return 1
  fi

  if [[ -f "${DOCS_DIR}/index.md" ]]; then
    log "PACKAGE — index.md generated"
  else
    log "PACKAGE — ⚠️ index.md not generated (mkdocs.yml may still work)"
  fi

  # Try to build if mkdocs is available
  if command -v mkdocs &>/dev/null; then
    log "PACKAGE — building site..."
    local build_output
    build_output=$(cd "${DOCS_DIR}" && mkdocs build --strict 2>&1) || true
    if [[ -d "${DOCS_DIR}/site" ]]; then
      local page_count
      page_count=$(find "${DOCS_DIR}/site" -name "*.html" | wc -l | xargs)
      log "PACKAGE — site built (${page_count} pages in ${DOCS_DIR}/site/)"
    else
      log "PACKAGE — ⚠️ mkdocs build did not produce site/. Output: ${build_output}"
    fi
  else
    log "PACKAGE — mkdocs not installed. To build: pip install mkdocs-material && cd ${DOCS_DIR} && mkdocs build"
  fi

  log "PACKAGE — complete"
}

# ============================================================
# Main
# ============================================================
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
    spawn_agent "Read ${SKILL_DIR}/references/diagram.md. Read all synthesis notes from ${SCRATCH}/synthesise-*.md and ${DOCS_DIR}/builder/specs/component-inventory.md. Generate Mermaid diagrams to ${DOCS_DIR}/diagrams/. Write ${DOCS_DIR}/diagrams/INDEX.md. ${HARD_RULES}" "diagram" "$TIMEOUT" > /dev/null
    log "DIAGRAM — complete"

    phase_write
    phase_review
    phase_record "init"
    phase_package

    log "COMPLETE — deep-docs init finished"
    ;;
  update)
    # Diff discovery — detect what changed
    if ! phase_diff_discovery; then
      log "COMPLETE — no changes detected, docs are up to date"
      exit 0
    fi

    # Targeted comprehension for affected components
    phase_update_comprehend

    # Re-synthesise if integration points changed
    local needs_synthesis=false
    if parse_affected_components | grep -qE '\|(NEW|REMOVED)$'; then
      needs_synthesis=true
    fi
    # Also re-synthesise if >3 components modified (likely cross-cutting change)
    local modified_count
    modified_count=$(parse_affected_components | grep -c '|MODIFIED$' || echo "0")
    if (( modified_count > 3 )); then
      needs_synthesis=true
    fi

    if [[ "$needs_synthesis" == "true" ]]; then
      log "SYNTHESISE — started (integration points changed)"
      spawn_agent "Read ${SKILL_DIR}/references/synthesise.md. Read all summary scratchpads from ${SCRATCH}/update-comprehend-*-summary.md and ${SCRATCH}/comprehend-*-summary.md. Read ${INVENTORY}. Write synthesis files to ${SCRATCH}/synthesise-01-integration.md, synthesise-02-flows.md, synthesise-03-architecture.md. Focus on what CHANGED. ${HARD_RULES}" "update-synthesise" "$TIMEOUT" "$(model_for high)" > /dev/null
      log "SYNTHESISE — complete"

      log "DIAGRAM — started (updating)"
      spawn_agent "Read ${SKILL_DIR}/references/diagram.md. Read synthesis notes from ${SCRATCH}/synthesise-*.md and ${INVENTORY}. Update Mermaid diagrams in ${DOCS_DIR}/diagrams/. Update ${DOCS_DIR}/diagrams/INDEX.md. ${HARD_RULES}" "update-diagram" "$TIMEOUT" "$(model_for economy)" > /dev/null
      log "DIAGRAM — complete"
    fi

    # Surgical doc updates
    phase_update_docs

    # Changelog
    phase_changelog

    # Review (same as init — verifies all updated docs)
    phase_review

    # Record last run
    phase_record "update"

    log "COMPLETE — deep-docs update finished"
    ;;
  history)
    # Parse history-specific options from remaining args (after $4/model)
    local history_since=""
    local history_last=""
    local history_granularity="major"

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

    mkdir -p "$SCRATCH"

    phase_history_harvest "$history_since" "$history_last" "$history_granularity"
    phase_history_epochs "$history_granularity"
    phase_history_comprehend
    phase_history_write
    phase_history_review

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
