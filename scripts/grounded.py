#!/usr/bin/env python3
"""Small, local source-grounded question registry. No provider SDK or implicit LLM."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import html
from html.parser import HTMLParser
import http.server
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

VERSION = 1
MAX_BYTES = 2_000_000
SLUG = re.compile(r"[a-z0-9][a-z0-9-]{0,63}\Z")
HEX = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?\Z")
EXCLUDED_DIRS = {".git", ".hermes", ".aws", ".azure", ".ssh", ".terraform",
                 "node_modules", ".venv", "venv", "logs", "secrets", "credentials",
                 "operations", "ops", "deployments"}


class Refusal(Exception):
    pass


def require(ok, message):
    if not ok:
        raise Refusal(message)


def encoded(value):
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, indent=2,
                       allow_nan=False) + "\n").encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate JSON key")
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs,
                          parse_constant=lambda value: (_ for _ in ()).throw(Refusal("non-finite JSON")))
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise Refusal("invalid JSON") from exc


def keys(value, required):
    require(isinstance(value, dict) and set(value) == set(required.split()),
            "unexpected or missing object keys: " + required)


def text(value, label, limit=20000):
    require(isinstance(value, str) and 0 < len(value) <= limit and "\0" not in value,
            "invalid " + label)
    return value


def array(value, label):
    require(isinstance(value, list) and len(value) <= 1000, "invalid " + label)
    return value


def relative(value):
    text(value, "relative path", 1000)
    path = PurePosixPath(value)
    require(not path.is_absolute() and path.parts and
            all(p not in ("", ".", "..") for p in value.split("/")) and
            not any(c in value for c in "\\\n\r\t:*?[]") and path.parts[0] != ".git",
            "unsafe relative path")
    return value


def excluded(path):
    parts = PurePosixPath(path).parts
    name = parts[-1].lower()
    return (any(p.lower() in EXCLUDED_DIRS for p in parts) or
            name.startswith((".env", "appsettings", "credentials", "secrets")) or
            name in {".npmrc", ".pypirc", "id_rsa", "id_ed25519"} or
            name.endswith((".pem", ".key", ".pfx", ".p12", ".log", ".tfstate")))


def no_symlinks(path):
    path = Path(os.path.abspath(path))
    for part in [path, *path.parents]:
        require(not part.is_symlink(), "symlink path refused: " + str(part))
    return path


def bounded_read(path):
    path = no_symlinks(path)
    require(path.is_file(), "missing regular file: " + str(path))
    require(path.stat().st_size <= MAX_BYTES, "file exceeds byte limit")
    return path.read_bytes()


def git(repo, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_NO_REPLACE_OBJECTS="1")
    proc = subprocess.run(["git", "--no-optional-locks", "-C", str(repo), *args],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=30)
    require(proc.returncode == 0, "Git operation failed: " + args[0])
    return proc.stdout


def identity(repo):
    repo = no_symlinks(repo)
    root = Path(os.fsdecode(git(repo, "rev-parse", "--show-toplevel")).strip())
    require(root == repo, "--repo must be the checkout root")
    require(not git(repo, "status", "--porcelain=v1", "--untracked-files=all"),
            "source checkout is dirty")
    head = git(repo, "rev-parse", "--verify", "HEAD").decode().strip()
    common = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip()
    require(HEX.fullmatch(head), "invalid Git commit identity")
    return {"repo": str(repo), "git_common_dir": str(Path(common).resolve()),
            "commit": head, "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip()}


def check_source(manifest):
    require(identity(manifest["source"]["repo"]) == manifest["source"],
            "source identity moved from pin")


def check_output_location(root, source):
    root = no_symlinks(root)
    for key in ("repo", "git_common_dir"):
        boundary = no_symlinks(source[key])
        require(not root.is_relative_to(boundary) and not boundary.is_relative_to(root),
                "output must be separate from source and Git metadata")


def tree(source, revision=None):
    rows = {}
    for record in git(source["repo"], "ls-tree", "-rz", "--full-tree",
                      revision or source["commit"]).split(b"\0"):
        if not record:
            continue
        meta, name = record.split(b"\t", 1)
        mode, kind, oid = meta.decode().split()
        path = name.decode("utf-8", errors="strict")
        rows[path] = {"mode": mode, "type": kind, "oid": oid}
    return rows


def safe_source_path(source, rows, path, must_exist=True):
    relative(path)
    require(not excluded(path), "excluded source path: " + path)
    for parent in [PurePosixPath(path), *PurePosixPath(path).parents]:
        item = rows.get(str(parent))
        require(not item or item["mode"] not in {"120000", "160000"},
                "source symlink/submodule refused")
    no_symlinks(Path(source["repo"]) / path)
    if must_exist:
        require(path in rows and rows[path]["type"] == "blob" and
                rows[path]["mode"] in {"100644", "100755"}, "not a pinned regular file: " + path)


def blob(source, rows, path):
    safe_source_path(source, rows, path)
    oid = rows[path]["oid"]
    require(int(git(source["repo"], "cat-file", "-s", oid)) <= MAX_BYTES,
            "source file exceeds byte limit")
    return git(source["repo"], "cat-file", "blob", oid)


def inventory(source, rows):
    entries = []
    for path in sorted(rows):
        name = PurePosixPath(path).name
        kind = ("node" if name == "package.json" else "dotnet" if name.endswith(".csproj")
                else "python" if name == "pyproject.toml" else None)
        if kind and not excluded(path) and rows[path]["mode"] in {"100644", "100755"}:
            entries.append({"path": path, "kind": kind, "sha256": digest(blob(source, rows, path))})
    return {"schema_version": VERSION, "source_commit": source["commit"], "projects": entries}


def atomic(path, data):
    path = no_symlinks(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".grounded-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def save(root, manifest):
    data = encoded(manifest)
    require(len(data) <= MAX_BYTES, "registry exceeds byte limit; start a new bounded run")
    atomic(root / "manifest.json", data)
    atomic(root / "manifest.sha256", (digest(data) + "\n").encode())


def put(root, manifest, name, data):
    relative(name)
    if name.endswith(".json"):
        require(len(data) <= MAX_BYTES, "JSON artifact exceeds byte limit")
    target = no_symlinks(root / name)
    require(not target.exists() or (name in manifest["artifacts"] and
            digest(target.read_bytes()) == manifest["artifacts"][name]), "refusing to overwrite unowned/changed material")
    atomic(target, data)
    manifest["artifacts"][name] = digest(data)


def receipt(root, manifest, event, data):
    number = len(manifest["receipts"]) + 1
    name = f"receipts/{number:06d}.json"
    require(not (root / name).exists(), "receipt collision")
    previous = manifest["artifacts"].get(manifest["receipts"][-1]) if manifest["receipts"] else None
    put(root, manifest, name, encoded({"schema_version": VERSION, "sequence": number,
        "event": event, "data": data, "previous_sha256": previous,
        "time_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    manifest["receipts"].append(name)
    save(root, manifest)


@contextlib.contextmanager
def locked(root):
    if (root / "manifest.json").exists():
        raw = bounded_read(root / "manifest.json")
        require(bounded_read(root / "manifest.sha256").decode().strip() == digest(raw),
                "manifest checksum mismatch")
        check_output_location(root, load_json(raw)["source"])
    path = no_symlinks(root / ".lock")
    with path.open("a+b") as stream:
        require(os.fstat(stream.fileno()).st_nlink == 1, "hardlinked lock refused")
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def validate_answer(answer, request, source, rows):
    keys(answer, "schema_version id source_commit model agent code_claims human_intent runtime_unknowns gaps dependency_paths watch_paths")
    require(type(answer["schema_version"]) is int and answer["schema_version"] == VERSION,
            "unsupported answer schema")
    require(answer["id"] == request["id"] and answer["source_commit"] == source["commit"],
            "answer question/source revision mismatch")
    text(answer["model"], "actual model", 200)
    text(answer["agent"], "agent", 200)
    support = {}
    cited = set()
    for claim in array(answer["code_claims"], "code claims"):
        keys(claim, "text citations")
        text(claim["text"], "claim")
        require(array(claim["citations"], "citations"), "code claim missing citations")
        for citation in claim["citations"]:
            keys(citation, "path start_line end_line quote")
            path, start, end = citation["path"], citation["start_line"], citation["end_line"]
            require(type(start) is int and type(end) is int and 1 <= start <= end,
                    "invalid citation line range")
            raw = blob(source, rows, path)
            require(b"\0" not in raw, "binary citation refused")
            try:
                lines = raw.decode("utf-8").splitlines()
            except UnicodeError as exc:
                raise Refusal("non-UTF-8 citation refused") from exc
            text(citation["quote"], "quote", MAX_BYTES)
            require(end <= len(lines) and citation["quote"] == "\n".join(lines[start - 1:end]),
                    "citation quote does not match exact pinned lines")
            support[path] = digest(raw)
            cited.add(path)
    for item in array(answer["human_intent"], "human intent"):
        keys(item, "text attribution")
        text(item["text"], "human intent")
        text(item["attribution"], "human attribution")
    for field in ("runtime_unknowns", "gaps"):
        for item in array(answer[field], field):
            text(item, field)
    for field in ("dependency_paths", "watch_paths"):
        paths = array(answer[field], field)
        require(all(isinstance(p, str) for p in paths) and len(paths) == len(set(paths)),
                "duplicate or invalid dependency/watch path")
        for path in paths:
            safe_source_path(source, rows, path, field == "dependency_paths")
            if field == "dependency_paths":
                support[path] = digest(blob(source, rows, path))
    return {"citation_status": "verified", "semantic_status": "unreviewed",
            "coverage_status": "bounded-not-exhaustive", "cited_paths": sorted(cited),
            "supporting_file_sha256": dict(sorted(support.items()))}


def request_for(manifest, qid, question, model):
    return {"schema_version": VERSION, "id": qid, "question": question,
            "source": manifest["source"], "selected_model": model,
            "answer_contract": {"required_fields": "schema_version id source_commit model agent code_claims human_intent runtime_unknowns gaps dependency_paths watch_paths".split(),
                "code_claim": {"text": "source-backed claim", "citations": [{"path": "relative/path", "start_line": 1,
                    "end_line": 1, "quote": "complete exact lines, no final newline"}]},
                "human_intent_item": {"text": "human-provided intent only", "attribution": "human source"},
                "string_arrays": ["runtime_unknowns", "gaps", "dependency_paths", "watch_paths"],
                "model": "actual model identifier, or unknown", "agent": "actual agent identifier, or unknown"},
            "rules": ["Read-only pinned Git source; never change source or existing docs/HUMAN blocks.",
                "Use existing authorised source tools; no private-code upload or new provider integration.",
                "Every code claim needs exact pinned relative-path/positive-inclusive-line/quote citations.",
                "Return only the answer JSON object; unknown keys and unsupported certification flags fail.",
                "Separate human-attributed intent, runtime unknowns and gaps. Never infer intent or deployment state.",
                "Matching spans is not semantic validation. Keep investigation bounded to this question.",
                "Do not read secrets/operational files or traverse symlinks/submodules.",
                "Dependency paths must be pinned regular files; watch paths are relative files/directories, no globs."]}


def load_registry(root, source_check=True):
    raw = bounded_read(root / "manifest.json")
    require(bounded_read(root / "manifest.sha256").decode().strip() == digest(raw), "manifest checksum mismatch")
    manifest = load_json(raw)
    keys(manifest, "schema_version source budgets questions artifacts receipts build")
    require(type(manifest["schema_version"]) is int and manifest["schema_version"] == VERSION, "unsupported manifest")
    keys(manifest["source"], "repo git_common_dir commit tree")
    check_output_location(root, manifest["source"])
    require(HEX.fullmatch(manifest["source"]["commit"]), "invalid source pin")
    keys(manifest["budgets"], "max_calls max_wall_seconds calls_reserved wall_seconds_reserved")
    budget = manifest["budgets"]
    require(type(budget["max_calls"]) is int and type(budget["calls_reserved"]) is int and
            0 <= budget["calls_reserved"] <= budget["max_calls"], "invalid call budget")
    require(all(type(budget[k]) in (int, float) and math.isfinite(budget[k]) and budget[k] >= 0
                for k in ("max_wall_seconds", "wall_seconds_reserved")), "invalid wall budget")
    require(isinstance(manifest["artifacts"], dict) and isinstance(manifest["questions"], dict), "invalid registry maps")
    require(isinstance(manifest["receipts"], list) and manifest["receipts"], "missing receipts")
    expected = set(manifest["artifacts"]) | {"manifest.json", "manifest.sha256", ".lock"}
    actual = set()
    for path in root.rglob("*"):
        no_symlinks(path)
        if path.is_file():
            require(path.stat().st_nlink == 1, "hardlinked artifact refused")
            actual.add(path.relative_to(root).as_posix())
        else:
            require(path.is_dir(), "nonregular output entry")
    require(actual == expected, "missing or unregistered output artifacts")
    for name, sha in manifest["artifacts"].items():
        relative(name)
        require(digest((root / name).read_bytes()) == sha, "artifact hash mismatch: " + name)
    previous = None
    for number, name in enumerate(manifest["receipts"], 1):
        require(name == f"receipts/{number:06d}.json", "invalid receipt sequence")
        record = load_json(bounded_read(root / name))
        keys(record, "schema_version sequence event data previous_sha256 time_utc")
        require(record["sequence"] == number and record["previous_sha256"] == previous, "receipt chain mismatch")
        previous = manifest["artifacts"][name]
    if source_check:
        check_source(manifest)
    rows = tree(manifest["source"])
    require(load_json(bounded_read(root / "inventory.json")) == inventory(manifest["source"], rows),
            "inventory mismatch")
    registered = {"inventory.json", *manifest["receipts"]}
    for qid, item in manifest["questions"].items():
        require(SLUG.fullmatch(qid), "invalid question ID")
        keys(item, "request answer")
        require(item["request"] == f"requests/{qid}.json", "invalid request registration")
        request = load_json(bounded_read(root / item["request"]))
        require(request == request_for(manifest, qid, text(request["question"], "question"),
                                        text(request["selected_model"], "selected model", 200)), "request mismatch")
        registered.add(item["request"])
        if item["answer"] is not None:
            require(item["answer"] == f"answers/{qid}.json", "invalid answer registration")
            envelope = load_json(bounded_read(root / item["answer"]))
            keys(envelope, "answer validation")
            require(envelope["validation"] == validate_answer(envelope["answer"], request, manifest["source"], rows),
                    "answer validation mismatch")
            registered.add(item["answer"])
    if manifest["build"] is not None:
        keys(manifest["build"], "status input_sha256 files")
        require(manifest["build"]["status"] == "strict-build-link-http-verified", "unsupported build status")
        require(manifest["build"]["input_sha256"] == build_input(manifest), "stale generated site; rebuild in a fresh run")
        files = manifest["build"]["files"]
        require(isinstance(files, list) and {"mkdocs.yml", "docs/index.md", "docs/reference/inventory.md", "site/index.html"} <= set(files),
                "partial required build artifacts")
        require(required_rendered_pages(manifest) <= set(files), "partial required rendered pages")
        registered.update(files)
    require(set(manifest["artifacts"]) == registered, "unregistered required artifact")
    if source_check:
        check_source(manifest)
    return manifest


def build_input(manifest):
    return digest(encoded({k: v for k, v in manifest["artifacts"].items()
                          if k == "inventory.json" or k.startswith(("requests/", "answers/"))}))


def init(args):
    source = identity(args.repo)
    root = no_symlinks(args.out)
    check_output_location(root, source)
    require(args.max_calls >= 0 and math.isfinite(args.max_wall_seconds) and args.max_wall_seconds >= 0,
            "invalid budget")
    if root.exists() and any(root.iterdir()):
        require((root / "manifest.json").is_file(), "refusing non-empty output directory")
        with locked(root):
            manifest = load_registry(root)
            require(manifest["source"] == source, "resume source mismatch")
            require(manifest["budgets"]["max_calls"] == args.max_calls and
                    manifest["budgets"]["max_wall_seconds"] == args.max_wall_seconds, "resume budget mismatch")
        return {"status": "resumed", "source_commit": source["commit"], "out": str(root)}
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with locked(root):
        require(set(p.name for p in root.iterdir()) == {".lock"}, "output changed during init")
        manifest = {"schema_version": VERSION, "source": source,
                    "budgets": {"max_calls": args.max_calls, "max_wall_seconds": args.max_wall_seconds,
                                "calls_reserved": 0, "wall_seconds_reserved": 0.0},
                    "questions": {}, "artifacts": {}, "receipts": [], "build": None}
        put(root, manifest, "inventory.json", encoded(inventory(source, tree(source))))
        check_source(manifest)
        receipt(root, manifest, "init", {"source_commit": source["commit"]})
        check_source(manifest)
    return {"status": "initialised", "source_commit": source["commit"], "out": str(root)}


def accept_value(root, manifest, qid, answer):
    require(qid in manifest["questions"], "unknown question ID")
    item = manifest["questions"][qid]
    request = load_json(bounded_read(root / item["request"]))
    envelope = {"answer": answer, "validation": validate_answer(answer, request, manifest["source"], tree(manifest["source"]))}
    name = f"answers/{qid}.json"
    if item["answer"] is not None:
        require(load_json(bounded_read(root / name)) == envelope, "accepted answers are immutable; use a new question ID")
        return {"status": "resumed", "answer": str(root / name), "semantic_status": "unreviewed"}
    require(manifest["build"] is None, "built registry is immutable; create a fresh output for more questions")
    check_source(manifest)
    put(root, manifest, name, encoded(envelope))
    item["answer"] = name
    receipt(root, manifest, "answer-accepted", {"id": qid, "semantic_status": "unreviewed"})
    return {"status": "accepted", "answer": str(root / name), "semantic_status": "unreviewed"}


def bounded_process(command, request, timeout, cwd):
    """Bound both pipe directions and kill descendants on timeout or overflow."""
    start = time.monotonic()
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            cwd=cwd, start_new_session=True)
    output = bytearray()
    sent = 0
    total = 0
    selector = selectors.DefaultSelector()
    assert proc.stdin is not None and proc.stdout is not None and proc.stderr is not None
    streams = (proc.stdin, proc.stdout, proc.stderr)
    for stream, event in ((proc.stdin, selectors.EVENT_WRITE), (proc.stdout, selectors.EVENT_READ),
                          (proc.stderr, selectors.EVENT_READ)):
        os.set_blocking(stream.fileno(), False)
        selector.register(stream.fileno(), event, stream)
    try:
        while selector.get_map():
            left = timeout - (time.monotonic() - start)
            require(left > 0, "adapter timeout")
            for key, mask in selector.select(min(left, 0.1)):
                stream = key.data
                if mask == selectors.EVENT_WRITE:
                    try:
                        sent += os.write(stream.fileno(), request[sent:sent + 65536])
                    except BrokenPipeError:
                        sent = len(request)
                    if sent == len(request):
                        selector.unregister(stream)
                        stream.close()
                else:
                    chunk = os.read(stream.fileno(), 65536)
                    if not chunk:
                        selector.unregister(stream)
                        stream.close()
                        continue
                    total += len(chunk)
                    require(total <= MAX_BYTES, "adapter output exceeds byte limit")
                    if stream is proc.stdout:
                        output.extend(chunk)
        require(proc.wait(timeout=max(0.001, timeout - (time.monotonic() - start))) == 0,
                "adapter exited unsuccessfully")
        return bytes(output)
    finally:
        selector.close()
        # Descendants may have closed their pipes but must not survive an invocation.
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        for stream in streams:
            stream.close()


def question(root, manifest, args):
    require(SLUG.fullmatch(args.id), "invalid question ID")
    text(args.question, "question")
    text(args.model, "selected model", 200)
    require(math.isfinite(args.timeout) and args.timeout > 0, "invalid timeout")
    request = request_for(manifest, args.id, args.question, args.model)
    name = f"requests/{args.id}.json"
    if args.id in manifest["questions"]:
        require(load_json(bounded_read(root / name)) == request, "question/model conflicts with saved request")
    else:
        require(manifest["build"] is None, "built registry is immutable; create a fresh output for more questions")
        check_source(manifest)
        put(root, manifest, name, encoded(request))
        manifest["questions"][args.id] = {"request": name, "answer": None}
        receipt(root, manifest, "question-created", {"id": args.id})
    if not args.runner_json or manifest["questions"][args.id]["answer"] is not None:
        return {"status": "request-ready", "request": str(root / name),
                "answer": manifest["questions"][args.id]["answer"]}
    command = load_json(args.runner_json)
    require(isinstance(command, list) and command and all(isinstance(x, str) and x and "\0" not in x for x in command),
            "runner-json must be a non-empty argv array")
    budget = manifest["budgets"]
    require(budget["calls_reserved"] < budget["max_calls"], "cumulative call budget exhausted")
    require(budget["wall_seconds_reserved"] + args.timeout <= budget["max_wall_seconds"],
            "cumulative wall-time budget exhausted (timeout must fit remaining allowance)")
    budget["calls_reserved"] += 1
    budget["wall_seconds_reserved"] += args.timeout
    call = budget["calls_reserved"]
    receipt(root, manifest, "adapter-reserved", {"id": args.id, "call": call, "timeout_seconds": args.timeout,
                                               "selected_model": args.model})
    start = time.monotonic()
    try:
        raw = bounded_process(command, encoded(request), args.timeout, manifest["source"]["repo"])
        answer = load_json(raw)
        validate_answer(answer, request, manifest["source"], tree(manifest["source"]))
        check_source(manifest)
    except (Refusal, OSError, subprocess.SubprocessError) as exc:
        elapsed = time.monotonic() - start
        budget["wall_seconds_reserved"] += elapsed - args.timeout
        receipt(root, manifest, "adapter-failed", {"id": args.id, "call": call,
                "elapsed_seconds": elapsed, "reason": str(exc) if isinstance(exc, Refusal) else type(exc).__name__})
        raise Refusal("adapter failed; reservation retained: " + (str(exc) if isinstance(exc, Refusal) else type(exc).__name__)) from exc
    elapsed = time.monotonic() - start
    budget["wall_seconds_reserved"] += elapsed - args.timeout
    receipt(root, manifest, "adapter-succeeded", {"id": args.id, "call": call, "elapsed_seconds": elapsed,
                                               "actual_model": answer["model"]})
    return accept_value(root, manifest, args.id, answer)


def freshness(root, manifest, args):
    target = identity(args.repo)
    git(target["repo"], "cat-file", "-e", manifest["source"]["commit"] + "^{commit}")
    before = tree(target, manifest["source"]["commit"])
    after = tree(target)
    cited, dependencies, watched = set(), set(), set()
    for item in manifest["questions"].values():
        if item["answer"]:
            envelope = load_json(bounded_read(root / item["answer"]))
            cited.update(envelope["validation"]["cited_paths"])
            dependencies.update(envelope["answer"]["dependency_paths"])
            watched.update(envelope["answer"]["watch_paths"])
    changes = []
    for path in sorted(set(before) | set(after)):
        if before.get(path) == after.get(path):
            continue
        reasons = []
        if path in cited:
            reasons.append("cited")
        if path in dependencies:
            reasons.append("dependency")
        if any(path == watch or path.startswith(watch + "/") for watch in watched):
            reasons.append("watched")
        if (PurePosixPath(path).suffix.lower() in {".json", ".toml", ".yaml", ".yml", ".xml", ".ini", ".config", ".csproj", ".props", ".targets"}
                or "config" in path.lower() or excluded(path)):
            reasons.append("configuration-or-operational")
        change = "added" if path not in before else "deleted" if path not in after else "modified"
        if change != "modified":
            reasons.append(change)
        if not reasons:
            reasons.append("unknown-impact")
        changes.append({"path": path, "change": change, "reasons": reasons})
    require(identity(args.repo) == target, "target source moved during freshness comparison")
    check_source(manifest)
    result = {"status": "needs-review" if changes else "unchanged", "baseline_commit": manifest["source"]["commit"],
              "target_commit": target["commit"], "changes": changes, "baseline_advanced": False}
    receipt(root, manifest, "freshness", result)
    return result


def prose(value):
    # Treat agent-authored text as text, never executable HTML or Markdown links.
    return html.escape(value).replace("\n", " ").replace("\\", "\\\\").translate(
        str.maketrans({c: "\\" + c for c in "`*_{}[]()#!|"}))


def pages(root, manifest):
    inv = load_json(bounded_read(root / "inventory.json"))
    answer_nav = []
    files = {"docs/reference/inventory.md": "# Mechanical project inventory\n\nPaths and hashes only; not architectural understanding.\n\n" +
             "\n".join(f"- {prose(p['path'])} — {p['kind']} — SHA-256 `{p['sha256']}`" for p in inv["projects"]) + "\n"}
    index = ["# Bounded source-grounded answers", "",
             "Source commit: `" + manifest["source"]["commit"] + "`.", "",
             "Citation spans are mechanically checked. Semantic support is **unreviewed**. This is not an exhaustive audit or runtime certification.", "",
             "Human-owned handbook material stays outside this generated package.", "",
             "[Mechanical project inventory](reference/inventory.md)", "", "## Questions", ""]
    for qid, item in sorted(manifest["questions"].items()):
        request = load_json(bounded_read(root / item["request"]))
        if not item["answer"]:
            index.append("- " + prose(request["question"]) + " — awaiting an accepted answer")
            continue
        answer = load_json(bounded_read(root / item["answer"]))["answer"]
        lines = ["# " + prose(request["question"]), "", "Semantic status: **unreviewed**. Citation validity is not semantic correctness.", "",
                 "Source commit: `" + answer["source_commit"] + "`.", "",
                 "Actual model: " + prose(answer["model"]) + ". Agent: " + prose(answer["agent"]) + ".", "", "## Code-derived claims", ""]
        for claim in answer["code_claims"]:
            lines.extend([prose(claim["text"]), ""])
            for citation in claim["citations"]:
                lines.extend([prose(citation["path"]) + f" lines {citation['start_line']}–{citation['end_line']}", "",
                              "<pre><code>" + html.escape(citation["quote"]) + "</code></pre>", ""])
        lines.extend(["## Attributed human intent", ""])
        for intent in answer["human_intent"]:
            lines.extend(["- " + prose(intent["text"]) + " — attribution: " + prose(intent["attribution"]), ""])
        for field, title in (("runtime_unknowns", "Runtime unknowns"), ("gaps", "Gaps")):
            lines.extend(["## " + title, "", *["- " + prose(value) for value in answer[field]], ""])
        files[f"docs/answers/{qid}.md"] = "\n".join(lines) + "\n"
        answer_nav.append({qid: f"answers/{qid}.md"})
        index.append(f"- [{qid}](answers/{qid}.md) — " + prose(request["question"]))
    files["docs/index.md"] = "\n".join(index) + "\n"
    config = {"site_name": "Bounded source-grounded answers", "docs_dir": "docs", "site_dir": "site", "use_directory_urls": True,
              "theme": {"name": "material", "font": False}, "plugins": [],
              "nav": [{"Overview": "index.md"}, {"Reference": "reference/inventory.md"}] +
                     ([{"Answers": answer_nav}] if answer_nav else [])}
    files["mkdocs.yml"] = encoded(config).decode()
    return files


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.add(attrs["id"])
        for field in ("href", "src"):
            if attrs.get(field):
                self.links.append(attrs[field])


def smoke(site):
    parsed = {}
    for path in site.rglob("*.html"):
        parser = Links()
        parser.feed(path.read_text(encoding="utf-8"))
        parsed[path] = parser
    count = 0
    for page, parser in parsed.items():
        for link in parser.links:
            url = urllib.parse.urlsplit(link)
            if url.scheme or url.netloc:
                continue
            target = (site / urllib.parse.unquote(url.path).lstrip("/") if url.path.startswith("/") else
                      page.parent / urllib.parse.unquote(url.path)) if url.path else page
            target = target.resolve()
            require(target.is_relative_to(site.resolve()), "generated link escapes site")
            if target.is_dir():
                target /= "index.html"
            require(target.is_file(), "broken local link: " + link)
            if url.fragment and target in parsed:
                require(urllib.parse.unquote(url.fragment) in parsed[target].ids, "broken local fragment: " + link)
            count += 1
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(site), **kwargs)

        def log_message(self, format, *args):
            pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for page in parsed:
            url = "http://127.0.0.1:" + str(server.server_port) + "/" + urllib.parse.quote(page.relative_to(site).as_posix())
            with opener.open(url, timeout=5) as response:
                require(response.status == 200 and response.read() == page.read_bytes(), "HTTP smoke mismatch")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    return {"html_pages": len(parsed), "local_links_checked": count, "http_pages_checked": len(parsed)}


def required_rendered_pages(manifest):
    return {"site/index.html", "site/reference/inventory/index.html"} | {
        f"site/answers/{qid}/index.html" for qid, item in manifest["questions"].items() if item["answer"]}


def preflight_stage(stage, manifest):
    entries = sorted(stage.rglob("*"))
    for path in entries:
        no_symlinks(path)
        require(path.is_file() or path.is_dir(), "nonregular staged output")
        if path.is_file():
            require(path.stat().st_nlink == 1, "hardlinked staged output refused")
    for name in required_rendered_pages(manifest):
        require((stage / name).is_file(), "missing required rendered page: " + name)
    return entries


def build(root, manifest, args):
    if manifest["build"] is not None:
        result = smoke(root / "site")
        check_source(manifest)
        return {"status": "resumed", "site": str(root / "site"), **result}
    with tempfile.TemporaryDirectory(prefix="grounded-build-", dir=root.parent) as directory:
        stage = Path(directory)
        for name, value in pages(root, manifest).items():
            atomic(stage / name, value.encode())
        bounded_process([args.mkdocs, "build", "--strict", "--config-file", str(stage / "mkdocs.yml")], b"", 120, stage)
        entries = preflight_stage(stage, manifest)
        result = smoke(stage / "site")
        check_source(manifest)
        files = []
        for path in entries:
            no_symlinks(path)
            if path.is_file():
                name = path.relative_to(stage).as_posix()
                put(root, manifest, name, path.read_bytes())
                files.append(name)
        manifest["build"] = {"status": "strict-build-link-http-verified", "input_sha256": build_input(manifest), "files": files}
        receipt(root, manifest, "build", result)
    return {"status": "built", "site": str(root / "site"), **result}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("init", "question", "accept", "verify", "freshness", "build"):
        command = commands.add_parser(name)
        command.add_argument("--out", required=True, type=Path)
        if name in {"init", "freshness"}:
            command.add_argument("--repo", required=True, type=Path)
        if name == "init":
            command.add_argument("--max-calls", type=int, default=10)
            command.add_argument("--max-wall-seconds", type=float, default=600)
        if name in {"question", "accept"}:
            command.add_argument("--id", required=True)
        if name == "question":
            command.add_argument("--question", required=True)
            command.add_argument("--model", default="unknown")
            command.add_argument("--runner-json")
            command.add_argument("--timeout", type=float, default=60)
        if name == "accept":
            command.add_argument("--answer", required=True, type=Path)
        if name == "build":
            command.add_argument("--mkdocs", default="mkdocs")
    args = parser.parse_args(argv)
    os.umask(0o077)
    try:
        if args.command == "init":
            result = init(args)
        else:
            root = no_symlinks(args.out)
            require(root.is_dir() and (root / "manifest.json").is_file(), "not a grounded output directory")
            with locked(root):
                manifest = load_registry(root)
                if args.command == "verify":
                    result = {"status": "verified", "source_commit": manifest["source"]["commit"],
                              "questions": len(manifest["questions"]),
                              "answers": sum(item["answer"] is not None for item in manifest["questions"].values()),
                              "artifacts": len(manifest["artifacts"]), "semantic_status": "unreviewed"}
                elif args.command == "accept":
                    result = accept_value(root, manifest, args.id, load_json(bounded_read(args.answer)))
                else:
                    result = globals()[args.command](root, manifest, args)
                check_source(manifest)
        print(encoded(result).decode(), end="")
        return 0
    except (Refusal, OSError, UnicodeError, KeyError, TypeError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps({"status": "error", "error": str(exc)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
