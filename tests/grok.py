"""Offline Grok structured-output contracts; run: python3 tests/grok.py build/review."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="review grok ") as tmp:
    root = Path(tmp)
    repo = root / "repo"
    repo.mkdir()
    def git(*args):
        subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True)
    git("init", "-q")
    git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "initial")
    (repo / "x.go").write_text("package x\n// Unix accepts only ASCII file names.\nfunc X() {}\n")
    git("add", "x.go")
    fake = root / "grok"
    record = root / "calls.jsonl"
    fake.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
schema = json.loads(args[args.index('--json-schema') + 1])
assert schema['type'] == 'object' and schema['additionalProperties'] is False
key, = schema['required']
assert key in ('findings', 'verdicts')
assert schema['properties'][key]['type'] == 'array'
assert '--no-subagents' in args and '--disable-web-search' in args
assert args[args.index('--tools') + 1] == 'todo_write'
assert 'todo_write' in args[args.index('--disallowed-tools') + 1].split(',')
assert os.environ['GROK_MEMORY'] == '0'
with open(os.environ['REVIEW_TEST_GROK_CALLS'], 'a') as f:
    f.write(json.dumps({'key': key, 'prompt': Path(args[args.index('--prompt-file') + 1]).read_text()}) + '\\n')
answer = {'findings': [{'rule':'unsupported-claim', 'severity':'must-fix', 'file':'x.go', 'line':2, 'symbol':'X', 'message':'unsupported', 'fix':'cite'}]} if key == 'findings' else {'verdicts':[{'index':0,'holds':False,'reason':'regression verification'}]}
print(json.dumps({'text':'I will check those findings.', 'structuredOutput':answer, 'stopReason':'end_turn'}))
""")
    fake.chmod(0o755)
    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"], REVIEW_TEST_GROK_CALLS=str(record))
    result = subprocess.run([str(binary), "--repo", str(repo), "--json", "--provider", "grok", "--jobs", "claims", "--fresh"], env=env, capture_output=True, text=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    report = json.loads(result.stdout)
    assert report["status"] == "complete" and report["failed"] == [], report
    assert len(report["retracted"]) == 1 and report["retracted"][0]["reason"] == "regression verification", report
    calls = [json.loads(line) for line in record.read_text().splitlines()]
    assert [c["key"] for c in calls] == ["findings", "verdicts"], calls
    assert "Unix accepts" in calls[0]["prompt"] and "unsupported" in calls[1]["prompt"]
print("ok Grok findings and verdict schema selection, isolation and decoding")
