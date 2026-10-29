# Bounded source-grounded workflow

## CLI checkpoint (schema version 1)

Run from the DeepDocs checkout on Linux/macOS with Python 3.11+ and Git. Mechanical commands use only the Python standard library; no model provider is configured or called implicitly. The local lock and bounded process-group runner use POSIX APIs.

```bash
python3 scripts/grounded.py init --repo /absolute/clean/source --out /absolute/new-output
python3 scripts/grounded.py question --out /absolute/new-output --id orientation --question 'What are the main packages?' --model unknown
python3 scripts/grounded.py accept --out /absolute/new-output --id orientation --answer /absolute/answer.json
python3 scripts/grounded.py verify --out /absolute/new-output
python3 scripts/grounded.py freshness --out /absolute/new-output --repo /absolute/clean/target
python3 scripts/grounded.py build --out /absolute/new-output --mkdocs /absolute/path/to/mkdocs
```

`init` accepts `--max-calls` (default 10), `--max-wall-seconds` (default 600). These immutable limits apply only to adapter invocations from this output directory, not manual agents, unrelated processes or money. Repeating the exact init against unchanged output verifies and resumes without repinning.

`question` writes `requests/SLUG.json` and returns its location. `--model` defaults to the literal `unknown`; pass the selected model explicitly when known. Question IDs match `[a-z0-9][a-z0-9-]{0,63}`. An unchanged request resumes; a conflicting question/model is refused. Optional `--runner-json '["/absolute/adapter", "arg"]' --timeout 60` executes the command without a shell, sending the request as JSON on stdin. Successful stdout must be exactly one answer JSON object using the schema below; stderr is not published. A successful adapter response is validated and accepted, not merely saved as prose. A failed exit, timeout or malformed/invalid response never becomes an answer. Failed attempts consume their call reservation. Wall-time allowance is reserved before invocation, settled to measured elapsed time on completion, and retained in full if the CLI is interrupted. Limits cannot be raised during resume.

## Exact answer JSON

Every key shown below is required; unknown keys are rejected. Arrays may be empty (an unknown-only answer is valid). The source revision must be the full pinned commit from `manifest.json`, not a branch or abbreviated SHA. This example is a **synthetic schema fixture**, not an evaluated answer.

```json
{
  "schema_version": 1,
  "id": "orientation",
  "source_commit": "FULL_PINNED_COMMIT",
  "model": "unknown",
  "agent": "authorised-agent-name-or-unknown",
  "code_claims": [
    {
      "text": "Fixture: the module defines a constant.",
      "citations": [
        {"path": "src/example.py", "start_line": 1, "end_line": 1, "quote": "VALUE = 1"}
      ]
    }
  ],
  "human_intent": [],
  "runtime_unknowns": ["Source inspection does not establish deployed behaviour."],
  "gaps": [],
  "dependency_paths": ["src/example.py"],
  "watch_paths": ["src", "package.json"]
}
```

`human_intent` contains objects `{"text":"...","attribution":"human-provided source/person"}`, not inferred intent. Runtime unknowns and gaps are strings. Every code claim needs at least one citation. Citation lines are one-based and inclusive. `quote` must equal the complete selected lines joined with `\n` without the final line terminator; CRLF source is split into logical lines. Supporting hashes cover original raw bytes, not normalised text. `dependency_paths` must be tracked regular files at the pin. `watch_paths` are explicit relative file/directory paths, including paths not yet present; no glob patterns, traversal or symlink components. Source symlinks, submodules, excluded secrets/operational paths and oversized/binary citations are refused. Semantic status is always **unreviewed**: matching a quote does not prove the claim follows from it. Independent semantic review belongs in a separately retained human review, not a fabricated certification flag.

## Package and trust boundary

The versioned `manifest.json` records source root/Git identity/full commit/tree, immutable budgets, request/answer registrations and hashes of owned artifacts. `manifest.sha256` detects accidental manifest changes. `receipts/` contains append-only immutable numbered JSON receipts; failed adapter calls are retained. The output root must be a dedicated new or empty directory outside source and its Git metadata; existing unrelated non-empty directories are rejected. Every resumed command checks that separation before even opening its output lock, so moving the registry into an ignored source directory or shared worktree metadata is refused. All commands fail on missing/changed owned artifacts, symlink paths and an unexpectedly dirty/moved original source. Source reads use pinned Git blobs. No checkout copy is made.

`inventory.json` is a deterministic inventory of eligible tracked `package.json`, `*.csproj` and `pyproject.toml` paths, project kinds and raw-byte hashes; it does not export configuration values. Answers retain only cited snippets and supporting file hashes. Sensitive filenames and operational paths are excluded by default. This is not content-based secret detection: review every supplied answer before publication. The local registry is not cryptographically signed and does not defend against a malicious owner rewriting the manifest and every receipt consistently. Adapter execution is authorised local code, not an OS sandbox; the request forbids source writes/network uploads but the CLI cannot constrain a deliberately hostile adapter's independent tools.

## Freshness and build

`freshness` checks a clean target checkout containing the baseline commit, compares its pinned HEAD tree to the original tree, and returns `unchanged` or `needs-review`. Every change needs review; cited, dependent, watched, configuration, added, deleted and otherwise unknown-impact paths are labelled. No change is silently declared irrelevant; no command advances the baseline. Original source must stay at the pin: use a separate clean checkout/worktree as the target when comparing a later revision. Reports are recorded as receipts and returned as JSON; `needs-review` is a successful comparison, not an error.

`build` generates owned Markdown under `docs/`, a Material-theme `mkdocs.yml`, and `site/`; calls the supplied existing MkDocs executable with `build --strict`; validates the complete staging tree for symlinks, hardlinks and nonregular entries before reading/serving/copying rendered content; requires the rendered index, inventory and every accepted answer page; then checks local HTML links/assets and serves a temporary loopback HTTP smoke endpoint. Required rendered pages remain mandatory on verification/resume. A deterministic staging refusal leaves the registry usable. It records a successful build only after those checks and a final source check. It does not deploy or leave a server running. Generated pages separate mechanical reference, code claims, attributed human intent and unknowns. Existing source documentation and HUMAN blocks are never edited. Editing an owned generated file, including inserting a HUMAN block, makes subsequent commands refuse rather than overwrite it. Keep a real handbook outside the managed output.

Successful commands print a JSON result to stdout and return 0. Operational refusals print JSON to stderr and return 2; argparse usage errors use its standard error text. Operational evidence and raw requests/answers stay outside the public DeepDocs repository. A successful verify means artifact/schema/span integrity at the pinned source, **not** exhaustive coverage, semantic correctness, deployment validation or an audited/complete codebase.

Keep runs bounded: JSON inputs/artifacts and each supporting source file are limited to 2,000,000 bytes; runner stdout plus stderr is capped at the same size. Each array has at most 1,000 items and ordinary prose strings at most 20,000 characters. Source files must be UTF-8 for citation, while hashes preserve their original bytes. Generated sites freeze their request/answer set: finish questions before `build`, or start a fresh output for a changed set. Hashes and same-directory atomic file replacement fail closed on an interrupted multi-file update; there is no automatic repair or silent adoption of partial material. A hard-killed CLI leaves its full durable budget reservation; it cannot guarantee termination of an already detached adapter after the supervisor itself has been killed.

## Verification

```bash
python3 tests/test-grounded.py
```

The tests use disposable real Git repositories and explicitly labelled fixture answers. They do not measure model quality or certify Buzz. Full real-source acceptance and independent semantic review are separate gates.
