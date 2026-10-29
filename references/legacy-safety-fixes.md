# Narrow legacy runtime safety fixes

This note covers `scripts/orchestrate.sh`, not the bounded source-grounded CLI. It does not restart or commission the exhaustive legacy audit. Existing baseline, inventory, coverage, source and publishing gates remain required; a clean review protocol marker is not independent proof of factual correctness.

## Review acceptance and resume

- A component review is accepted only after a **successful process exit**, a valid terminal outcome marker, unchanged clean source and a matching document fingerprint. A failed or timed-out process cannot certify a clean artifact it wrote before failing.
- Standalone review identity is now the protocol version, phase, pinned source commit and full required scope hash—not process ID or wall clock. Same-source retries retain successful component results; document changes invalidate only the affected component. Source/scope changes invalidate scoped results. Protocol versioning intentionally invalidates pre-fix receipts that may have accepted a failed process.
- The aggregate has its own fingerprint over the scope/state, component reviews/fingerprints/current documents and `REVIEW.md`. A fully unchanged successful resume makes no agent calls. An incomplete scope gets a mechanical incomplete summary, not an additional paid aggregation call.
- `DEEP_DOCS_REVIEW_SLUGS=alpha,beta` restricts **dispatch only**. Unknown/malformed selectors fail; omitted required components still block completion. It never shrinks the coverage gate or advances the baseline on a partial review.
- `DEEP_DOCS_REVIEW_MAX_ITERATIONS` accepts `1`, `2` or `3` (default). Existing unresolved findings are saved as `review-<slug>.previous.md` and passed to the next reviewer with the quality model, including across shell restarts. Unsupported material claims and HUMAN content are not waived.

## History completion

- Every mandatory history stage must exit successfully, produce fresh required output, and leave the pinned source HEAD and clean source tree unchanged. Main stops on any failed stage or exhausted dispatch budget; it never prints history completion after a denied/failed reviewer.
- History scratch harvest, epochs, per-epoch notes, writer receipt and reviews are cleared on entry. Existence-only epoch resume is disabled because it has no source/range-bound receipt. Existing `CHANGELOG.md` is retained for prepend semantics, but cannot certify the writer: a fresh `history-write-complete.md` ending in `HISTORY_WRITE_COMPLETE` is required.
- Review acceptance requires one exact terminal `REVIEW_CLEAN` outcome after a successful reviewer exit. Missing, stale, malformed, nonterminal, contradictory and unresolved outcomes fail closed; unresolved/malformed outcomes remain bounded to three review iterations. Failed-process or source-mutating clean artifacts are removed. History still never changes `last-run.md`.
- The initial `all` diagram dispatch now explicitly uses the economy model, matching the update diagram path; an empty economy setting still selects quality.

## Explicit model adapter

The old `openclaw agent --local` launcher accepted a model argument but never used it. That silent behaviour is removed. The default legacy adapter now fails **before dispatch**, explaining that it cannot enforce the requested model and requiring an explicit adapter choice. It does not rewrite global OpenClaw configuration or invent an `openclaw agent --model` flag.

The supported adapter in this patch is opt-in Hermes:

```bash
DEEP_DOCS_AGENT_ADAPTER=hermes \
DEEP_DOCS_ECONOMY_MODEL='your-supported-economy-model' \
DEEP_DOCS_HERMES_PROVIDER='your-configured-provider' \
DEEP_DOCS_REVIEW_SLUGS='the-pending-component-slug' \
DEEP_DOCS_REVIEW_MAX_ITERATIONS=1 \
bash scripts/orchestrate.sh review /absolute/clean/source /absolute/external/docs 'your-supported-quality-model'
```

Omit `DEEP_DOCS_HERMES_PROVIDER` to use the existing Hermes provider selection. An explicitly empty `DEEP_DOCS_ECONOMY_MODEL=''` now really uses the quality model everywhere. The adapter checks the installed `hermes chat --help` interface, then passes the selected value through `hermes chat --model MODEL --query TASK --quiet`, with optional `--provider`. It adds no approval-bypass flag. Unsupported models/providers fail through the adapter; it does not silently replace them itself.

Interface evidence:

