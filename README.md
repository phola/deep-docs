# DeepDocs

Source-grounded repository understanding: **small maintained handbook, bounded questions, and mechanical reference**. Preserve useful explanations instead of requiring an exhaustive generated encyclopaedia before anyone can use the output.

**Source stays read-only. Generated explanations are drafts, not runtime or whole-repository certification.**

## Recommended workflow

Use `scripts/grounded.py` with Python 3.11+, Git and a POSIX host (Linux/macOS). It uses the standard library for source identity, question/evidence records, verification and freshness. Rendering reuses MkDocs; there is no required vector database, graph service, hosted wiki or model SDK.

1. Initialise a dedicated output directory from a clean Git checkout. The source revision is pinned; existing docs are not imported as unquestioned facts or rewritten.
2. Ask a small number of useful questions. Use an existing authorised agent to locate entry points, follow relevant definitions/configuration/tests and answer from that source snapshot.
3. Retain worthwhile answers with exact source spans, explicit unknowns, dependencies and agent/model metadata. Keep human intent separate from code-derived facts.
4. Verify citation bytes and artifact integrity, then review whether the cited implementation actually supports each claim.
5. Build a compact static site with an index, mechanical package/project reference and retained answers. Deployment is a separate action.
6. Check freshness after source changes. Changed evidence or uncertain impact means review is needed; it is not permission to silently carry old claims forward.

See [the command and answer contract](references/grounded-workflow.md) for executable examples, adapter details, limits and failure behaviour.

### Important limits

- Citation validation proves that quoted source exists at the pinned revision. It does **not** prove semantic correctness; accepted answers remain explicitly unreviewed until separately assessed.
- A dependency watch list is not a complete dependency graph. Unknown-impact changes must remain visible rather than being labelled unaffected.
- Source cannot establish the currently deployed version, live configuration, actual permissions or business intent by itself. Those need separately authorised evidence or human input.
- A provider-neutral runner is optional. Its local process/cumulative limits do not measure manual/out-of-band agent spend. Exact model/cost data may be unknown and must not be invented.
- Local source access does not imply local inference. Only use approved model endpoints; do not send private code to a new commercial service by default.
- This first slice is not a chat service, language-server implementation or self-updating documentation platform. Existing navigation and agent tools do the investigation.

## Existing tiered documentation

The legacy Bash/OpenClaw engine remains available for an explicitly requested full tiered run or compatible existing outputs. It is **not the recommended default** for a new repository question.

It supports L1 leadership summaries, L2 product/group explanations, L3 developer guides and L4 structured reference. Existing output, human-authored sections and failed/incomplete review evidence remain valuable; replacing the default workflow does not delete or certify them.

See [legacy orchestration](SKILL.md#legacy-tiered-workflow), [incremental updates](references/update.md), [review](references/review.md) and [legacy safety fixes](references/legacy-safety-fixes.md). Review resumes and retries must respect source/artifact identity, invocation failures, budgets and honest completeness. A successful static build is not a successful semantic audit.

## Verification

```bash
# For real-renderer checks, install mkdocs-material on PATH or set
# DEEPDOCS_MKDOCS_BIN to an existing mkdocs executable before these commands.
python3 -B tests/test-grounded.py
bash tests/test-orchestrate.sh
python3 -B tests/test-update-cli.py
python3 -B tests/test-package-site.py
```

Offline synthetic answers test lifecycle and validation behaviour, not model accuracy. Actual source-grounded investigations and semantic review must be reported separately. No private source, generated private answers, credentials or operational captures belong in this public tool repository.

## Layout

- `scripts/grounded.py` — bounded source/evidence workflow.
- `references/grounded-workflow.md` — commands, schema and operational limits.
- `references/thin-implementation-contract.md` — first-slice acceptance boundaries.
- `scripts/orchestrate.sh` — retained tiered engine.
- `references/` — phase guides and implementation decisions.
- `tests/` — disposable Git/CLI and real-renderer regressions.

## License

MIT
