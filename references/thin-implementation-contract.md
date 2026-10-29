# Bounded source-grounded workflow: implementation contract

This is the commissioned local first slice, not a new wiki product or a claim of universal repository understanding. Preserve the legacy tiered engine and existing documentation; make bounded questions the recommended path.

## Owned boundaries

- Implement a Python standard-library CLI at `scripts/grounded.py`, with tests at `tests/test-grounded.py`. No mandatory vector, graph, indexer, remote service or LLM SDK.
- Source is a clean Git checkout pinned to an exact commit. Read source via pinned Git objects where practical. Refuse dirty/moving source at admission and completion. Never modify source, existing documentation or HUMAN blocks.
- Output must be outside source and a dedicated new directory. Refuse to adopt arbitrary non-empty output directories. Keep a versioned manifest and append-only receipts with atomic writes; exclude secrets and operational files by default. Do not copy a whole private checkout into generated output.
- Keep handbook/human intent separate from machine-derived reference and evidence-backed answers. No generated intent or operational certification.

## User-facing commands and minimum evidence contract

The implementing worker may refine CLI details but document and report exact commands promptly.

1. `init --repo PATH --out PATH`: pin clean HEAD; create a deterministic compact package/project inventory from tracked package.json/csproj/pyproject files without dumping configuration values. Preserve source identity.
2. `question --out PATH --id SLUG --question TEXT`: create a bounded investigation request identifying source pin, safety rules, expected JSON answer and evidence requirements. Use existing source tools rather than recursive summaries. Optional `--runner-json '["executable", ...]'` invokes a provider-neutral stdin/stdout adapter with a per-call timeout and persisted cumulative call/wall-time limits; failed exit, malformed output or timeout cannot become accepted answers. Pass selected model explicitly in request; adapter must report actual model or unknown. Do not claim enforcement of out-of-band/manual agent costs.
3. `accept --out PATH --id SLUG --answer FILE`: accept a structured response from an existing authorised agent. Every code claim needs pinned relative path, positive start/end line and exact quote. Record code-derived claims separately from human intent, runtime unknowns and general gaps. Verify citation spans mechanically; mark semantic status as unreviewed, never infer truth from citation validity. Refuse path traversal, wrong source revision, symlinks/out-of-tree reads, mismatched quote, missing citations for code claims, stale manifests and overwritten human material. Persist hashes of supporting files plus explicit dependency/watch paths and model/agent metadata.
4. `verify --out PATH`: recheck artifacts, answer/schema/citation integrity, source identity, output hashes and no unsupported complete/audited claim. Fail on tampering or partial required artifacts.
5. `freshness --out PATH --repo PATH`: compare tracked target revision to original; flag directly cited/dependent changes, deleted files and configuration changes. Conservatively report unknown-impact changes/new files as needing review rather than asserting unaffected freshness. No silent source-pin/baseline advancement.
6. `build --out PATH`: emit browsable MkDocs Markdown/config using existing renderer, small index, reference inventory and curated answers; leave existing handbook/HUMAN content untouched. Actual `mkdocs build --strict` plus local link/HTTP smoke required before claiming usable site. Publishing/deployment is separate.

## Required tests

Exercise actual CLI with disposable real Git repositories: happy path, deterministic inventory, no LLM necessary for mechanical commands, unchanged resume, failed runner with plausible output, timeout and cumulative budgets, explicit model request, malformed response, unsupported/wrong-line quotes, source moving/dirty, cited/dependency/config/new/deleted-file freshness, output tampering and paths/symlink escapes, human-content preservation. Synthetic test answers must be labelled fixtures, not model-quality evidence.

## Real Buzz acceptance

After feature branch code is tested and committed, fast-forward Buzz's verified actual default branch (`master`, not absent `main`) and pin it. Run a bounded set of real questions across orientation, cross-package behaviour, precise UI edge case, backend/configuration and source-only uncertainty. Use authorised existing agent tooling; no new commercial/private-code integration. Validate citations and independently review semantic support, correcting or dropping unsupported claims. Record actual model metadata when available, elapsed/call evidence without invented costs, complete artifact counts and source/docs preservation. Keep generated Buzz content and raw operational receipts outside the public DeepDocs Git repository.

The old exhaustive audit remains paused. Full old-baseline certification is not a new-workflow acceptance gate. Do not automatically start background watchers, PRs, merges or deployments.