- Installed `hermes --help` and `hermes chat --help` were inspected directly; chat documents `--model`, `--query`, `--quiet` and `--provider`.
- [Hermes official CLI reference](https://hermes-agent.nousresearch.com/docs/reference/cli-commands) ([official source](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/reference/cli-commands.md)) confirms the per-run model override.
- OpenClaw was **not installed** in the validation environment. Its [current official agent reference](https://docs.openclaw.ai/cli/agent) ([official source](https://github.com/openclaw/openclaw/blob/main/docs/cli/agent.md)) documents a newer, separate `openclaw agent exec --model` interface. That is not the legacy `agent --local` call and is not implemented or falsely claimed tested here. It is an option for a separately tested future adapter.

The journal records `requested_model` and `actual_model: null`. Passing a real CLI override proves dispatch intent, not the provider's final serving identity, fallback behaviour, token use or cost. This patch makes no actual-model/cost claim from labels alone.

## Durable invocation and elapsed-time limits

All dispatched agents use the same atomic, fsynced `builder/.scratch/agent-budget.json` ledger for that docs output. It persists across phases, source changes and shell restarts. Limits are:

| Variable | Default | Meaning |
|---|---:|---|
| `DEEP_DOCS_MAX_INVOCATIONS` | `200` | Cumulative agent-process dispatch reservations |
| `DEEP_DOCS_MAX_AGENT_SECONDS` | `14400` | Cumulative measured supervised agent elapsed seconds |
| `DEEP_DOCS_AGENT_TIMEOUT_SECONDS` | Existing phase timeout | Additional per-call ceiling, capped by remaining cumulative time |

Limits must be positive and finite; the invocation count must be an integer. Cumulative ceilings are persisted too: omitting the variables in a later shell keeps the saved limits rather than restoring larger defaults. A CLI-output lock prevents simultaneous legacy runs from changing review state, and a ledger lock serializes reservations. The implementation requires Python 3, POSIX process groups/`fcntl`, and `flock` (verified on Linux).

Before launch, one invocation and its full allowed duration are durably reserved. Normal termination reconciles elapsed time and exit status, including failures. Timeouts kill the owned process group, including ordinary descendants, and return failure. No stdout accumulation or token-price guesses are used. Exhaustion denies new calls; raising an environment ceiling is an explicit increase to the **cumulative total**, not a reset.

A killed supervisor leaves a `running` reservation charged in full and blocks further dispatch. Inspect the private ledger and ensure the original process/descendants are stopped before manually reconciling an abandoned attempt; preserve its invocation and conservative charge. Do not delete the ledger to obtain an unrecorded allowance. A SIGKILL or machine crash cannot execute cleanup; the ledger's conservative block is not proof that remote work or deliberately detached descendants stopped.

Limits cover supervised agent processes, not mechanical Git/MkDocs time, internal model-request counts, provider billing, historical pre-upgrade work or manual/out-of-band calls. Credentials and Hermes session logs remain in the existing operator profile, not this repository. Keep generated docs and operational receipts outside the public checkout. Trusted operators can edit their own local ledger; this is not an adversarial accounting service or an agent filesystem sandbox.

## Regression evidence

Run from the DeepDocs checkout:

```bash
bash tests/test-orchestrate.sh
python3 -B tests/test-update-cli.py
DEEPDOCS_MKDOCS_BIN=/absolute/path/to/mkdocs python3 -B tests/test-package-site.py
```

The full-CLI fixtures launch the actual Bash entry point with disposable real Git histories and explicitly synthetic agent executables. They cover failed-process clean markers, unchanged and partial standalone resume, source/doc invalidation, source dirt, focused retry coverage, preserved unresolved findings, durable budgets across restart/phase changes, crash reservations, timeout/descendant cleanup, invalid limits/ledger and exact economy/quality/provider adapter arguments. History regressions also cover all mandatory-stage process failures and missing outputs, stale/malformed/nonterminal/contradictory/unresolved review markers, budget denial before review, source mutation, the positive history path and exact initial `all` diagram model selection. Existing lifecycle/baseline/navigation regressions remain in the same suite. The expanded full-CLI suite passed all 42 tests; all 3 package tests passed using **real MkDocs strict builds** with synthetic agent-written fixtures. These are runtime safety/build tests, not model-quality or real Buzz audit evidence.
