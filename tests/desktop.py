#!/usr/bin/env python3
"""Black-box MCP acceptance tests. Run: python3 tests/desktop.py --binary build/review.

Uses only Python's standard library and Git. It never launches a Desktop UI or
establishes UI compatibility. Inference is supplied as fixture JSON answers.
Validated on Linux; the slow-analyzer test requires POSIX.
"""
import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time
import unittest


class Session:
    def __init__(self, binary, repo, environment):
        self.process = subprocess.Popen(
            [str(binary), "mcp", "--repo", str(repo)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment,
        )
        self.lines = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, timeout=10):
        line = self.lines.get(timeout=timeout)
        if line is None:
            raise AssertionError("server closed stdout unexpectedly")
        return json.loads(line)

    def request(self, identifier, method, params=None):
        message = {"jsonrpc": "2.0", "id": identifier, "method": method}
        if params is not None:
            message["params"] = params
        self.send(message)
        response = self.receive()
        assert response["jsonrpc"] == "2.0" and response["id"] == identifier, response
        return response

    def initialize(self, version="2025-11-25"):
        response = self.request("initialize", "initialize", {
            "protocolVersion": version, "capabilities": {},
            "clientInfo": {"name": "review-acceptance", "version": "1"},
        })
        assert response["result"]["protocolVersion"] == "2025-11-25", response
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def tool(self, identifier, name, arguments):
        return self.request(identifier, "tools/call", {"name": name, "arguments": arguments})

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
                raise AssertionError("server did not exit within 3 seconds after EOF")
        self.reader.join(timeout=3)
        stderr = self.process.stderr.read().decode(errors="replace")
        self.process.stdout.close()
        self.process.stderr.close()
        return self.process.returncode, stderr


