#!/usr/bin/env python3
"""Offline, full-CLI regressions for the five DeepDocs update blockers.

Run: python3 tests/test-update-cli.py
Override the implementation with DEEPDOCS_SCRIPT=/absolute/path/orchestrate.sh.

Only disposable Git repositories receive commits. The real Bash CLI, Git,
parsers, lifecycle gates and persisted files are exercised, without sourcing
helpers or enabling DEEP_DOCS_TEST_MODE. All agent outputs are explicitly
synthetic TEST DOUBLES, not model responses or documentation-quality evidence.
The fake mkdocs executable proves strict-build invocation/exit handling ONLY;
it does not prove that a real MkDocs site builds. No network or real agents.
"""

import json
import os
import fcntl
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("DEEPDOCS_SCRIPT", ROOT / "scripts/orchestrate.sh")).resolve()
INVENTORY_HEADER = (
    "# TEST DOUBLE component inventory\n\n"
    "| # | Component | Slug | Path | Source Files | Language | Purpose | Key Files | Dependencies |\n"
    "|---|-----------|------|------|--------------|----------|---------|-----------|--------------|\n"
)
GROUP_HEADER = (
    "# TEST DOUBLE component groups\n\n"
    "| # | Group | Slug | Path Prefix | Components | Purpose |\n"
    "|---|-------|------|-------------|------------|---------|\n"
)
ALL_STANDALONE = "No component groups detected — all components are standalone.\n"
REQUIRED_SYSTEM = (
    "L1/executive-summary.md", "L2/overview.md", "L4/OVERVIEW.md",
    "diagrams/INDEX.md", "index.md",
)

