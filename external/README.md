# External inference protocol v1

`review external` lets a calling assistant answer the same narrow jobs used by
ordinary review. The existing CLI and provider selection remain the default.
External preparation never selects or invokes an inference provider. Language
readers and repository analysers still run as they do during ordinary review.

```sh
review external prepare --repo '/absolute/repository path' --jobs tests,namer
review external submit --repo '/absolute/repository path' < submission.json
review external report --repo '/absolute/repository path' --run RUN_ID
```

`prepare` accepts optional `--rev REV` and `--jobs LIST`. Omit `--repo` to use the
current repository. Flags belong after the external action. `submit` reads one
bounded JSON object from stdin; it does not accept a results-file path. Each
successful command prints one JSON object. Errors print `{"error":"..."}` to
stdout, a diagnostic to stderr, and exit 2. A successful protocol operation exits
0 even when its report is incomplete or contains findings.

The result has these fields:

- `version`: `1`.
- `run_id`, `source_id`, `repo`: the run, its source identity, and canonical Git root.
- `jobs`: pending packets, each with `job_id`, `schema`, `system`, `user` and `verdict_count`.
- `report`: the existing v1 review contract, including findings, retractions,
  dismissals, stable IDs, coverage, failures, skipped jobs and status.

Give the assistant each packet's exact `system` and `user` text. They contain the
existing instructions, criteria and bounded evidence. Send its JSON answer as a
**string**, alongside the exact identifiers from that packet and run:

```json
{
  "version": 1,
  "run_id": "COPY_FROM_PREPARE",
  "source_id": "COPY_FROM_PREPARE",
  "job_id": "COPY_FROM_PACKET",
  "schema": "review.findings.v1",
  "answer": "{\"findings\":[]}"
}
```

First readings use `review.findings.v1`. Findings require `rule`, `severity`
(`must-fix`, `consider`, or `note`) and `message`; optional fields are `file`,
`line`, `symbol`, and `fix`. A file must belong to the reviewed change. Rule IDs
must belong to that packet’s existing job criteria.

Findings above note severity generate `review.verdicts.v1` packets containing the
same evidence and numbered findings. Answer with
`{"verdicts":[{"index":0,"holds":true,"reason":"..."}]}` (encoded as the
submission's answer string). Every numbered finding needs exactly one verdict.
A false verdict retracts its finding. Accepted first readings do not complete a
run while verification remains pending. Process the newly returned `jobs` until
none remain. Only `report.status == "complete"` establishes complete coverage;
uncovered files or truncated source keep it incomplete even with no pending jobs.
An empty change has status `empty`.

Malformed JSON, duplicate keys, wrong schemas, unknown jobs, missing verdicts,
conflicting retries, wrong repositories and changed source are rejected before
saved state changes. A byte-identical accepted answer can be retried. Source
identity includes HEAD, the index, resolved revision endpoints and tracked
working-file content, plus Git-visible nonignored untracked files. Staged and bare-revision reviews retain the ordinary
engine's working-tree reading behavior. Even an unrelated visible source edit requires
a new preparation. Run identity also binds packet IDs, so answers cannot move
between preparations of identical source. Sessions also record the executable’s
SHA-256 digest and become invalid after a binary change, including development
builds with an unknown commit. Executable fingerprinting is bounded to 128 MiB.

One active session per repository is saved in the user's cache under
`review/external-v1/`. Preparing again replaces that repository's previous run.
Each repository uses one bounded state file and a persistent OS lock file; a
transient atomic-write file may remain after abrupt termination. The OS releases
locks on process death. Session data has owner-only permissions and is separate
from the ordinary provider answer cache. External answers never enter that cache.
Remove the repository's cache files when no session is active to discard its data.

Limits are 8 MiB per session and source file, 64 MiB of source,
256 pending packets, 256 KiB per prompt and answer, 256 findings per answer, and
32 levels of JSON nesting. CLI submission envelopes are also limited to 256 KiB,
including JSON escaping. Preparation fails explicitly when export limits are
exceeded. This version exposes no baseline-file or commit-message-file input;
ordinary review retains those options. Compiler/toolchain and dependency changes
outside the repository, including ignored dependency caches, are not fingerprinted;
this is a source snapshot rather than a hermetic build environment. Initialized,
clean submodules are supported: source identity includes their actual HEAD, and
tracked or visible untracked changes reject the operation. Uninitialized or nested
submodules are unsupported and reject preparation.

The reusable Odin API is `external.prepare(Options)`,
`external.submit(repo, Submission)` and `external.inspect(repo, run_id)`.
Each returns `(View, error_string)` and accepts an optional trailing allocator.
Long-lived hosts must call `external.capture_engine(allocator)` at startup, before
accepting work; its nonempty error aborts startup. This freezes the process identity
if the executable is later replaced on disk. Short-lived callers capture it lazily.
Callers must discard the view when the error string is nonempty. The engine uses
an optional `reviewer.Reviewer.exchange` callback and serial scheduling to replay
session answers and export pending asks; decoding, verification, filtering and
report generation remain in the existing packages.
