#!/usr/bin/env bash
set -euo pipefail

# deep-docs orchestrator — drives the per-component loop mechanically
# Usage: ./orchestrate.sh <phase> <repo_path> <docs_dir> [model]
#
# Phases: discover, comprehend, write, review
# The script reads component-inventory.md, loops through each component,
# and spawns one OpenClaw sub-agent per component.

PHASE="${1:?Usage: orchestrate.sh <phase> <repo_path> <docs_dir> [model]}"
REPO_PATH="${2:?Missing repo_path}"
DOCS_DIR="${3:?Missing docs_dir}"
MODEL="${4:-anthropic/claude-sonnet-4-6}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROGRESS="${DOCS_DIR}/builder/progress.md"
INVENTORY="${DOCS_DIR}/builder/specs/component-inventory.md"
SCRATCH="${DOCS_DIR}/builder/.scratch"
TIMEOUT=1800  # 30 min per sub-agent

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
parse_components() {
  grep -E '^\| [0-9]' "$INVENTORY" | while IFS='|' read -r _ num name slug path files lang purpose key_files deps _rest; do
    # Trim whitespace
    name=$(echo "$name" | xargs)
    slug=$(echo "$slug" | xargs)
    path=$(echo "$path" | xargs)
    files=$(echo "$files" | xargs)
    echo "${slug}|${name}|${path}|${files}"
  done
}

count_components() {
  parse_components | wc -l | xargs
}

# Spawn a sub-agent and wait for completion
spawn_agent() {
  local task="$1"
  local label="$2"
  local agent_timeout="${3:-$TIMEOUT}"

  openclaw agent \
    --message "$task" \
    --timeout "$agent_timeout" \
    --json 2>/dev/null | jq -r '.content // .error // "no output"'
}

