#!/usr/bin/env python3
"""Actual-CLI tests. Every answer is an authored synthetic fixture, not model evidence."""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

CLI = Path(__file__).resolve().parents[1] / "scripts/grounded.py"
MKDOCS = (os.environ.get("GROUNDED_TEST_MKDOCS") or
          os.environ.get("DEEPDOCS_MKDOCS_BIN") or shutil.which("mkdocs"))


class GroundedCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="grounded-tests-")
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / "source"
        self.out = self.base / "output"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Synthetic fixture")
        self.write("src/code.py", "VALUE = 1\n\ndef result():\n    return VALUE\n")
        self.write("src/dependency.py", "DEPENDENCY = 'fixture'\n")
        self.write("package.json", '{"name":"fixture","private":true,"scripts":{"start":"SECRET_FIXTURE_VALUE"}}\n')
        self.write("nested/package.json", '{"name":"nested-fixture"}\n')
        self.write("backend/Example.csproj", '<Project Sdk="Microsoft.NET.Sdk" />\n')
        self.write("pyproject.toml", '[project]\nname = "fixture"\n')
        self.write("config.json", '{"feature": false}\n')
        self.write("README.md", "# Fixture\n<!-- HUMAN:START -->\nKeep exactly.\n<!-- HUMAN:END -->\n")
        self.write(".env", "SECRET_FIXTURE_VALUE=never-export-this\n")
        self.commit("synthetic baseline")
        self.pin = self.git("rev-parse", "HEAD").strip()
        self.fixture = {
            "schema_version": 1, "id": "fixture", "source_commit": self.pin,
            "model": "fixture-not-a-model", "agent": "synthetic-test-author",
            "code_claims": [{"text": "Synthetic fixture: VALUE is assigned 1.", "citations": [
                {"path": "src/code.py", "start_line": 1, "end_line": 1, "quote": "VALUE = 1"}]}],
            "human_intent": [{"text": "Synthetic fixture intent.", "attribution": "test fixture author"}],
            "runtime_unknowns": ["Fixture: no runtime has been observed."], "gaps": [],
            "dependency_paths": ["src/dependency.py"], "watch_paths": ["src", "future"]}

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, value, repo=None):
        path = (repo or self.repo) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(value, bytes):
            path.write_bytes(value)
        else:
            path.write_text(value)
        return path

    def git(self, *args, repo=None):
        proc = subprocess.run(["git", "-C", str(repo or self.repo), *args], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout

    def commit(self, message, repo=None):
        self.git("add", "-A", repo=repo)
        self.git("commit", "-qm", message, repo=repo)

    def cli(self, *args, ok=True, out=None):
        proc = subprocess.run([sys.executable, "-B", str(CLI), *map(str, args), "--out", str(out or self.out)],
                              capture_output=True, text=True, timeout=180)
        self.assertEqual(proc.returncode, 0 if ok else 2, proc.stdout + proc.stderr)
        value = json.loads(proc.stdout if ok else proc.stderr)
        return value

    def init(self, *extra):
        return self.cli("init", "--repo", self.repo, *extra)

    def question(self, *extra, ok=True, qid="fixture"):
        return self.cli("question", "--id", qid, "--question", "Synthetic fixture question?", *extra, ok=ok)

    def answer(self, value=None, ok=True):
        path = self.base / "fixture-answer.json"
        path.write_text(json.dumps(value if value is not None else self.fixture))
        return self.cli("accept", "--id", "fixture", "--answer", path, ok=ok)

    def manifest(self):
        return json.loads((self.out / "manifest.json").read_text())

    def ready(self):
        self.init()
        self.question()

    def runner(self, code):
        path = self.base / "fixture-adapter.py"
        path.write_text(code)
        return json.dumps([sys.executable, "-B", str(path)])

    def responding_runner(self, suffix=""):
        return self.runner("import json, sys\nr=json.load(sys.stdin)\nprint(" + repr(json.dumps(self.fixture)) + ")\n" + suffix)

    def accepted(self):
        self.ready()
        self.answer()

    def target(self):
        target = self.base / "target"
        self.git("clone", "-q", str(self.repo), str(target))
        self.git("config", "user.email", "fixture@example.invalid", repo=target)
        self.git("config", "user.name", "Synthetic fixture", repo=target)
        return target

    def test_happy_path_resume_deterministic_inventory_and_no_provider(self):
        before = {p.relative_to(self.repo).as_posix(): p.read_bytes() for p in self.repo.rglob("*")
                  if p.is_file() and ".git" not in p.parts}
        init = self.init()
        self.assertEqual(init["source_commit"], self.pin)
        old_manifest = (self.out / "manifest.json").read_bytes()
        self.assertEqual(self.init()["status"], "resumed")
        self.assertEqual(old_manifest, (self.out / "manifest.json").read_bytes())
        alternate = self.base / "alternate"
        self.cli("init", "--repo", self.repo, out=alternate)
        self.assertEqual((self.out / "inventory.json").read_bytes(), (alternate / "inventory.json").read_bytes())
        inventory = json.loads((self.out / "inventory.json").read_text())
        self.assertEqual([x["path"] for x in inventory["projects"]], ["backend/Example.csproj", "nested/package.json", "package.json", "pyproject.toml"])
        self.assertNotIn("SECRET_FIXTURE_VALUE", (self.out / "inventory.json").read_text())
        self.question()
        request = (self.out / "requests/fixture.json").read_bytes()
        self.question()
        self.assertEqual(request, (self.out / "requests/fixture.json").read_bytes())
        self.assertEqual(self.answer()["semantic_status"], "unreviewed")
        self.assertEqual(self.answer()["status"], "resumed")
        verified = self.cli("verify")
        self.assertEqual((verified["questions"], verified["answers"]), (1, 1))
        self.assertEqual(self.manifest()["budgets"]["calls_reserved"], 0)
        after = {p.relative_to(self.repo).as_posix(): p.read_bytes() for p in self.repo.rglob("*")
                 if p.is_file() and ".git" not in p.parts}
        self.assertEqual(before, after)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_dirty_and_moving_source_admission(self):
        self.write("untracked.txt", "dirty")
        self.assertIn("dirty", self.cli("init", "--repo", self.repo, ok=False)["error"])
        (self.repo / "untracked.txt").unlink()
        self.init()
        self.write("src/code.py", "VALUE = 2\n")
        self.cli("verify", ok=False)
        self.git("checkout", "--", "src/code.py")
        self.cli("verify")
        self.write("new.py", "new = True\n")
        self.commit("move source")
        self.assertIn("moved", self.cli("verify", ok=False)["error"])
        self.question(ok=False)

    def test_reject_nonempty_nested_and_symlink_output(self):
        self.out.mkdir()
        marker = self.out / "handbook.md"
        marker.write_text("<!-- HUMAN -->preserve")
        self.cli("init", "--repo", self.repo, ok=False)
        self.assertEqual(marker.read_text(), "<!-- HUMAN -->preserve")
        self.cli("init", "--repo", self.repo, out=self.repo / "docs", ok=False)
        alias = self.base / "alias"
        alias.symlink_to(self.out, target_is_directory=True)
        self.cli("init", "--repo", self.repo, out=alias, ok=False)
        self.cli("init", "--repo", self.repo / "src", out=self.base / "wrong-root", ok=False)

    def test_wrong_schema_source_and_uncited_claims(self):
        self.ready()
        cases = []
        for key, value in (("source_commit", "0" * 40), ("id", "wrong"), ("schema_version", True),
                           ("model", ""), ("agent", ""), ("code_claims", {}), ("human_intent", ["inferred intent"])):
            answer = copy.deepcopy(self.fixture)
            answer[key] = value
            cases.append(answer)
        missing = copy.deepcopy(self.fixture)
        del missing["gaps"]
        cases.append(missing)
        for field in ("complete", "audited", "semantic_status"):
            answer = copy.deepcopy(self.fixture)
            answer[field] = True
            cases.append(answer)
        answer = copy.deepcopy(self.fixture)
        answer["code_claims"][0]["citations"] = []
        cases.append(answer)
        for answer in cases:
            with self.subTest(answer=answer):
                self.answer(answer, ok=False)
        self.assertIsNone(self.manifest()["questions"]["fixture"]["answer"])
        self.cli("verify")

    def test_bad_spans_quotes_and_paths_fail_closed(self):
        self.ready()
        changes = [{"start_line": 0}, {"end_line": 100}, {"start_line": True}, {"start_line": 3, "end_line": 1},
                   {"quote": "VALUE=1"}, {"start_line": 2, "end_line": 2}, {"quote": "VALUE = 1\n"},
                   {"path": "../source/src/code.py"}, {"path": str(self.repo / "src/code.py")},
                   {"path": "src/./code.py"}, {"path": "src//code.py"}, {"path": "src\\code.py"},
                   {"path": ".env", "quote": "SECRET_FIXTURE_VALUE=never-export-this"}]
        for change in changes:
            with self.subTest(change=change):
                value = copy.deepcopy(self.fixture)
                value["code_claims"][0]["citations"][0].update(change)
                self.answer(value, ok=False)
        self.assertFalse((self.out / "answers").exists())
        self.cli("verify")

    def test_dependency_and_watch_paths_are_explicit_safe_and_validated(self):
        self.ready()
        for field, paths in (("dependency_paths", ["missing.py"]), ("dependency_paths", ["src"]),
                             ("watch_paths", ["../outside"]), ("watch_paths", ["src/*"]),
                             ("dependency_paths", [".env"]), ("watch_paths", [".env"]),
                             ("dependency_paths", ["src/code.py", "src/code.py"])):
            value = copy.deepcopy(self.fixture)
            value[field] = paths
            self.answer(value, ok=False)
        self.answer()
        envelope = json.loads((self.out / "answers/fixture.json").read_text())
        self.assertEqual(set(envelope["validation"]["supporting_file_sha256"]), {"src/code.py", "src/dependency.py"})

    def test_source_symlink_binary_large_file_and_submodule_escape(self):
        outside = self.base / "outside.py"
        outside.write_text("VALUE = 1\n")
        (self.repo / "linked.py").symlink_to(outside)
        (self.repo / "linked-dir").symlink_to(self.repo / "src", target_is_directory=True)
        self.write("binary.dat", b"VALUE = 1\0\n")
        self.write("large.py", b"x" * 2_000_001)
        self.git("clone", "-q", str(self.repo), str(self.repo / "submodule"))
        self.commit("unsafe fixture entries")
        self.assertIn("160000 commit", self.git("ls-tree", "HEAD", "submodule"))
        self.pin = self.git("rev-parse", "HEAD").strip()
        self.fixture["source_commit"] = self.pin
        self.ready()
        for path in ("linked.py", "linked-dir/code.py", "binary.dat", "large.py", "submodule/code.py"):
            answer = copy.deepcopy(self.fixture)
            answer["code_claims"][0]["citations"][0]["path"] = path
            self.answer(answer, ok=False)
        self.assertEqual(outside.read_text(), "VALUE = 1\n")

    def test_crlf_quotes_use_logical_lines_but_hash_original_bytes(self):
        raw = b"VALUE = 1\r\n\r\ndef result():\r\n    return VALUE\r\n"
        self.write("src/code.py", raw)
        self.commit("CRLF fixture")
        self.fixture["source_commit"] = self.git("rev-parse", "HEAD").strip()
        self.fixture["code_claims"][0]["citations"][0].update(end_line=4, quote="VALUE = 1\n\ndef result():\n    return VALUE")
        self.accepted()
        saved = json.loads((self.out / "answers/fixture.json").read_text())
        self.assertEqual(saved["validation"]["supporting_file_sha256"]["src/code.py"], hashlib.sha256(raw).hexdigest())

    def test_valid_spans_do_not_claim_semantic_correctness(self):
        self.ready()
        value = copy.deepcopy(self.fixture)
        value["code_claims"][0]["text"] = "Synthetic negative semantic fixture: this assignment proves the moon is cheese."
        self.answer(value)
        envelope = json.loads((self.out / "answers/fixture.json").read_text())
        self.assertEqual(envelope["validation"]["semantic_status"], "unreviewed")
        self.assertEqual(envelope["validation"]["citation_status"], "verified")

    def test_unknown_only_answer_is_valid_but_wrong_answer_cannot_replace_it(self):
        self.ready()
        value = copy.deepcopy(self.fixture)
        value["code_claims"] = []
        value["dependency_paths"] = []
        self.answer(value)
        self.answer(ok=False)
        self.cli("verify")

    def test_manifest_artifact_receipt_and_partial_tampering(self):
        self.accepted()
        for name in ("manifest.json", "manifest.sha256", "inventory.json", "requests/fixture.json", "answers/fixture.json", "receipts/000001.json"):
            with self.subTest(name=name):
                path = self.out / name
                original = path.read_bytes()
                path.write_bytes(original + b" ")
                # Trailing checksum whitespace is intentionally tolerated; change a digit.
                if name == "manifest.sha256":
                    path.write_text("0" * 64 + "\n")
                self.cli("verify", ok=False)
                path.write_bytes(original)
                path.unlink()
                self.cli("verify", ok=False)
                path.write_bytes(original)
        self.cli("verify")
        extra = self.out / "handbook.md"
        extra.write_text("<!-- HUMAN -->preserve")
        self.cli("verify", ok=False)
        self.assertEqual(extra.read_text(), "<!-- HUMAN -->preserve")

    def test_output_symlink_hardlink_and_answer_input_symlink(self):
        self.ready()
        path = self.out / "inventory.json"
        original = path.read_bytes()
        outside = self.base / "inventory-copy.json"
        outside.write_bytes(original)
        path.unlink()
        path.symlink_to(outside)
        self.cli("verify", ok=False)
        self.question(ok=False)
        self.assertEqual(outside.read_bytes(), original)
        path.unlink()
        os.link(outside, path)
        self.cli("verify", ok=False)
        path.unlink()
        path.write_bytes(original)
        fixture = self.base / "fixture.json"
        fixture.write_text(json.dumps(self.fixture))
        linked = self.base / "fixture-link.json"
        linked.symlink_to(fixture)
        self.cli("accept", "--id", "fixture", "--answer", linked, ok=False)
        self.cli("verify")

    def test_question_id_and_model_conflict(self):
        self.init()
        for qid in ("../escape", "UPPERCASE", "", "x" * 65):
            self.question(qid=qid, ok=False)
        self.question("--model", "fixture-selected")
        self.question("--model", "changed", ok=False)
        self.cli("question", "--id", "fixture", "--question", "different", "--model", "fixture-selected", ok=False)
        self.cli("verify")

    def test_explicit_model_request_successful_adapter_and_no_replay(self):
        self.init()
        marker = self.base / "invocations.txt"
        runner = self.runner("import json,sys,pathlib\nr=json.load(sys.stdin)\nassert r['selected_model']=='fixture-selected'\n"
                             + "assert r['source']['commit']==" + repr(self.pin) + "\n"
                             + "pathlib.Path(" + repr(str(marker)) + ").open('a').write('called\\n')\n"
                             + "print(" + repr(json.dumps(self.fixture)) + ")\n")
        result = self.question("--model", "fixture-selected", "--runner-json", runner, "--timeout", "2")
        self.assertEqual(result["status"], "accepted")
        self.question("--model", "fixture-selected", "--runner-json", runner, "--timeout", "2")
        self.assertEqual(marker.read_text(), "called\n")
        manifest = self.manifest()
        self.assertEqual(manifest["budgets"]["calls_reserved"], 1)
        self.assertGreater(manifest["budgets"]["wall_seconds_reserved"], 0)
        records = [json.loads((self.out / name).read_text()) for name in manifest["receipts"]]
        self.assertEqual([r["data"]["actual_model"] for r in records if r["event"] == "adapter-succeeded"], ["fixture-not-a-model"])
        self.cli("verify")

    def test_failed_exit_with_plausible_answer_is_never_accepted(self):
        self.init("--max-calls", "1", "--max-wall-seconds", "5")
        runner = self.responding_runner("sys.exit(3)\n")
        self.question("--runner-json", runner, "--timeout", "1", ok=False)
        self.assertFalse((self.out / "answers/fixture.json").exists())
        self.assertEqual(self.manifest()["budgets"]["calls_reserved"], 1)
        failure = self.question("--runner-json", runner, "--timeout", "1", ok=False)
        self.assertIn("call budget", failure["error"])
        self.cli("verify")
        self.cli("init", "--repo", self.repo, "--max-calls", "2", "--max-wall-seconds", "5", ok=False)

    def test_timeout_process_group_and_wall_budget_survive_restart(self):
        self.init("--max-calls", "5", "--max-wall-seconds", "0.3")
        marker = self.base / "descendant-survived"
        runner = self.runner("import subprocess,sys,time\n"
            "subprocess.Popen([sys.executable,'-c'," + repr("import time,pathlib; time.sleep(0.7); pathlib.Path(" + repr(str(marker)) + ").write_text('bad')") + "])\n"
            "time.sleep(20)\n")
        started = time.monotonic()
        failure = self.question("--runner-json", runner, "--timeout", "0.2", ok=False)
        self.assertIn("timeout", failure["error"])
        self.assertLess(time.monotonic() - started, 5)
        budget = self.manifest()["budgets"]
        self.assertEqual(budget["calls_reserved"], 1)
        self.assertGreaterEqual(budget["wall_seconds_reserved"], 0.2)
        failure = self.question("--runner-json", runner, "--timeout", "0.2", ok=False)
        self.assertIn("wall-time budget", failure["error"])
        time.sleep(0.75)
        self.assertFalse(marker.exists())
        self.cli("verify")

    def test_malformed_runner_response_and_stdout_stderr_limits(self):
        self.init()
        variants = ["print('not json')", "print('[]')", "print('{}')", "print('{\"schema_version\":1,\"schema_version\":1}')",
                    "print('x'*2100000)", "import sys; sys.stderr.write('x'*2100000)"]
        for code in variants:
            runner = self.runner(code)
            self.question("--runner-json", runner, "--timeout", "1", ok=False)
            self.assertFalse((self.out / "answers/fixture.json").exists())
        self.assertEqual(self.manifest()["budgets"]["calls_reserved"], len(variants))
        self.cli("verify")

    def test_runner_missing_executable_invalid_argv_and_invalid_timeouts(self):
        self.init()
        for command in ('[]', '"shell command"', '[3]', '["x", null]'):
            self.question("--runner-json", command, ok=False)
        for value in ("0", "-1", "nan", "inf"):
            self.question("--timeout", value, ok=False)
        self.assertEqual(self.manifest()["budgets"]["calls_reserved"], 0)
        self.question("--runner-json", '["/nonexistent/fixture-adapter"]', "--timeout", "1", ok=False)
        self.assertEqual(self.manifest()["budgets"]["calls_reserved"], 1)
        self.cli("verify")

    def test_source_dirty_or_moved_during_runner_never_accepts(self):
        self.init()
        runner = self.responding_runner("from pathlib import Path\nPath('untracked.txt').write_text('fixture mutation')\n")
        self.question("--runner-json", runner, "--timeout", "2", ok=False)
        self.assertFalse((self.out / "answers/fixture.json").exists())
        (self.repo / "untracked.txt").unlink()
        self.cli("verify")
        runner = self.responding_runner("import subprocess\nsubprocess.run(['git','commit','--allow-empty','-qm','fixture moving source'],check=True)\n")
        self.question("--runner-json", runner, "--timeout", "2", ok=False)
        self.assertFalse((self.out / "answers/fixture.json").exists())
        self.git("checkout", "-q", self.pin)
        self.cli("verify")

    def test_concurrent_runner_calls_serialize_durable_call_budget(self):
        self.init("--max-calls", "1", "--max-wall-seconds", "5")
        runner = self.runner("import time,sys\ntime.sleep(.2)\nsys.exit(1)\n")
        command = [sys.executable, "-B", str(CLI), "question", "--out", str(self.out), "--id", "fixture",
                   "--question", "Synthetic fixture question?", "--runner-json", runner, "--timeout", "1"]
        first = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        outputs = [p.communicate(timeout=10) for p in (first, second)]
        self.assertEqual([first.returncode, second.returncode], [2, 2])
        self.assertTrue(any(b"call budget" in error for _, error in outputs))
        self.assertEqual(self.manifest()["budgets"]["calls_reserved"], 1)
        self.cli("verify")

    def test_interrupted_cli_keeps_full_reservation_durable(self):
        self.init("--max-calls", "2", "--max-wall-seconds", "5")
        marker = self.base / "adapter-pid"
        runner = self.runner("import os,pathlib,time\npathlib.Path(" + repr(str(marker)) +
                             ").write_text(str(os.getpid()))\ntime.sleep(20)\n")
        command = [sys.executable, "-B", str(CLI), "question", "--out", str(self.out), "--id", "fixture",
                   "--question", "Synthetic fixture question?", "--runner-json", runner, "--timeout", "5"]
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), "adapter did not start")
            process.kill()
            process.communicate(timeout=5)
            budget = self.manifest()["budgets"]
            self.assertEqual((budget["calls_reserved"], budget["wall_seconds_reserved"]), (1, 5))
            failed = self.question("--runner-json", runner, "--timeout", "1", ok=False)
            self.assertIn("wall-time budget", failed["error"])
            self.cli("verify")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
            if marker.exists():
                try:
                    os.killpg(int(marker.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_manual_malformed_and_encoded_oversized_answer_keeps_registry_valid(self):
        self.ready()
        path = self.base / "bad-answer.json"
        for value in ("{", "[]", '{"x":NaN}', '{"x":1,"x":2}'):
            path.write_text(value)
            self.cli("accept", "--id", "fixture", "--answer", path, ok=False)
        answer = copy.deepcopy(self.fixture)
        answer["gaps"] = ["\u00e9" * 19000] * 20
        path.write_text(json.dumps(answer, ensure_ascii=False))
        self.assertLess(path.stat().st_size, 2_000_000)
        failure = self.cli("accept", "--id", "fixture", "--answer", path, ok=False)
        self.assertIn("byte limit", failure["error"])
        self.cli("verify")

    @unittest.skipUnless(MKDOCS, "existing MkDocs unavailable; set GROUNDED_TEST_MKDOCS")
    def test_built_registry_is_immutable_and_generated_text_is_inert(self):
        self.ready()
        answer = copy.deepcopy(self.fixture)
        answer["code_claims"][0]["text"] = '<script>alert(1)</script> [bad](../../outside) ![image](https://example.invalid/private)'
        self.answer(answer)
        self.cli("build", "--mkdocs", MKDOCS)
        rendered = (self.out / "site/answers/fixture/index.html").read_text()
        self.assertNotIn("<script>alert(1)</script>", rendered)
        self.assertNotIn('src="https://example.invalid/private"', rendered)
        self.question(qid="new-question", ok=False)
        self.answer(answer)
        self.cli("verify")
        page = self.out / "site/index.html"
        page.unlink()
        self.cli("verify", ok=False)

    def test_build_rejects_source_movement_before_publication(self):
        self.accepted()
        fake = self.base / "fixture-moving-renderer"
        fake.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nimport subprocess\n"
                        "Path('site').mkdir()\nPath('site/index.html').write_text('<html>fixture</html>')\n"
                        "subprocess.run(['git','-C'," + repr(str(self.repo)) +
                        ",'commit','--allow-empty','-qm','fixture moving source'],check=True)\n")
        fake.chmod(0o700)
        self.cli("build", "--mkdocs", fake, ok=False)
        self.assertFalse((self.out / "site").exists())
        self.git("checkout", "-q", self.pin)
        self.cli("verify")

    def test_freshness_cited_dependent_config_new_deleted_and_unknown(self):
        self.accepted()
        target = self.target()
        unchanged = self.cli("freshness", "--repo", target)
        self.assertEqual(unchanged["status"], "unchanged")
        self.write("src/code.py", "VALUE = 2\n", repo=target)
        self.write("src/dependency.py", "DEPENDENCY = 'changed'\n", repo=target)
        self.write("config.json", '{"feature":true}\n', repo=target)
        self.write("future/new.py", "new = True\n", repo=target)
        self.write("unrelated.py", "new = True\n", repo=target)
        self.write("README.md", "Changed unrelated prose\n", repo=target)
        (target / "nested/package.json").unlink()
        self.commit("target drift", repo=target)
        result = self.cli("freshness", "--repo", target)
        self.assertEqual(result["status"], "needs-review")
        self.assertFalse(result["baseline_advanced"])
        changes = {x["path"]: x for x in result["changes"]}
        self.assertEqual(len(changes), 7)
        self.assertIn("cited", changes["src/code.py"]["reasons"])
        self.assertIn("dependency", changes["src/dependency.py"]["reasons"])
        self.assertIn("configuration-or-operational", changes["config.json"]["reasons"])
        self.assertIn("watched", changes["future/new.py"]["reasons"])
        self.assertEqual(changes["unrelated.py"]["change"], "added")
        self.assertEqual(changes["nested/package.json"]["change"], "deleted")
        self.assertEqual(changes["README.md"]["reasons"], ["unknown-impact"])
        self.assertEqual(self.manifest()["source"]["commit"], self.pin)
        self.cli("verify")

    def test_freshness_deleted_citation_and_dirty_or_unrelated_target(self):
        self.accepted()
        target = self.target()
        self.write("dirty.py", "dirty", repo=target)
        self.cli("freshness", "--repo", target, ok=False)
        (target / "dirty.py").unlink()
        (target / "src/code.py").unlink()
        self.commit("delete cited", repo=target)
        result = self.cli("freshness", "--repo", target)
        self.assertEqual(result["changes"][0]["reasons"], ["cited", "watched", "deleted"])
        other = self.base / "unrelated"
        other.mkdir()
        self.git("init", "-q", repo=other)
        self.git("config", "user.email", "fixture@example.invalid", repo=other)
        self.git("config", "user.name", "Synthetic fixture", repo=other)
        self.write("other.txt", "unrelated", repo=other)
        self.commit("unrelated", repo=other)
        self.cli("freshness", "--repo", other, ok=False)

    @unittest.skipUnless(MKDOCS, "existing MkDocs unavailable; set GROUNDED_TEST_MKDOCS (no install attempted)")
    def test_actual_strict_mkdocs_build_links_http_resume_and_human_preservation(self):
        original = (self.repo / "README.md").read_bytes()
        self.accepted()
        built = self.cli("build", "--mkdocs", MKDOCS)
        self.assertEqual(built["status"], "built")
        self.assertGreaterEqual(built["http_pages_checked"], 3)
        self.assertGreater(built["local_links_checked"], 0)
        self.cli("verify")
        self.assertEqual(self.cli("build", "--mkdocs", MKDOCS)["status"], "resumed")
        self.assertEqual((self.repo / "README.md").read_bytes(), original)
        self.assertEqual(self.git("status", "--porcelain"), "")
        page = self.out / "docs/answers/fixture.md"
        page.write_text(page.read_text() + "\n<!-- HUMAN -->Do not overwrite.\n")
        preserved = page.read_bytes()
        self.cli("build", "--mkdocs", MKDOCS, ok=False)
        self.assertEqual(page.read_bytes(), preserved)
        self.cli("verify", ok=False)

    def test_build_missing_or_failed_renderer_keeps_registry_usable(self):
        self.accepted()
        self.cli("build", "--mkdocs", "/nonexistent/mkdocs", ok=False)
        self.cli("verify")
        self.assertIsNone(self.manifest()["build"])
        fake = self.base / "failed-renderer"
        fake.write_text("#!/usr/bin/env python3\nimport sys\nprint('plausible build message')\nsys.exit(1)\n")
        fake.chmod(0o700)
        self.cli("build", "--mkdocs", fake, ok=False)
        self.cli("verify")
        self.assertFalse((self.out / "site").exists())

    def test_relocated_output_is_refused_before_lock_or_writes(self):
        self.ready()
        fixture = self.base / "answer.json"
        fixture.write_text(json.dumps(self.fixture))
        for destination in (self.repo / ".git/relocated", self.repo / "ignored-output"):
            if destination.name == "ignored-output":
                (self.repo / ".git/info/exclude").write_text("ignored-output/\n")
            shutil.move(self.out, destination)
            (destination / ".lock").unlink()
            before = {p.relative_to(destination): p.read_bytes() for p in destination.rglob("*") if p.is_file()}
            self.cli("accept", "--id", "fixture", "--answer", fixture, out=destination, ok=False)
            self.cli("verify", out=destination, ok=False)
            after = {p.relative_to(destination): p.read_bytes() for p in destination.rglob("*") if p.is_file()}
            self.assertEqual(after, before)
            self.assertFalse((destination / ".lock").exists())
            shutil.move(destination, self.out)
            self.cli("verify")

    def test_init_refuses_shared_git_metadata_output(self):
        source = self.base / "source-worktree"
        self.git("worktree", "add", "--detach", str(source), self.pin)
        self.cli("init", "--repo", source, out=self.repo / ".git/new-output", ok=False)
        self.assertFalse((self.repo / ".git/new-output").exists())

    def test_linkless_partial_renderer_cannot_claim_complete_site(self):
        self.accepted()
        fake = self.base / "partial-renderer"
        fake.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\n"
                        "Path('site').mkdir()\nPath('site/index.html').write_text('<html>Partial fixture</html>')\n")
        fake.chmod(0o700)
        before = (self.out / "manifest.json").read_bytes()
        self.cli("build", "--mkdocs", fake, ok=False)
        self.assertEqual((self.out / "manifest.json").read_bytes(), before)
        self.assertFalse((self.out / "docs").exists())
        self.cli("verify")

    def test_stage_escape_rejected_before_smoke_or_partial_publication(self):
        self.accepted()
        import importlib.util
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location("grounded_stage_probe", CLI)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        outside = self.base / "outside.html"
        outside.write_text("NEUTRAL_OUTSIDE_FIXTURE")
        fake = self.base / "symlink-renderer"
        fake.write_text("#!/usr/bin/env python3\nfrom pathlib import Path\n"
                        "Path('site').mkdir()\nPath('site/index.html').symlink_to(" + repr(str(outside)) + ")\n")
        fake.chmod(0o700)
        before = {p.relative_to(self.out): p.read_bytes() for p in self.out.rglob("*") if p.is_file()}
        with patch.object(module, "smoke", side_effect=AssertionError("must not read or serve invalid stage")) as smoke:
            with self.assertRaises(module.Refusal):
                module.build(self.out, module.load_registry(self.out), argparse.Namespace(mkdocs=str(fake)))
            smoke.assert_not_called()
        after = {p.relative_to(self.out): p.read_bytes() for p in self.out.rglob("*") if p.is_file()}
        self.assertEqual(after, before)
        self.cli("verify")

    def test_fake_successful_renderer_cannot_bypass_required_artifacts_or_links(self):
        self.accepted()
        fake = self.base / "fixture-renderer"
        variants = ["pass", "from pathlib import Path\nPath('site').mkdir()\nPath('site/index.html').write_text('<a href=\"missing.html\">bad</a>')"]
        for code in variants:
            fake.write_text("#!/usr/bin/env python3\n" + code + "\n")
            fake.chmod(0o700)
            self.cli("build", "--mkdocs", fake, ok=False)
            self.cli("verify")


if __name__ == "__main__":
    unittest.main(verbosity=2)