# Executed only inside each disposable fixture's private PATH. Unknown calls
# fail, rather than accidentally falling through to an installed real agent.
TEST_DOUBLE = r'''
import json, os, pathlib, re, subprocess, sys, time
D = pathlib.Path(os.environ["DD_TEST_DOCS"])
S = D / "builder/.scratch"
mode = os.environ["DD_TEST_MODE"]

def write(p, content):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(content, encoding="utf-8")

def record(kind, **fields):
    with open(os.environ["DD_TEST_CALLS"], "a", encoding="utf-8") as f:
        f.write(json.dumps(dict(kind=kind, **fields)) + "\n")

def package():
    write(D / "index.md", "# TEST DOUBLE packaged landing page\n")
    pages = sorted(p.relative_to(D).as_posix() for p in D.rglob("*.md")
                   if p.relative_to(D).parts[0] not in ("builder", "site", "docs"))
    write(D / "mkdocs.yml", "# TEST DOUBLE configuration\nsite_name: Fixture\nnav:\n" +
          "".join("  - Page: " + p + "\n" for p in pages))
    write(S / "package-complete.md", "TEST DOUBLE package receipt\nPACKAGE_COMPLETE\n")

if pathlib.Path(sys.argv[0]).name == "mkdocs":
    record("mkdocs", args=sys.argv[1:])
    if sys.argv[1:] != ["build", "--strict"]:
        sys.exit(97)
    if os.environ.get("DD_TEST_BUILD_FAIL") == "1":
        print("TEST DOUBLE strict-build failure", file=sys.stderr)
        sys.exit(73)
    write(D / "site/index.html", "<!-- TEST DOUBLE, NOT a real MkDocs build -->\n")
    sys.exit(0)

args = sys.argv[1:]
if args == ["chat", "--help"]:
    print("TEST DOUBLE Hermes chat --model --query --quiet --provider")
    sys.exit(0)
if not args or args[0] != "chat" or "--model" not in args or "--query" not in args or "--quiet" not in args:
    record("unexpected", args=args)
    sys.exit(98)
label = os.environ["DEEP_DOCS_AGENT_LABEL"]
task = args[args.index("--query") + 1]
record("agent", label=label, model=args[args.index("--model") + 1],
       provider=args[args.index("--provider") + 1] if "--provider" in args else None)
reservation = json.loads((S / "agent-budget.json").read_text())["attempts"][-1]
if reservation["status"] != "running" or reservation["label"] != label or reservation["requested_model"] != args[args.index("--model") + 1]:
    record("unreserved-invocation")
    sys.exit(80)

if label.startswith("history-"):
    fail_stage = os.environ.get("DD_TEST_HISTORY_FAIL_STAGE")
    missing_stage = os.environ.get("DD_TEST_HISTORY_MISSING_STAGE")
    if missing_stage == label:
        sys.exit(0)
    if label == "history-harvest":
        write(S / "history-harvest.md", "# TEST DOUBLE harvest\n")
    elif label == "history-epochs":
        write(S / "history-epochs.md", "## Epoch 1: TEST DOUBLE (2026-01-01)\n")
    elif label == "history-comprehend-epoch-01":
        write(S / "history-epoch-01.md", "# TEST DOUBLE epoch notes\n")
    elif label == "history-write":
        write(D / "CHANGELOG.md", "# TEST DOUBLE history changelog\n")
        write(S / "history-write-complete.md", "HISTORY_WRITE_COMPLETE\n")
    elif label.startswith("history-review-"):
        outcome = {
            "history-malformed": "REVIEW_CLEAN maybe",
            "history-nonterminal": "REVIEW_CLEAN\nStill working",
            "history-unresolved": "REVIEW_ISSUES: 1 unresolved",
            "history-contradictory": "REVIEW_ISSUES: 1 unresolved\nREVIEW_CLEAN",
        }.get(mode, "REVIEW_CLEAN")
        if mode != "history-stale":
            write(S / (label + ".md"), "# TEST DOUBLE history review\n" + outcome + "\n")
        if mode == "history-failed-clean":
            sys.exit(72)
        if mode == "history-dirties-source":
            write(pathlib.Path(os.environ["DD_TEST_SOURCE"]) / "packages/alpha/main.py", "# TEST DOUBLE mutation\n")
    else:
        record("unexpected", label=label)
        sys.exit(99)
    if fail_stage == label:
        sys.exit(72)
elif label in ("discover", "synthesise", "diagram", "write-l2-overview", "write-l4-overview", "write-l1") and mode == "review-contract-all":
    if label == "synthesise":
        write(S / "synthesise-01-integration.md", "# TEST DOUBLE synthesis\n")
    elif label == "diagram":
        write(D / "diagrams/INDEX.md", "# TEST DOUBLE diagram\n")
elif label.startswith("update-inventory-"):
    if mode == "candidate-slugs":
        p = D / "builder/specs/component-inventory.md"
        write(p, p.read_text().replace("`alpha`", "`candidate-alpha`").replace("`gamma`", "`candidate-gamma`"))
        p = D / "builder/specs/component-groups.md"
        write(p, p.read_text().replace("`alpha, beta`", "`candidate-alpha, beta`").replace("`gamma`", "`candidate-gamma`"))
    if mode == "root-then-fail-diff":
        p = D / "builder/specs/component-inventory.md"
        write(p, p.read_text() + "| 2 | Root Package | `agent-root` | `.` | 1 | Python | root metadata | pyproject.toml | none |\n")
        p = D / "builder/specs/component-groups.md"
        write(p, "| # | Group | Slug | Path Prefix | Components | Purpose |\n|---|-------|------|-------------|------------|---------|\n"
              "\n## Standalone Components\n| Component | Path | Reason |\n|-----------|------|--------|\n"
              "| alpha | packages/alpha | independent |\n| agent-root | . | root |\n")
    if mode.startswith("remove") or mode == "refresh-then-fail-diff":
        p = D / "builder/specs/component-inventory.md"
        write(p, "\n".join(line for line in p.read_text().splitlines()
                             if "`beta`" not in line) + "\n")
        p = D / "builder/specs/component-groups.md"
        if p.exists():
            write(p, p.read_text().replace("`alpha, beta`", "`alpha`"))
    write(S / "inventory-refresh-complete.md", "TEST DOUBLE\nINVENTORY_REFRESH_COMPLETE\n")
elif label == "diff-discovery":
    if mode == "require-diff-classification-contract":
        required = (
            "STRUCTURAL is reserved for component Path changes recorded in inventory-delta.md.",
            "File moves between components whose Path values are unchanged are MODIFIED",
            "Do not introduce NEW, REMOVED or STRUCTURAL rows absent from inventory-delta.md.",
        )
        if not all(rule in task for rule in required):
            record("missing-diff-classification-contract")
            sys.exit(77)
    if mode == "require-diff-source":
        source = os.environ["DD_TEST_SOURCE"]
        target = os.environ["DD_TEST_SOURCE_HEAD"]
        base = (D / "builder/last-run.md").read_text().split("commit: ", 1)[1].splitlines()[0]
        if source not in task or (base + ".." + target) not in task:
            record("missing-diff-context")
            sys.exit(76)
    if mode in ("fail-diff", "refresh-then-fail-diff", "root-then-fail-diff"):
        # Deliberately do not rewrite any inherited diff report.
        sys.exit(71)
    if mode.startswith("remove"):
        write(S / "update-diff.md", "# TEST DOUBLE diff\n\n## Affected Components\n"
              "| Slug | Classification | What Changed |\n"
              "|------|----------------|--------------|\n"
              "| beta | REMOVED | removed packages/beta |\n")
    elif mode == "empty-scope":
        write(S / "update-diff.md", "# TEST DOUBLE empty affected scope\n"
              "## Affected Components\n| Slug | Classification | What Changed |\n"
              "|------|----------------|--------------|\n")
    else:
        write(S / "update-diff.md", "NO_CHANGES_DETECTED\n")
elif label == "update-synthesise":
    for name in ("01-integration", "02-flows", "03-architecture"):
        write(S / ("synthesise-" + name + ".md"), "# TEST DOUBLE synthesis\n")
elif label == "update-diagram":
    write(D / "diagrams/INDEX.md", "# TEST DOUBLE diagram index\n")
elif label in ("update-l2-overview", "update-l4-overview", "update-l1"):
    target = {"update-l2-overview": "L2/overview.md",
              "update-l4-overview": "L4/OVERVIEW.md",
              "update-l1": "L1/executive-summary.md"}[label]
    write(D / target, "# TEST DOUBLE updated system document\n")
elif label == "changelog":
    write(D / "CHANGELOG.md", "# TEST DOUBLE changelog\n\nRemoved Beta.\n")
    write(S / "changelog-complete.md", "TEST DOUBLE\nCHANGELOG_COMPLETE\n")
elif mode.startswith("review-contract") and label.startswith("review-") and "-attempt-" in label:
    required = (
        "Source repository (absolute, read-only): " + os.environ["DD_TEST_SOURCE"],
        "Follow specific imports, referenced schemas, root configuration and relevant consumer/infrastructure wiring",
        "Read permissions are repository-wide; documentation writes remain component-scoped.",
        "A marker alone never resolves an unsupported material claim.",
        "Material unsupported HUMAN claims remain unresolved",
        "Lack of runtime execution or an optional automated check is not itself a documentation error",
    )
    if not all(rule in task for rule in required):
        record("missing-review-contract")
        sys.exit(78)
    slug = label.removeprefix("review-").split("-attempt-", 1)[0]
    outcome = "COMPONENT_ISSUES: 1 unresolved" if mode == "review-contract-unresolved" or (mode == "review-contract-partial" and slug == "beta") else "COMPONENT_CLEAN"
    if mode == "review-contract-requires-findings":
        previous = S / ("review-" + slug + ".previous.md")
        if str(previous) not in task or "COMPONENT_ISSUES: 1 unresolved" not in previous.read_text():
            record("missing-previous-findings")
            sys.exit(79)
    write(S / ("review-" + slug + ".md"), "# TEST DOUBLE review contract\n" + outcome + "\n")
    if mode == "review-contract-dirties-source":
        write(pathlib.Path(os.environ["DD_TEST_SOURCE"]) / "packages/alpha/main.py", "# TEST DOUBLE source mutation\n")
    if mode == "review-contract-failed-clean":
        sys.exit(72)
    if mode == "review-contract-timeout-clean":
        subprocess.Popen([sys.executable, "-c", "import pathlib,sys,time; time.sleep(0.7); pathlib.Path(sys.argv[1]).write_text('ORPHAN TEST DOUBLE')", str(S / "orphan-wrote.md")])
        time.sleep(30)
    if mode == "review-contract-kill-supervisor":
        os.kill(os.getppid(), 9)
        sys.exit(0)
elif "REVIEW_AGGREGATE_COMPLETE" in task and str(D / "REVIEW.md") in task:
    record("aggregate-review")
    write(D / "REVIEW.md", "# TEST DOUBLE aggregate\n\nSystem removal review only; no component reviews.\n")
    write(S / "review-aggregate-complete.md", "TEST DOUBLE\nREVIEW_AGGREGATE_COMPLETE\n")
elif str(S / "review-system.md") in task and "SYSTEM_REVIEW_CLEAN" in task:
    record("system-review", label=label)
    body = "# TEST DOUBLE system removal review\n\n"
    if mode == "remove-malformed-review":
        body += "No terminal protocol marker.\n"
    elif mode == "remove-issues-review":
        body += "SYSTEM_REVIEW_ISSUES: 1 unresolved\n"
    else:
        body += "SYSTEM_REVIEW_CLEAN\n"
    write(S / "review-system.md", body)
    print("SYSTEM_REVIEW_CLEAN")  # stdout must not replace artifact validation.
    if mode == "remove-failed-review":
        sys.exit(72)  # Even a clean artifact must not rescue a failed invocation.
elif label == "package":
    package()
else:
    record("unexpected", label=label)
    print("UNEXPECTED TEST DOUBLE invocation: " + label, file=sys.stderr)
    sys.exit(99)
'''


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def inventory(slugs):
    return INVENTORY_HEADER + "".join(
        f"| {i} | {slug.title()} | `{slug}` | `packages/{slug}` | 1 | Python | "
        f"TEST DOUBLE {slug} baseline metadata | main.py | none |\n"
        for i, slug in enumerate(slugs, 1)
    )


