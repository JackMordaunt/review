"""Offline CLI contract tests; run: python3 tests/cli.py build/review."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()


def run(*args, cwd, env=None, code=0):
    p = subprocess.run([str(binary), *args], cwd=cwd, env=env, capture_output=True, text=True)
    assert p.returncode == code, (args, p.returncode, p.stderr, p.stdout)
    return json.loads(p.stdout), p


with tempfile.TemporaryDirectory(prefix="review cli ") as tmp:
    root = Path(tmp)
    repo = root / "repo with spaces"
    repo.mkdir()
    def git(*args):
        subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)
    git("init", "-q")
    git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "initial")
    report, _ = run("--repo", str(repo), "--json", cwd=root)
    assert report["status"] == "empty" and report["version"] == 1
    for args, code, kind in [
        (("--bad", "--json"), 2, "arguments"),
        (("--repo", "--json"), 2, "arguments"),
        (("--json", "--model"), 2, "arguments"),
        (("--json",), 2, "repository"),
        (("--repo", str(repo), "--json", "bad-revision"), 1, "revision"),
        (("--repo", str(repo), "--json", "--message-file", str(root / "missing-message")), 1, "message"),
    ]:
        report, _ = run(*args, cwd=root, code=code)
        assert report["status"] == "error" and report["kind"] == kind
    help_result = subprocess.run([str(binary), "--help"], cwd=root, capture_output=True, text=True)
    assert help_result.returncode == 2 and "usage: review" in help_result.stdout and not help_result.stderr
    hook_result = subprocess.run([str(binary), "hook"], cwd=root, capture_output=True, text=True)
    assert hook_result.returncode == 0 and "--message-file" in hook_result.stdout
    (repo / "readme.txt").write_text("hello\n")
    git("add", "readme.txt")
    report, p = run("--repo", str(repo), "--json", "--verbose", "--provider", "unknown", cwd=root, code=1)
    assert report["kind"] == "provider" and "reviewing" in p.stderr
    env = dict(os.environ, REVIEW_COMMAND='printf {"findings":[]}', ANTHROPIC_API_KEY="test-secret-never-print")
    args = ("--repo", str(repo), "--json", "--provider", "command", "--fresh", "--no-verify", "--verbose")
    report, p = run(*args, cwd=root, env=env)
    assert report["version"] == 1 and "findings" in report and "asking" in p.stderr
    assert report["failed"] == [], report
    report, _ = run(*args, "--baseline", str(root / "missing.json"), cwd=root, env=env, code=1)
    assert report["kind"] == "baseline"
    (repo / "subdirectory").mkdir()
    report, _ = run("doctor", "--repo", str(repo / "subdirectory"), "--json", cwd=root, env=env)
    assert report["repository"] == str(repo) and report["repository_available"]
    assert report["api_credential_present"] and not report["authentication_verified"]
    assert "test-secret-never-print" not in json.dumps(report)
    # A copied installation finds its shipped tools with no installation directory on PATH.
    install = root / "installation"
    install.mkdir()
    shutil.copy2(binary, install / "review")
    binary = install / "review"
    first = root / "first"
    second = root / "second"
    first.mkdir()
    second.mkdir()
    for directory in (install, first, second):
        for name in ("review-go", "review-vet", "odin-review-extract"):
            tool = directory / name
            tool.write_text("#!/bin/sh\nexit 0\n")
            tool.chmod(0o755 if directory != first else 0o644)
    env["PATH"] = os.pathsep.join((str(first), str(second), os.environ["PATH"]))
    report, _ = run("doctor", "--json", cwd=root, env=env)
    tools = {t["name"]: t for t in report["tools"]}
    assert tools["review-go"]["path"] == str(install / "review-go")
    (install / "review-go").chmod(0o644)
    report, _ = run("doctor", "--json", cwd=root, env=env)
    tools = {t["name"]: t for t in report["tools"]}
    assert tools["review-go"]["path"] == str(second / "review-go")
print("ok CLI JSON, explicit repository, diagnostics and executable discovery")