# ============================================================
# PHASE: comprehend
# ============================================================
phase_comprehend() {
  local total
  total=$(count_components)
  log "COMPREHEND — started (${total} components)"

  local i=0
  parse_components | while IFS='|' read -r slug name path files; do
    i=$((i + 1))
    
    # Check if summary already exists (resume support)
    if [[ -f "${SCRATCH}/comprehend-${slug}-summary.md" ]]; then
      log "COMPREHEND/${slug} — skipped (summary exists, ${i}/${total})"
      continue
    fi

    local mode="single-agent"
    local files_int="${files//[^0-9]/}"
    files_int="${files_int:-0}"
    if (( files_int > 30 )); then
      mode="per-loop (${files_int} files)"
    fi

    log "COMPREHEND/${slug} — started (${mode}, ${i}/${total})"

    # Collect dependency summaries
    local dep_summaries="None — check component-inventory.md for dependencies and read their summaries from ${SCRATCH}/ if needed."

    local task="You are studying the '${name}' component of a codebase at ${REPO_PATH}.
Your job is to BUILD UNDERSTANDING through iterative study. Do NOT write documentation.

Read these first:
- ${DOCS_DIR}/builder/interview-notes.md (user context)
- ${DOCS_DIR}/builder/specs/component-inventory.md (find your component's entry)

Component path: ${REPO_PATH}/${path}
Component slug: ${slug}

Read the comprehension loop instructions at ${SKILL_DIR}/references/comprehend.md.
Based on the file count (${files} source files), use the appropriate profile:
- ≤30 files: SMALL PROFILE (3 loops)
- >30 files: LARGE PROFILE (7 loops)

Dependency context: ${dep_summaries}
Read any relevant dependency summaries from ${SCRATCH}/comprehend-*-summary.md

After ALL loops, write a summary scratchpad to:
${SCRATCH}/comprehend-${slug}-summary.md

On completion, append a progress line to ${PROGRESS}

${HARD_RULES}"

    local result
    result=$(spawn_agent "$task" "comprehend-${slug}" "$TIMEOUT")

    # Verify output
    if [[ -f "${SCRATCH}/comprehend-${slug}-summary.md" ]]; then
      log "COMPREHEND/${slug} — complete (${i}/${total})"
    else
      log "COMPREHEND/${slug} — ❌ no summary produced, retrying (${i}/${total})"
      # Retry once
      result=$(spawn_agent "$task" "comprehend-${slug}-retry" "$TIMEOUT")
      if [[ -f "${SCRATCH}/comprehend-${slug}-summary.md" ]]; then
        log "COMPREHEND/${slug} — complete on retry (${i}/${total})"
      else
        log "COMPREHEND/${slug} — ❌ SKIPPED after retry (${i}/${total})"
        echo "- ${name} (${slug}): no summary produced after 2 attempts" >> "${DOCS_DIR}/builder/skipped-components.md"
      fi
    fi
  done

  local summaries
  summaries=$(find "$SCRATCH" -name "comprehend-*-summary.md" | wc -l | xargs)
  log "COMPREHEND — complete (${summaries}/${total} summaries)"
}

# ============================================================
# PHASE: write
# ============================================================
phase_write() {
  local total
  total=$(count_components)
  log "WRITE — started (${total} components)"

  local i=0
  parse_components | while IFS='|' read -r slug name path files; do
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
    result=$(spawn_agent "$task" "write-${slug}" "$TIMEOUT")

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
      result=$(spawn_agent "$task" "write-${slug}-retry" "$TIMEOUT")
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
  done

  # Write overviews and L1
  log "WRITE/overviews — started"

  spawn_agent "Write the system-level L2 overview. Read all L2 docs in ${DOCS_DIR}/L2/ and synthesis notes in ${SCRATCH}/synthesise-*.md. Write ${DOCS_DIR}/L2/overview.md covering system architecture, component relationships, end-to-end flows. Embed relevant diagrams from ${DOCS_DIR}/diagrams/. ${HARD_RULES}" "write-l2-overview" "$TIMEOUT" > /dev/null
  log "WRITE/L2/overview.md — complete"

  spawn_agent "Write the L4 system overview for AI agents. Read the first 20 lines of each L4 file in ${DOCS_DIR}/L4/ plus ${DOCS_DIR}/diagrams/dependencies.mmd. Write ${DOCS_DIR}/L4/OVERVIEW.md — NO PROSE, only headings, tables, code blocks. Include: full file inventory, dependency graph, all env vars, all CLI entry points. ${HARD_RULES}" "write-l4-overview" "$TIMEOUT" > /dev/null
  log "WRITE/L4/OVERVIEW.md — complete"

  spawn_agent "Write the executive summary (LAST document). Read all L2 docs in ${DOCS_DIR}/L2/ and ${DOCS_DIR}/builder/interview-notes.md. Write ${DOCS_DIR}/L1/executive-summary.md — 1 page max, no code, no jargon. What the project does, business value, key components, current status, key risks. ${HARD_RULES}" "write-l1" "$TIMEOUT" > /dev/null
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

2. COMPONENT DETECTION — Identify logical components at the PACKAGE level (not module level). Each independently-packaged library, API, UI app, or infrastructure stack is its own component. For each: directory, SOURCE FILE COUNT, language, entry points, purpose. Detect inter-component dependencies.

3. EXISTING DOCS — Find .md files, doc comments, OpenAPI specs. Assess quality.

4. STACK DETECTION — Languages, frameworks, infrastructure, data stores.

OUTPUT two files:

${DOCS_DIR}/builder/specs/scope-and-goals.md
${DOCS_DIR}/builder/specs/component-inventory.md

Use this table format for the inventory:
| # | Component | Slug | Path | Source Files | Language | Purpose | Key Files | Dependencies |

IMPORTANT: Each package/workspace is its own component. Do NOT collapse multiple packages into one 'module' entry. If a module has 6 packages (contracts, cosmos, app, api, ui, infra), that's 6 components.

${HARD_RULES}"

  spawn_agent "$task" "discover" 600 > /dev/null

  if [[ -f "$INVENTORY" ]]; then
    local count
    count=$(count_components)
    log "DISCOVER — complete (${count} components)"
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
    log "REVIEW — iteration ${iteration}/${max_iterations}"

    local i=0
    parse_components | while IFS='|' read -r slug name path files; do
      i=$((i + 1))

      # Skip if no docs exist
      if [[ ! -f "${DOCS_DIR}/L2/${slug}.md" && ! -f "${DOCS_DIR}/L3/${slug}.md" && ! -f "${DOCS_DIR}/L4/${slug}.md" ]]; then
        continue
      fi

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

      spawn_agent "$task" "review-${slug}" "$TIMEOUT" > /dev/null
    done

    # Aggregation
    local issues
    issues=$(grep -l "COMPONENT_ISSUES" "${SCRATCH}"/review-*.md 2>/dev/null | wc -l | xargs)

    if (( issues == 0 )); then
      log "REVIEW — iteration ${iteration}: REVIEW_CLEAN"
      break
    else
      log "REVIEW — iteration ${iteration}: ${issues} components with issues"
      iteration=$((iteration + 1))
    fi
  done

  # Write REVIEW.md
  spawn_agent "Aggregate all review files from ${SCRATCH}/review-*.md into ${DOCS_DIR}/REVIEW.md. Read only files with COMPONENT_ISSUES. Write summary table. ${HARD_RULES}" "review-aggregate" "$TIMEOUT" > /dev/null
  log "REVIEW — complete"
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

    log "COMPLETE — deep-docs init finished"
    ;;
  *)
    echo "Unknown phase: $PHASE"
    echo "Usage: orchestrate.sh <discover|comprehend|write|review|all> <repo_path> <docs_dir> [model]"
    exit 1
    ;;
esac