class DesktopProtocol(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="review desktop ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = {
            k: v for k, v in os.environ.items()
            if not k.startswith("REVIEW_") and not any(word in k for word in ("KEY", "TOKEN", "SECRET"))
        }
        # Keep Git and system tools, while excluding user provider CLIs.
        if os.name == "posix":
            self.environment["PATH"] = "/usr/bin:/bin"
        for name in ("home", "cache", "config", "state"):
            (self.root / name).mkdir()
        self.environment.update(HOME=str(self.root / "home"),
                                USERPROFILE=str(self.root / "home"),
                                XDG_CACHE_HOME=str(self.root / "cache"),
                                XDG_CONFIG_HOME=str(self.root / "config"),
                                XDG_STATE_HOME=str(self.root / "state"),
                                GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
            self.environment.pop(name, None)
        self.repo = self.fixture("repository with spaces")
        self.sessions = []
        self.addCleanup(self.close_sessions)

    def git(self, repo, *arguments):
        return subprocess.run(
            ["git", "-C", str(repo), *arguments], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.environment,
        )

    def fixture(self, name):
        repo = self.root / name
        repo.mkdir()
        self.git(repo, "init", "-q")
        (repo / "test.md").write_text("# Before\n")
        self.git(repo, "add", ".")
        self.commit(repo, "docs: create fixture")
        (repo / "test.md").write_text("# After\n")
        self.git(repo, "add", ".")
        self.commit(repo, "docs: change fixture")
        return repo

    def commit(self, repo, subject):
        self.git(repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "-c", "core.hooksPath=" + os.devnull, "commit", "-qm", subject)

    def start(self, repo=None, environment=None):
        session = Session(BINARY, repo or self.repo, environment or self.environment)
        self.sessions.append(session)
        return session

    def close_sessions(self):
        for session in self.sessions:
            if session.process.stderr.closed:
                continue
            code, stderr = session.close()
            self.assertEqual(code, 0, stderr)
            self.assertEqual(stderr, "")

    def prepare(self, session, identifier=1):
        response = session.tool(identifier, "review_prepare", {"rev": "HEAD~1..HEAD", "only": "hygiene"})
        result = response["result"]
        self.assertFalse(result["isError"], result)
        return result["structuredContent"]

    def external(self, action, *arguments, answer=None):
        result = subprocess.run(
            [str(BINARY), "external", action, "--repo", str(self.repo), *arguments],
            input=json.dumps(answer) if answer is not None else None,
            capture_output=True, text=True, env=self.environment, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return json.loads(result.stdout)

    def test_round_trip_and_scope(self):
        session = self.start()
        session.initialize("2099-01-01")
        tools = session.request("list", "tools/list")["result"]["tools"]
        self.assertEqual([x["name"] for x in tools], ["review_prepare", "review_submit", "review_report"])
        view = self.prepare(session)
        self.assertEqual(Path(view["repo"]).resolve(), self.repo.resolve())
        self.assertTrue(view["jobs"], view)
        self.assertEqual(self.external("report", "--run", view["run_id"]), view)
        for index, packet in enumerate(view["jobs"]):
            answer = dict(version=1, run_id=view["run_id"], source_id=view["source_id"],
                          job_id=packet["job_id"], schema=packet["schema"], answer='{"findings":[]}')
            if index == 0:
                accepted_view = self.external("submit", answer=answer)
            else:
                accepted = session.tool(10 + index, "review_submit", answer)["result"]
                self.assertFalse(accepted["isError"], accepted)
                accepted_view = accepted["structuredContent"]
            self.assertEqual(accepted_view["jobs"], [])
        report = session.tool("report", "review_report", {"run_id": view["run_id"]})["result"]
        self.assertFalse(report["isError"], report)
        self.assertEqual(report["structuredContent"]["report"]["status"], "complete")
        self.assertEqual(self.external("report", "--run", view["run_id"]), report["structuredContent"])
        other = self.start(self.fixture("other repository"))
        other.initialize()
        rejected = other.tool("cross-repo", "review_report", {"run_id": view["run_id"]})["result"]
        self.assertTrue(rejected["isError"], rejected)
        (self.repo / "test.md").write_text("# Changed after prepare\n")
        stale = session.tool("stale", "review_report", {"run_id": view["run_id"]})["result"]
        self.assertTrue(stale["isError"], stale)

    def test_errors_ids_and_notifications(self):
        session = self.start()
        self.assertEqual(session.request("modern", "server/discover")["error"]["code"], -32601)
        self.assertEqual(session.request(1, "tools/list")["error"]["code"], -32000)
        session.initialize()
        for identifier in ["text-id", 9223372036854775807, -9223372036854775808]:
            response = session.request(identifier, "ping")
            self.assertEqual(response["result"], {})
        session.send({"jsonrpc": "2.0", "method": "unknown-notification"})
        self.assertEqual(session.request("after-notification", "ping")["result"], {})
        self.assertEqual(session.tool("invalid", "review_prepare", {"repo": "/tmp"})["error"]["code"], -32602)
        for raw in [b"{\n", b'{"x":1,}\n', b'{"x":1} trailing\n', b"[]\n"]:
            session.process.stdin.write(raw)
            session.process.stdin.flush()
            self.assertIn(session.receive()["error"]["code"], (-32700, -32600))
        unknown = session.tool("unknown", "review_report", {"run_id": "unknown"})["result"]
        self.assertTrue(unknown["isError"], unknown)

    def test_invalid_submissions_preserve_pending_work(self):
        session = self.start()
        session.initialize()
        view = self.prepare(session)
        packet = view["jobs"][0]
        answer = dict(version=1, run_id=view["run_id"], source_id=view["source_id"],
                      job_id=packet["job_id"], schema=packet["schema"], answer='{"findings":[]}')
        for field, value in [("run_id", "unknown"), ("source_id", "wrong"),
                             ("job_id", "wrong"), ("schema", "wrong"), ("answer", "{}")]:
            rejected = session.tool("bad-" + field, "review_submit", dict(answer, **{field: value}))["result"]
            self.assertTrue(rejected["isError"], rejected)
        pending = session.tool("pending", "review_report", {"run_id": view["run_id"]})["result"]
        self.assertEqual(pending["structuredContent"], view)
        self.assertEqual(pending["structuredContent"]["report"]["status"], "incomplete")
        accepted = session.tool("valid", "review_submit", answer)["result"]
        self.assertFalse(accepted["isError"], accepted)

    def test_verification_remains_pending_until_valid_verdicts(self):
        session = self.start()
        session.initialize()
        view = self.prepare(session)
        packet = view["jobs"][0]
        finding = {"rule": "message-claims-more", "severity": "consider", "file": "test.md", "line": 1,
                   "symbol": "", "message": "Synthetic protocol fixture", "fix": "Fixture fix"}
        submission = dict(version=1, run_id=view["run_id"], source_id=view["source_id"],
                          job_id=packet["job_id"], schema=packet["schema"],
                          answer=json.dumps({"findings": [finding]}))
        first = session.tool("first-pass", "review_submit", submission)["result"]
        self.assertFalse(first["isError"], first)
        pending = first["structuredContent"]
        self.assertEqual(pending["report"]["status"], "incomplete")
        self.assertEqual(len(pending["jobs"]), 1)
        verification = pending["jobs"][0]
        self.assertEqual(verification["schema"], "review.verdicts.v1")
        self.assertEqual(verification["verdict_count"], 1)
        verdict = dict(submission, job_id=verification["job_id"], schema=verification["schema"],
                       answer='{"verdicts":[]}')
        rejected = session.tool("missing-verdict", "review_submit", verdict)["result"]
        self.assertTrue(rejected["isError"], rejected)
        verdict["answer"] = json.dumps({"verdicts": [{"index": 0, "holds": False,
                                                     "reason": "Synthetic fixture retraction"}]})
        final = session.tool("verified", "review_submit", verdict)["result"]
        self.assertFalse(final["isError"], final)
        complete = final["structuredContent"]
        self.assertEqual(complete["jobs"], [])
        self.assertEqual(complete["report"]["status"], "complete")
        self.assertEqual(complete["report"]["findings"], [])
        self.assertEqual(len(complete["report"]["retracted"]), 1)
        retraction = complete["report"]["retracted"][0]
        self.assertEqual(retraction["reason"], "Synthetic fixture retraction")
        self.assertEqual({key: retraction["finding"].get(key, "") for key in finding}, finding)

    def test_startup_errors_and_debug_stdout(self):
        for arguments, diagnostic in [
            ([], b"usage: review mcp --repo <absolute-repository-path>"),
            (["--repo", "relative"], b"review mcp: expected --repo /absolute/git/repository"),
            (["--repo", str(self.root / "missing")], b"review mcp: repository unavailable:"),
        ]:
            result = subprocess.run([str(BINARY), "mcp", *arguments], capture_output=True,
                                    env=self.environment, timeout=3)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, b"")
            self.assertIn(diagnostic, result.stderr)
        environment = dict(self.environment, REVIEW_DEBUG_ALLOC="1")
        session = self.start(environment=environment)
        self.assertEqual(session.request("debug", "ping")["result"], {})
        self.assertEqual(session.close(), (0, ""))
        self.assertIsNone(session.lines.get(timeout=1), "unexpected trailing stdout")

    def test_external_cli_debug_stdout_is_one_json_object(self):
        environment = dict(self.environment, REVIEW_DEBUG_ALLOC="1")
        prepared = subprocess.run(
            [str(BINARY), "external", "prepare", "--repo", str(self.repo)],
            capture_output=True, env=environment, timeout=10,
        )
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode(errors="replace"))
        view = json.loads(prepared.stdout)
        self.assertEqual(Path(view["repo"]).resolve(), self.repo.resolve())
        self.assertEqual(view["jobs"], [])
        self.assertEqual(view["report"]["status"], "empty")
        self.assertEqual(prepared.stderr, b"")
        reported = subprocess.run(
            [str(BINARY), "external", "report", "--repo", str(self.repo), "--run", view["run_id"]],
            capture_output=True, env=environment, timeout=10,
        )
        self.assertEqual(reported.returncode, 0, reported.stderr.decode(errors="replace"))
        self.assertEqual(json.loads(reported.stdout), view)
        self.assertEqual(reported.stderr, b"")

    def test_frame_limits_and_eof(self):
        command = [str(BINARY), "mcp", "--repo", str(self.repo)]
        ping = b'{"jsonrpc":"2.0","id":1,"method":"ping"}'
        for size, code in [(16 * 1024 * 1024, 0), (16 * 1024 * 1024 + 1, 1)]:
            result = subprocess.run(command, input=ping + b" " * (size - len(ping)) + b"\n",
                                    capture_output=True, env=self.environment, timeout=10)
            self.assertEqual(result.returncode, code, result.stderr)
            response = json.loads(result.stdout)
            if code:
                self.assertNotIn("result", response)
                self.assertEqual(response["error"]["code"], -32700)
            else:
                self.assertEqual(response["result"], {})
                self.assertEqual(response["id"], 1)
        session = self.start()
        session.initialize()
        session.send({"jsonrpc": "2.0", "id": "inflight", "method": "tools/call",
                      "params": {"name": "review_prepare", "arguments": {}}})
        self.assertEqual(session.close(), (0, ""))

    @unittest.skipUnless(os.name == "posix", "slow-analyzer fixture uses a POSIX executable")
    def test_cancel_keeps_ping_responsive(self):
        fakebin = self.root / "fakebin"
        fakebin.mkdir()
        marker = self.root / "analyzer-started"
        fake = fakebin / "odin"
        fake.write_text('#!/bin/sh\n: > "$REVIEW_TEST_MARKER"\nsleep 2\nprintf \'{"error_count":0,"errors":[]}\\n\' >&2\n')
        fake.chmod(0o755)
        (self.repo / "fixture.odin").write_text("package fixture\nf :: proc() {}\n")
        self.git(self.repo, "add", ".")
        self.commit(self.repo, "fixture: add source")
        environment = dict(self.environment, PATH=str(fakebin) + ":/usr/bin:/bin",
                           REVIEW_TEST_MARKER=str(marker))
        session = self.start(environment=environment)
        session.initialize()
        session.send({"jsonrpc": "2.0", "id": "slow", "method": "tools/call",
                      "params": {"name": "review_prepare", "arguments": {"rev": "HEAD~1..HEAD", "only": "hygiene"}}})
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(marker.exists(), "prepare did not start the slow analyzer")
        # Envelope rejection must precede the busy-tool shortcut.
        for invalid in [
            {"jsonrpc": "2.0", "id": True},
            {"jsonrpc": "2.0", "id": 1.5},
            {"jsonrpc": "1.0", "id": "bad-version"},
        ]:
            session.send(dict(invalid, method="tools/call",
                              params={"name": "review_prepare", "arguments": {}}))
            rejected = session.receive()
            self.assertEqual(rejected["error"]["code"], -32600)
            self.assertIsNone(rejected["id"])
        session.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": "slow"}})
        started = time.monotonic()
        self.assertEqual(session.request("responsive", "ping")["result"], {})
        self.assertLess(time.monotonic() - started, 1)
        # The underlying check finishes; cancellation suppresses its response.
        with self.assertRaises(queue.Empty):
            session.lines.get(timeout=2.5)
        self.assertEqual(session.request("after-cancel", "ping")["result"], {})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=Path("build/review"))
    options, remaining = parser.parse_known_args()
    BINARY = options.binary.resolve()
    if not BINARY.is_file():
        parser.error("build review first or pass --binary /absolute/path/to/review")
    unittest.main(argv=[__file__, *remaining])