def group_row(members="alpha, beta", slug="shared", number=1):
    return f"| {number} | Shared | `{slug}` | `packages` | `{members}` | TEST DOUBLE group metadata |\n"


def standalone_rows(slugs, heading="Singleton Modules"):
    return f"\n## {heading}\n\n| Component | Path | Reason |\n|-----------|------|--------|\n" + "".join(
        f"| `{slug}` | `packages/{slug}` | TEST DOUBLE independent module |\n"
        for slug in slugs
    )


class Fixture:
    """Disposable real Git history and synthetic docs/CLI dependencies."""

    def __init__(self, case, slugs=("alpha",), groups=None):
        self.case = case
        self.temp = tempfile.TemporaryDirectory(prefix="deepdocs-cli-")
        case.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.docs = self.root / "docs"
        self.scratch = self.docs / "builder/.scratch"
        self.source.mkdir()
        self.scratch.mkdir(parents=True)
        self.bin = self.root / "bin"
        self.calls_file = self.root / "calls.jsonl"
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.root / "home"), "TMPDIR": str(self.root),
            "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_AUTHOR_NAME": "DeepDocs TEST DOUBLE",
            "GIT_COMMITTER_NAME": "DeepDocs TEST DOUBLE",
            "GIT_AUTHOR_EMAIL": "test-double@example.invalid",
            "GIT_COMMITTER_EMAIL": "test-double@example.invalid",
            "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
            "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
            "DD_TEST_DOCS": str(self.docs), "DD_TEST_CALLS": str(self.calls_file),
            "DEEP_DOCS_AGENT_ADAPTER": "hermes",
            "DEEP_DOCS_ECONOMY_MODEL": "test-double/economy",
        }
        (self.root / "home").mkdir()
        for name in ("hermes", "openclaw", "mkdocs"):
            target = self.bin / name
            write(target, f"#!{sys.executable}\n# Offline TEST DOUBLE, not a real {name} CLI.\n" + TEST_DOUBLE)
            target.chmod(0o755)
        self.git("init", "-q")
        self.git("config", "core.hooksPath", os.devnull)
        self.git("config", "commit.gpgSign", "false")
        for slug in slugs:
            write(self.source / f"packages/{slug}/main.py", f"# TEST DOUBLE source: {slug}\nVALUE = 1\n")
        # Ensure the standalone empty-inventory negative control still has a commit.
        write(self.source / "README.md", "# Disposable TEST DOUBLE source repository\n")
        self.base = self.commit("TEST DOUBLE baseline")
        self.last_run = self.docs / "builder/last-run.md"
        write(self.last_run, f"date: 2026-01-01T00:00:00Z\ncommit: {self.base}\nmode: update\n")
        self.baseline_bytes = self.last_run.read_bytes()
        write(self.docs / "builder/specs/component-inventory.md", inventory(slugs))
        if groups is not None:
            write(self.docs / "builder/specs/component-groups.md", groups)
        for slug in slugs:
            for tier in ("L2", "L3", "L4"):
                write(self.docs / tier / f"{slug}.md", f"# TEST DOUBLE inherited {tier} {slug}\n")
        for relative in REQUIRED_SYSTEM:
            write(self.docs / relative, f"# TEST DOUBLE inherited {relative}\n")
        for slug in re.findall(r"^\| \d+ \| [^|]+ \| `([^`]+)`", groups or "", re.M):
            write(self.docs / f"L2/groups/{slug}.md", f"# TEST DOUBLE group {slug}\n")
        self.write_nav()
        self.last_output = ""

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.source), *args], env=self.env,
            text=True, stderr=subprocess.PIPE, timeout=3,
        ).strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-qm", message)
        return self.git("rev-parse", "HEAD")

    def remove_beta(self):
        shutil.rmtree(self.source / "packages/beta")
        return self.commit("TEST DOUBLE remove Beta")

    def write_nav(self):
        pages = sorted(p.relative_to(self.docs).as_posix() for p in self.docs.rglob("*.md")
                       if p.relative_to(self.docs).parts[0] not in ("builder", "site", "docs"))
        write(self.docs / "mkdocs.yml", "# TEST DOUBLE configuration\nsite_name: Fixture\nnav:\n" +
              "".join(f"  - Page: {p}\n" for p in pages))

    def run(self, mode="no-change", *, phase="update", build_fail=False, assert_clean=True):
        self.calls_file.unlink(missing_ok=True)
        before_head = self.git("rev-parse", "HEAD")
        result = subprocess.run(
            ["bash", str(SCRIPT), phase, str(self.source), str(self.docs), "test-double/no-real-model"],
            cwd=self.root, env=dict(self.env, DD_TEST_MODE=mode, DD_TEST_BUILD_FAIL=str(int(build_fail)),
                                    DD_TEST_SOURCE=str(self.source), DD_TEST_SOURCE_HEAD=before_head),
            text=True, capture_output=True, timeout=5,
        )
        self.last_output = result.stdout + result.stderr
        self.case.assertEqual(self.git("rev-parse", "HEAD"), before_head, self.last_output)
        if assert_clean:
            self.case.assertEqual(self.git("status", "--porcelain"), "", self.last_output)
        self.case.assertFalse(self.events("unexpected"), self.last_output + repr(self.calls()))
        self.case.assertFalse(self.events("unreserved-invocation"), self.last_output)
        return result.returncode

    def calls(self):
        return [json.loads(line) for line in self.calls_file.read_text().splitlines()] if self.calls_file.exists() else []

    def events(self, kind):
        return [call for call in self.calls() if call["kind"] == kind]

    def labels(self):
        return [call["label"] for call in self.events("agent")]

    def assert_baseline_unchanged(self):
        self.case.assertEqual(self.last_run.read_bytes(), self.baseline_bytes, self.last_output)

    def assert_built(self):
        self.case.assertTrue(self.events("mkdocs"), "Strict-build gate was bypassed.\n" + self.last_output)
        self.case.assertTrue(all(call["args"] == ["build", "--strict"] for call in self.events("mkdocs")))


class UpdateCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not SCRIPT.is_file():
            raise RuntimeError(f"DEEPDOCS_SCRIPT is not a file: {SCRIPT}")
        for command in ("bash", "git"):
            if not shutil.which(command):
                raise RuntimeError(f"Required local dependency missing: {command}")

    def test_review_prompt_allows_targeted_dependency_reads_without_waiving_material_errors(self):
        f = Fixture(self)
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertFalse(f.events("missing-review-contract"))
        self.assertTrue((f.scratch / "review-alpha.fingerprint").is_file())
        f.assert_baseline_unchanged()

    def test_history_success_requires_fresh_stages_and_preserves_baseline(self):
        f = Fixture(self)
        write(f.scratch / "history-epoch-99.md", "STALE EPOCH\n")
        self.assertEqual(f.run("history-clean", phase="history"), 0, f.last_output)
        self.assertEqual(f.labels(), ["history-harvest", "history-epochs", "history-comprehend-epoch-01",
                                      "history-write", "history-review-1"])
        self.assertFalse((f.scratch / "history-epoch-99.md").exists())
        self.assertIn("COMPLETE — deep-docs history finished", f.last_output)
        self.assertEqual((f.scratch / "history-review-1.md").read_text().splitlines()[-1], "REVIEW_CLEAN")
        f.assert_baseline_unchanged()

    def test_history_failed_reviewer_cannot_certify_clean_marker(self):
        f = Fixture(self)
        self.assertNotEqual(f.run("history-failed-clean", phase="history"), 0, f.last_output)
        self.assertEqual(f.labels()[-1], "history-review-1")
        attempts = json.loads((f.scratch / "agent-budget.json").read_text())["attempts"]
        self.assertEqual(attempts[-1]["returncode"], 72)
        self.assertFalse((f.scratch / "history-review-1.md").exists())
        self.assertNotIn("COMPLETE — deep-docs history finished", f.last_output)
        f.assert_baseline_unchanged()

    def test_history_budget_denied_before_review_is_not_success(self):
        f = Fixture(self)
        f.env["DEEP_DOCS_MAX_INVOCATIONS"] = "4"
        write(f.scratch / "history-review-1.md", "REVIEW_CLEAN\n")
        self.assertNotEqual(f.run("history-clean", phase="history"), 0, f.last_output)
        self.assertEqual(len(f.labels()), 4)
        self.assertIn("budget exhausted", f.last_output)
        self.assertFalse(list(f.scratch.glob("history-review-*.md")))
        self.assertNotIn("COMPLETE — deep-docs history finished", f.last_output)
        f.assert_baseline_unchanged()

    def test_history_stale_malformed_nonterminal_and_unresolved_fail(self):
        for mode in ("history-stale", "history-malformed", "history-nonterminal", "history-unresolved", "history-contradictory"):
            with self.subTest(mode=mode):
                f = Fixture(self)
                for iteration in range(1, 4):
                    write(f.scratch / f"history-review-{iteration}.md", "REVIEW_CLEAN\n")
                self.assertNotEqual(f.run(mode, phase="history"), 0, f.last_output)
                self.assertEqual(f.labels()[-3:], ["history-review-1", "history-review-2", "history-review-3"])
                self.assertNotIn("COMPLETE — deep-docs history finished", f.last_output)
                if mode == "history-stale":
                    self.assertFalse(list(f.scratch.glob("history-review-*.md")))
                f.assert_baseline_unchanged()

    def test_history_mandatory_stage_failures_and_missing_outputs_stop_main(self):
        stages = ["history-harvest", "history-epochs", "history-comprehend-epoch-01", "history-write"]
        for key in ("DD_TEST_HISTORY_FAIL_STAGE", "DD_TEST_HISTORY_MISSING_STAGE"):
            for index, stage in enumerate(stages):
                with self.subTest(key=key, stage=stage):
                    f = Fixture(self)
                    for name in ("history-harvest.md", "history-epochs.md", "history-epoch-01.md", "history-write-complete.md"):
                        write(f.scratch / name, "STALE TEST DOUBLE\n")
                    write(f.docs / "CHANGELOG.md", "# Existing changelog must not certify a no-op\n")
                    f.env[key] = stage
                    self.assertNotEqual(f.run("history-clean", phase="history"), 0, f.last_output)
                    self.assertEqual(f.labels(), stages[:index + 1])
                    self.assertNotIn("COMPLETE — deep-docs history finished", f.last_output)
                    f.assert_baseline_unchanged()

    def test_history_dirty_or_reviewer_mutated_source_fails_closed(self):
        f = Fixture(self)
        write(f.source / "packages/alpha/main.py", "# TEST DOUBLE dirty source\n")
        self.assertNotEqual(f.run("history-clean", phase="history", assert_clean=False), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        f.assert_baseline_unchanged()
        f = Fixture(self)
        self.assertNotEqual(f.run("history-dirties-source", phase="history", assert_clean=False), 0, f.last_output)
        self.assertEqual(f.labels()[-1], "history-review-1")
        self.assertFalse((f.scratch / "history-review-1.md").exists())
        self.assertIn("tracked changes", f.last_output)
        f.assert_baseline_unchanged()

    def test_initial_all_diagram_uses_economy_or_explicit_quality_fallback(self):
        for economy, expected in (("test-double/economy", "test-double/economy"), ("", "test-double/no-real-model")):
            with self.subTest(economy=economy):
                f = Fixture(self)
                f.env["DEEP_DOCS_ECONOMY_MODEL"] = economy
                write(f.scratch / "comprehend-alpha-summary.md", "# TEST DOUBLE existing summary\n")
                self.assertEqual(f.run("review-contract-all", phase="all"), 0, f.last_output)
                diagrams = [call for call in f.events("agent") if call["label"] == "diagram"]
                self.assertEqual(len(diagrams), 1)
                self.assertEqual(diagrams[0]["model"], expected)
                f.assert_built()

    def test_review_material_uncertainty_still_blocks_completion(self):
        f = Fixture(self)
        self.assertNotEqual(f.run("review-contract-unresolved", phase="review"), 0, f.last_output)
        self.assertFalse(f.events("missing-review-contract"))
        self.assertFalse((f.scratch / "review-alpha.fingerprint").exists())
        self.assertIn("COMPONENT_ISSUES: 1 unresolved", (f.scratch / "review-alpha.md").read_text())
        f.assert_baseline_unchanged()

    def test_failed_reviewer_cannot_certify_its_clean_marker(self):
        f = Fixture(self)
        f.env["DEEP_DOCS_REVIEW_MAX_ITERATIONS"] = "1"
        self.assertNotEqual(f.run("review-contract-failed-clean", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-alpha-attempt-1", "review-alpha-attempt-2"])
        self.assertFalse((f.scratch / "review-alpha.fingerprint").exists())
        self.assertFalse((f.scratch / "review-alpha.md").exists())
        attempts = json.loads((f.scratch / "agent-budget.json").read_text())["attempts"]
        self.assertEqual([row["returncode"] for row in attempts], [72, 72])
        f.assert_baseline_unchanged()

    def test_standalone_resume_reuses_successes_and_invalidates_only_changed_docs(self):
        f = Fixture(self, ("alpha", "beta"))
        human = "# TEST DOUBLE\n<!-- HUMAN -->\nKeep this exact sentence.\n<!-- /HUMAN -->\n"
        write(f.docs / "L2/alpha.md", human)
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        review = (f.scratch / "review-alpha.md").read_bytes()
        state = (f.scratch / "review-run-state").read_bytes()
        budget = (f.scratch / "agent-budget.json").read_bytes()
        self.assertEqual(f.run("review-contract-failed-clean", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        self.assertEqual((f.scratch / "review-alpha.md").read_bytes(), review)
        self.assertEqual((f.scratch / "review-run-state").read_bytes(), state)
        self.assertEqual((f.scratch / "agent-budget.json").read_bytes(), budget)
        self.assertEqual((f.docs / "L2/alpha.md").read_text(), human)
        write(f.docs / "L3/beta.md", "# TEST DOUBLE changed Beta docs\n")
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-beta-attempt-1", "review-aggregate"])
        self.assertEqual((f.scratch / "review-alpha.md").read_bytes(), review)
        # Same inventory, different source must not inherit either clean result.
        write(f.source / "README.md", "# TEST DOUBLE new source pin\n")
        f.commit("TEST DOUBLE source change")
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-alpha-attempt-1", "review-beta-attempt-1", "review-aggregate"])
        f.assert_baseline_unchanged()

    def test_standalone_dirty_source_cannot_reuse_clean_result(self):
        f = Fixture(self)
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        write(f.source / "packages/alpha/main.py", "# TEST DOUBLE dirty source\n")
        self.assertNotEqual(f.run("review-contract", phase="review", assert_clean=False), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        self.assertIn("tracked changes", f.last_output)
        f.assert_baseline_unchanged()

    def test_partial_resume_targets_findings_and_preserves_success(self):
        f = Fixture(self, ("alpha", "beta"))
        f.env["DEEP_DOCS_REVIEW_MAX_ITERATIONS"] = "1"
        self.assertNotEqual(f.run("review-contract-partial", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-alpha-attempt-1", "review-beta-attempt-1"])
        saved = (f.scratch / "review-alpha.md").read_bytes()
        f.env["DEEP_DOCS_REVIEW_SLUGS"] = "beta"
        self.assertEqual(f.run("review-contract-requires-findings", phase="review"), 0, f.last_output)
        self.assertFalse(f.events("missing-previous-findings"))
        self.assertEqual(f.labels(), ["review-beta-attempt-1", "review-aggregate"])
        self.assertEqual((f.scratch / "review-alpha.md").read_bytes(), saved)
        self.assertEqual(f.events("agent")[0]["model"], "test-double/no-real-model")
        f.assert_baseline_unchanged()

    def test_reviewer_source_mutation_cannot_acquire_clean_fingerprint(self):
        f = Fixture(self)
        self.assertNotEqual(f.run("review-contract-dirties-source", phase="review", assert_clean=False), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-alpha-attempt-1"])
        self.assertFalse((f.scratch / "review-alpha.fingerprint").exists())
        self.assertFalse((f.scratch / "review-alpha.md").exists())
        self.assertIn("tracked changes", f.last_output)
        f.assert_baseline_unchanged()

    def test_concurrent_cli_cannot_invalidate_owned_review_state(self):
        f = Fixture(self)
        write(f.scratch / "review-run-state", "TEST DOUBLE active owner\n")
        with (f.scratch / "legacy-run.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        self.assertEqual((f.scratch / "review-run-state").read_text(), "TEST DOUBLE active owner\n")
        self.assertIn("Another legacy run", f.last_output)

    def test_focused_selection_never_shrinks_acceptance_scope(self):
        f = Fixture(self, ("alpha", "beta"))
        f.env.update(DEEP_DOCS_REVIEW_SLUGS="alpha", DEEP_DOCS_REVIEW_MAX_ITERATIONS="1")
        self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-alpha-attempt-1"])
        self.assertEqual(len((f.scratch / "review-scope.psv").read_text().splitlines()), 2)
        for selector in ("ghost", "alpha,", "alpha, beta"):
            f.env["DEEP_DOCS_REVIEW_SLUGS"] = selector
            self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
            self.assertEqual(f.labels(), [])
        f.env["DEEP_DOCS_REVIEW_SLUGS"] = "beta"
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-beta-attempt-1", "review-aggregate"])
        f.assert_baseline_unchanged()

    def test_invocation_budget_survives_failures_restarts_and_phase_changes(self):
        f = Fixture(self)
        f.env["DEEP_DOCS_MAX_INVOCATIONS"] = "2"
        self.assertNotEqual(f.run("review-contract-failed-clean", phase="review"), 0, f.last_output)
        self.assertEqual(len(f.labels()), 2)
        before = (f.scratch / "agent-budget.json").read_bytes()
        f.env.pop("DEEP_DOCS_MAX_INVOCATIONS")  # A new shell cannot restore the larger default.
        self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        self.assertEqual((f.scratch / "agent-budget.json").read_bytes(), before)
        self.assertIn("budget exhausted", f.last_output)
        # Explicitly raising the ceiling retains failed calls, not a fresh allowance.
        f.env["DEEP_DOCS_MAX_INVOCATIONS"] = "4"
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        attempts = json.loads((f.scratch / "agent-budget.json").read_text())["attempts"]
        self.assertEqual(len(attempts), 4)
        self.assertEqual([row["returncode"] for row in attempts], [72, 72, 0, 0])
        self.assertTrue(all(row["elapsed_seconds"] > 0 for row in attempts))
        f.env.pop("DEEP_DOCS_MAX_INVOCATIONS")
        self.assertNotEqual(f.run(phase="package"), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        f.assert_baseline_unchanged()

    def test_durable_time_budget_kills_clean_marker_process_and_blocks_restart(self):
        f = Fixture(self)
        f.env["DEEP_DOCS_MAX_AGENT_SECONDS"] = "0.3"
        self.assertNotEqual(f.run("review-contract-timeout-clean", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-alpha-attempt-1"])
        self.assertIn("hard invocation timeout", f.last_output)
        self.assertFalse((f.scratch / "review-alpha.fingerprint").exists())
        self.assertFalse((f.scratch / "review-alpha.md").exists())
        ledger = f.scratch / "agent-budget.json"
        attempts = json.loads(ledger.read_text())["attempts"]
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["returncode"], 124)
        self.assertGreaterEqual(attempts[0]["charged_seconds"], 0.3)
        before = ledger.read_bytes()
        f.env.pop("DEEP_DOCS_MAX_AGENT_SECONDS")
        self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        self.assertEqual(ledger.read_bytes(), before)
        f.assert_baseline_unchanged()

    def test_killed_supervisor_retains_reservation_and_blocks_replay(self):
        f = Fixture(self)
        self.assertNotEqual(f.run("review-contract-kill-supervisor", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), ["review-alpha-attempt-1"])
        ledger = f.scratch / "agent-budget.json"
        attempts = json.loads(ledger.read_text())["attempts"]
        self.assertEqual(len(attempts), 1)
        self.assertEqual(attempts[0]["status"], "running")
        self.assertGreater(attempts[0]["charged_seconds"], 0)
        self.assertFalse((f.scratch / "review-alpha.fingerprint").exists())
        self.assertFalse((f.scratch / "review-alpha.md").exists())
        before = ledger.read_bytes()
        self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        self.assertEqual(ledger.read_bytes(), before)
        self.assertIn("unreconciled interrupted invocation", f.last_output)

    def test_time_budget_accumulates_and_caps_retries_and_descendants(self):
        f = Fixture(self)
        f.env.update(DEEP_DOCS_MAX_AGENT_SECONDS="0.5", DEEP_DOCS_AGENT_TIMEOUT_SECONDS="0.3")
        self.assertNotEqual(f.run("review-contract-timeout-clean", phase="review"), 0, f.last_output)
        attempts = json.loads((f.scratch / "agent-budget.json").read_text())["attempts"]
        self.assertEqual(len(attempts), 2)
        self.assertEqual([row["returncode"] for row in attempts], [124, 124])
        self.assertLess(attempts[1]["reserved_seconds"], attempts[0]["reserved_seconds"])
        self.assertGreaterEqual(sum(row["charged_seconds"] for row in attempts), 0.5)
        time.sleep(0.8)
        self.assertFalse((f.scratch / "orphan-wrote.md").exists())
        self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        f.assert_baseline_unchanged()

    def test_invalid_budget_configuration_or_ledger_fails_closed(self):
        for key, value in (("DEEP_DOCS_MAX_INVOCATIONS", "0"), ("DEEP_DOCS_MAX_INVOCATIONS", "1.5"),
                           ("DEEP_DOCS_MAX_AGENT_SECONDS", "nan"), ("DEEP_DOCS_MAX_AGENT_SECONDS", "inf"),
                           ("DEEP_DOCS_AGENT_TIMEOUT_SECONDS", "-1")):
            with self.subTest(key=key, value=value):
                f = Fixture(self)
                f.env[key] = value
                self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
                self.assertEqual(f.labels(), [])
        f = Fixture(self)
        write(f.scratch / "agent-budget.json", "{broken TEST DOUBLE journal")
        self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual(f.labels(), [])
        self.assertIn("refusing to reset", f.last_output)

    def test_models_and_provider_reach_the_supported_adapter(self):
        f = Fixture(self)
        f.env["DEEP_DOCS_HERMES_PROVIDER"] = "test-double-provider"
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual([call["model"] for call in f.events("agent")],
                         ["test-double/economy", "test-double/no-real-model"])
        self.assertTrue(all(call["provider"] == "test-double-provider" for call in f.events("agent")))
        attempts = json.loads((f.scratch / "agent-budget.json").read_text())["attempts"]
        self.assertEqual([row["requested_model"] for row in attempts],
                         [call["model"] for call in f.events("agent")])
        self.assertTrue(all(row["actual_model"] is None for row in attempts))
        f = Fixture(self)
        f.env["DEEP_DOCS_ECONOMY_MODEL"] = ""
        self.assertEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertEqual([call["model"] for call in f.events("agent")], ["test-double/no-real-model"] * 2)

    def test_unsupported_openclaw_or_missing_hermes_interface_fails_before_dispatch(self):
        f = Fixture(self)
        f.env.pop("DEEP_DOCS_AGENT_ADAPTER")
        self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertIn("cannot enforce requested per-call models", f.last_output)
        self.assertEqual(f.calls(), [])
        self.assertFalse((f.scratch / "agent-budget.json").exists())
        f.env["DEEP_DOCS_AGENT_ADAPTER"] = "hermes"
        write(f.bin / "hermes", "#!/bin/sh\nprintf 'TEST DOUBLE obsolete interface\\n'\n")
        self.assertNotEqual(f.run("review-contract", phase="review"), 0, f.last_output)
        self.assertIn("lacks the required", f.last_output)
        self.assertEqual(f.calls(), [])

    def test_diff_prompt_reserves_structural_for_inventory_path_changes(self):
        f = Fixture(self)
        self.assertEqual(f.run("require-diff-classification-contract"), 0, f.last_output)
        self.assertFalse(f.events("missing-diff-classification-contract"))
        f.assert_baseline_unchanged()

    def test_diff_prompt_includes_source_root_and_pinned_range(self):
        f = Fixture(self)
        self.assertEqual(f.run("require-diff-source"), 0, f.last_output)
        self.assertFalse(f.events("missing-diff-context"))
        f.assert_baseline_unchanged()

    def test_f1_failed_diff_cannot_reuse_stale_same_range_report(self):
        f = Fixture(self)
        write(f.scratch / "update-run-state", f"{f.base}..{f.base}\n")
        write(f.scratch / "update-diff.md", "NO_CHANGES_DETECTED\n")
        rc = f.run("fail-diff")
        self.assertIn("diff-discovery", f.labels(), f.last_output)
        f.assert_baseline_unchanged()
        self.assertNotEqual(rc, 0, "Failed mandatory agent accepted stale diff.\n" + f.last_output)
        self.assertNotIn("COMPLETE — no changes detected", f.last_output)

    def test_f2_complete_unchanged_docs_pass_without_new_semantic_review(self):
        f = Fixture(self)
        self.assertEqual(f.run(), 0, f.last_output)
        f.assert_baseline_unchanged()
        f.assert_built()
        self.assertFalse(any(label.startswith("review-") for label in f.labels()), f.last_output)
        self.assertFalse((f.docs / "REVIEW.md").exists())

    def test_f2_unchanged_missing_required_outputs_never_false_success(self):
        required = tuple(f"{tier}/alpha.md" for tier in ("L2", "L3", "L4")) + REQUIRED_SYSTEM + ("mkdocs.yml",)
        for missing in required:
            with self.subTest(missing=missing):
                f = Fixture(self)
                (f.docs / missing).unlink()
                if missing != "mkdocs.yml":
                    f.write_nav()
                rc = f.run()
                f.assert_baseline_unchanged()
                if rc == 0:
                    self.assertTrue((f.docs / missing).is_file(), "False no-change success with missing " + missing + "\n" + f.last_output)
                    self.assertIn("package", f.labels(), f.last_output)
                    f.assert_built()

    def test_f2_unchanged_missing_group_output_never_false_success(self):
        f = Fixture(self, ("alpha", "beta"), GROUP_HEADER + group_row())
        (f.docs / "L2/groups/shared.md").unlink()
        f.write_nav()
        rc = f.run()
        f.assert_baseline_unchanged()
        if rc == 0:
            self.assertTrue((f.docs / "L2/groups/shared.md").is_file(), f.last_output)
            f.assert_built()

    def test_f2_unchanged_strict_build_failure_blocks_success(self):
        f = Fixture(self)
        rc = f.run(build_fail=True)
        f.assert_baseline_unchanged()
        self.assertNotEqual(rc, 0, f.last_output)
        f.assert_built()

    def test_f2_unchanged_stale_navigation_is_repaired_and_built(self):
        f = Fixture(self)
        with (f.docs / "mkdocs.yml").open("a") as nav:
            nav.write("  - Removed page: L4/nonexistent.md\n")
        self.assertEqual(f.run(), 0, f.last_output)
        self.assertNotIn("L4/nonexistent.md", (f.docs / "mkdocs.yml").read_text())
        self.assertIn("L4/alpha.md", (f.docs / "mkdocs.yml").read_text())
        self.assertIn("package", f.labels(), f.last_output)
        f.assert_built()
        f.assert_baseline_unchanged()

    def test_f3_new_target_preserves_successful_baseline_inventory_and_groups(self):
        f = Fixture(self, ("alpha", "beta"), GROUP_HEADER + group_row())
        old_inventory = (f.docs / "builder/specs/component-inventory.md").read_bytes()
        old_groups = (f.docs / "builder/specs/component-groups.md").read_bytes()
        first_target = f.remove_beta()
        self.assertNotEqual(f.run("refresh-then-fail-diff"), 0, f.last_output)
        self.assertIn("diff-discovery", f.labels(), f.last_output)
        self.assertIn("| `beta` | REMOVED |", (f.scratch / "inventory-delta.md").read_text())
        self.assertNotIn("`beta`", (f.docs / "builder/specs/component-inventory.md").read_text())
        write(f.source / "README.md", "# TEST DOUBLE later target, Beta still absent\n")
        second_target = f.commit("TEST DOUBLE later target")
        self.assertNotEqual(first_target, second_target)
        self.assertNotEqual(f.run("refresh-then-fail-diff"), 0, f.last_output)
        self.assertIn("diff-discovery", f.labels(), f.last_output)
        f.assert_baseline_unchanged()
        self.assertEqual((f.scratch / "update-run-state").read_text().strip(), f"{f.base}..{second_target}")
        # Check all independent preservation invariants even on the buggy snapshot.
        for name, expected in (("inventory-before-update.md", old_inventory),
                               ("component-groups-before-update.md", old_groups)):
            with self.subTest(snapshot=name):
                self.assertEqual((f.scratch / name).read_bytes(), expected, f.last_output)
        with self.subTest(removal_delta=True):
            delta = (f.scratch / "inventory-delta.md").read_text()
            self.assertIn("| `beta` | REMOVED |", delta, f.last_output)
            self.assertIn("packages/beta", delta)
        for tier in ("L2", "L3", "L4"):
            self.assertTrue((f.docs / tier / "beta.md").exists(), "Stopped before document removal")

    def test_f4_removal_only_reviews_system_then_packages_and_records(self):
        f = Fixture(self, ("alpha", "beta"))
        target = f.remove_beta()
        self.assertEqual(f.run("remove-clean"), 0, f.last_output)
        self.assertTrue(f.events("system-review"), f.last_output)
        self.assertEqual((f.scratch / "review-system.md").read_text().splitlines()[-1], "SYSTEM_REVIEW_CLEAN")
        self.assertEqual((f.scratch / "review-scope.psv").read_text().strip(), "")
        for tier in ("L2", "L3", "L4"):
            self.assertFalse((f.docs / tier / "beta.md").exists())
            self.assertTrue((f.docs / tier / "alpha.md").is_file())
        nav = (f.docs / "mkdocs.yml").read_text()
        self.assertNotIn("beta.md", nav)
        self.assertIn("L4/alpha.md", nav)
        self.assertIn("package", f.labels())
        f.assert_built()
        self.assertIn(f"commit: {target}\n", f.last_run.read_text())
        self.assertIn("RECORD —", f.last_output)
        self.assertLess(f.last_output.index("PACKAGE — complete"), f.last_output.index("RECORD —"))
        self.assertFalse((f.scratch / "review-alpha.md").exists(), "Unchanged Alpha must not be invented as affected")

    def test_f4_failed_malformed_or_issue_system_review_cannot_advance(self):
        for mode in ("remove-failed-review", "remove-malformed-review", "remove-issues-review"):
            with self.subTest(mode=mode):
                f = Fixture(self, ("alpha", "beta"))
                f.remove_beta()
                rc = f.run(mode)
                f.assert_baseline_unchanged()
                self.assertNotEqual(rc, 0, f.last_output)
                self.assertTrue(f.events("system-review"), "Must reach the system-review failure boundary.\n" + f.last_output)
                self.assertNotIn("package", f.labels(), f.last_output)

    def test_f4_removal_only_strict_build_failure_preserves_baseline(self):
        f = Fixture(self, ("alpha", "beta"))
        f.remove_beta()
        rc = f.run("remove-clean", build_fail=True)
        f.assert_baseline_unchanged()
        self.assertNotEqual(rc, 0, f.last_output)
        self.assertTrue(f.events("system-review"), f.last_output)
        f.assert_built()

    def test_f4_arbitrary_empty_scope_is_not_a_removal_review(self):
        for phase, slugs, mode in (("review", (), "no-change"), ("update", ("alpha",), "empty-scope")):
            with self.subTest(phase=phase):
                f = Fixture(self, slugs)
                self.assertNotEqual(f.run(mode, phase=phase), 0, f.last_output)
                f.assert_baseline_unchanged()
                self.assertFalse(f.events("system-review"), f.last_output)

    def test_f5_grouped_and_explicit_singleton_modules_are_accepted(self):
        for heading in ("Singleton Modules", "Standalone Components"):
            with self.subTest(heading=heading):
                f = Fixture(self, ("alpha", "beta", "gamma"),
                            GROUP_HEADER + group_row() + standalone_rows(("gamma",), heading))
                self.assertEqual(f.run(), 0, f.last_output)
                f.assert_baseline_unchanged()
                f.assert_built()

    def test_slug_reconciliation_updates_group_and_standalone_references(self):
        f = Fixture(self, ("alpha", "beta", "gamma"),
                    GROUP_HEADER + group_row() + standalone_rows(("gamma",)))
        self.assertEqual(f.run("candidate-slugs"), 0, f.last_output)
        self.assertNotIn("candidate-", (f.docs / "builder/specs/component-groups.md").read_text())
        f.assert_baseline_unchanged()
        f.assert_built()

    def test_new_root_package_has_safe_slug_and_matching_standalone_reference(self):
        f = Fixture(self)
        write(f.source / "pyproject.toml", '[project]\nname="root-package"\nversion="0.1.0"\n')
        f.commit("TEST DOUBLE root package discovered")
        self.assertNotEqual(f.run("root-then-fail-diff"), 0, f.last_output)
        self.assertIn("diff-discovery", f.labels(), f.last_output)
        self.assertIn("| `repository-root` | NEW |", (f.scratch / "inventory-delta.md").read_text())
        self.assertIn("`repository-root`", (f.docs / "builder/specs/component-groups.md").read_text())
        self.assertNotIn("agent-root", (f.docs / "builder/specs/component-groups.md").read_text())
        f.assert_baseline_unchanged()

    def test_f5_zero_groups_with_canonical_all_standalone_note_is_accepted(self):
        f = Fixture(self, ("alpha", "beta"), GROUP_HEADER + "\n" + ALL_STANDALONE)
        self.assertEqual(f.run(), 0, f.last_output)
        f.assert_baseline_unchanged()
        f.assert_built()

    def test_negated_standalone_note_cannot_authorize_baseline_advancement(self):
        for mode in ("no-change", "remove-clean"):
            with self.subTest(mode=mode):
                f = Fixture(self, ("alpha", "beta"), GROUP_HEADER + "\nNot all components are standalone.\n")
                if mode == "remove-clean":
                    f.remove_beta()
                self.assertNotEqual(f.run(mode), 0, f.last_output)
                f.assert_baseline_unchanged()
                self.assertNotIn("diff-discovery", f.labels(), f.last_output)

    def test_f5_unknown_duplicate_or_unaccounted_members_still_fail(self):
        invalid = {
            "unknown-group-member": GROUP_HEADER + group_row("alpha, beta, ghost"),
            "duplicate-group-member": GROUP_HEADER + group_row() + group_row("beta", "second", 2),
            "missing-accounted-member": GROUP_HEADER + group_row("alpha"),
            "duplicate-singleton-and-group": GROUP_HEADER + group_row() + standalone_rows(("beta",)),
            "unknown-singleton": GROUP_HEADER + group_row() + standalone_rows(("ghost",)),
            "empty-unexplained-groups": GROUP_HEADER,
        }
        for name, groups in invalid.items():
            with self.subTest(name=name):
                f = Fixture(self, ("alpha", "beta"), groups)
                self.assertNotEqual(f.run(), 0, f.last_output)
                f.assert_baseline_unchanged()
                self.assertNotIn("diff-discovery", f.labels(), f.last_output)


if __name__ == "__main__":
    print(f"Full CLI under test: {SCRIPT}", flush=True)
    print("Offline synthetic agent + mkdocs TEST DOUBLES; not a real-site/model proof.", flush=True)
    unittest.main(verbosity=2)
