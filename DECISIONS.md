# Design Decisions

Record of key design decisions for the deep-docs skill.

## 2026-03-07: Bottom-up comprehension loops

**Decision:** Document repos through iterative comprehension loops (inventory → data → logic → errors) rather than "read everything then write."

**Rationale:** Mirrors how humans actually understand codebases. Each loop builds on the previous one's output. Writing happens only after genuine understanding is established.

## 2026-03-07: L1-L4 audience tiers

**Decision:** Four documentation tiers: L1 (exec summary), L2 (BA/product), L3 (developer), L4 (model context).

**Rationale:** Different audiences need fundamentally different docs. L4 for AI agents is the differentiator — structured, no-prose, context-window-efficient. Adapted from the Pollen docs builder (~/Projects/Spafax/pollen/docs/builder/).

## 2026-03-07: Document as-is only

**Decision:** Never suggest code improvements, fixes, or refactoring. Hard rule.

**Rationale:** Documentation tools that mix in suggestions produce noisy, opinionated output. deep-docs is a mirror, not a critic. If something looks like a bug, describe actual behaviour neutrally.

## 2026-03-07: Plan → Build → Review loop (from Pollen "Ralph loop")

**Decision:** Three-phase methodology: plan (gap analysis), build (write docs), review (verify against source). Review loops until clean.

**Rationale:** Proven on the Pollen project. Review loop catches hallucinated paths, wrong signatures, stale descriptions.

## 2026-03-07: Separate discover + calibrate phases

**Decision:** Auto-discover components and auto-select comprehension depth based on repo size.

**Rationale:** Makes the skill generic — no manual component inventory needed. Calibration prevents over-engineering small repos and under-serving large ones.

## 2026-03-07: Per-component sub-agents for write + review

**Decision:** One sub-agent per component (not one giant agent for everything).

**Rationale:** Avoids context window overflow. Each agent focuses on one component with relevant scratchpad context only.

## 2026-03-07: Scratchpad kept, not loaded

**Decision:** Comprehension scratchpad files are kept after completion but not loaded into context for subsequent runs.

**Rationale:** Useful reference material without polluting future context. Update mode reads them selectively.

## 2026-03-07: Separate docs repo support

**Decision:** Output can target a separate repo, not just `docs/` in the source repo.

**Rationale:** Monorepos, open-source projects with private docs, centralised doc repos.

## 2026-03-07: Cumulative changelog

**Decision:** CHANGELOG.md is append-only across update runs. History mode can generate retrospective changelog from git.

**Rationale:** Living history of codebase evolution. Changelog comprehension uses its own loops (catalogue → semantics → impact → write).

## 2026-03-07: Review split (per-component + aggregation)

**Decision:** Review phase uses per-component sub-agents plus a final aggregation agent.

**Rationale:** Single review agent reading all docs for a large repo would blow context. Per-component review keeps context small. Aggregation catches cross-cutting consistency issues.

## 2026-03-07: Known-issues tracking across review iterations

**Decision:** Per-component review agents write to their own files. Aggregation agent consolidates into review-known-issues.md. Next iteration reads this to skip resolved items.

**Rationale:** Prevents oscillation (UNVERIFIED tag added then removed then re-added). Avoids race conditions from parallel agents writing to shared file.

## 2026-03-07: `<!-- HUMAN -->` markers for preserved content

**Decision:** Update mode preserves sections wrapped in `<!-- HUMAN --> ... <!-- /HUMAN -->`. All other content assumed deep-docs generated.

**Rationale:** "Preserve human edits" is unimplementable without explicit markers. This makes it deterministic.

## 2026-03-07: Batched synthesis for large repos (>20 components)

**Decision:** Synthesis groups components by dependency level, runs per-group synthesis, then a final pass reads group outputs only.

**Rationale:** 50 component summaries would blow context. Group-level synthesis captures domain-specific patterns. Final pass connects the groups.

## 2026-03-07: Middle-ground sub-agent granularity

**Decision:** Small/medium profiles run all comprehension loops in a single sub-agent per component. Large profile (or any component with >30 source files) splits into per-loop sub-agents where each loop agent reads previous loop outputs.

**Rationale:** Fully granular (per-loop agents for everything) creates too much orchestration overhead for small repos. But large components with 50+ files can't fit 7 loops in one session. Middle ground: automatic escalation when a component is too large for single-agent comprehension.

## 2026-03-07: History mode epoch detection

**Decision:** Group git history into meaningful epochs (not 1:1 with commits) using signals like new directories, large refactors, activity gaps, and tag boundaries.

**Rationale:** Commit-by-commit changelogs are noise. Epoch-based narrative tells the actual story of how the project evolved.
