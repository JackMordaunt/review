# Local assistant review through MCP

Build or install the existing `review` binary. No Node, Python, provider CLI,
API key, or additional server executable is required for this transport.
The assistant connected to the server supplies inference by answering review
jobs. Its subscription does not become server-side API authentication.

The adapter implements the initialization-based MCP revision **2025-11-25**.
It does not implement the handshake-free 2026 revision. Real Claude Desktop UI
compatibility has not been tested; protocol tests do not establish UI acceptance.

Add this entry to your existing Claude Desktop MCP configuration, replacing both
paths with absolute paths on your computer. Merge the entry into any existing
`mcpServers` object, then restart Desktop. This command does not edit your config.

```json
{
  "mcpServers": {
    "review": {
      "command": "/absolute/path/to/review",
      "args": ["mcp", "--repo", "/absolute/path/to/repository"]
    }
  }
}
```

The repository must already exist and be a Git repository. The server resolves
its Git root once at startup. Tool arguments cannot select another repository.
Use a separate server entry for each repository. Repository analyzers retain
review's normal execution policy: selecting a repository does not sandbox its
build commands. Keep the sibling analysis binaries beside `review` as usual.

Ask the connected assistant:

> Use review_prepare for the staged change (or pass the requested revision).
> For every returned job, follow its system and user instructions and produce
> the exact JSON required by its schema. Call review_submit with version 1,
> the returned run_id, source_id, job_id and schema, and the JSON answer encoded
> as a string. Process all newly returned verification jobs the same way.
> For verification, supply exactly the packet's verdict_count verdicts.
> Call review_report and tell me its completion state and findings. Pending
> jobs, faults and missing verification must remain incomplete.

`review_prepare` accepts optional `rev` and comma-separated `only` job names.
`review_submit` accepts the six fields above; its answer is limited to 256 KiB.
`review_report` requires `run_id`. Responses include the engine object in both
`structuredContent` and JSON text content. Engine failures appear as tool errors.
No tool executes a provider or requests sampling from the client.

The [external protocol](../external/README.md) describes source identity,
session limits and accepted answer schemas. Preparing again replaces the
repository's active run. Restart the server after updating the binary, then
prepare a new run.

If the connector does not start, run
`/absolute/path/to/review doctor --repo /absolute/path/to/repository --json`
in a terminal. Check the reported Git root and sidecar paths, then confirm the
Desktop configuration uses that same binary and repository. Doctor reports
credential presence; it does not verify authentication. A provider login error
from an ordinary review or commit hook is separate from this MCP connection.

If a tool reports changed source or engine identity, prepare again with the
current binary and source. If it reports a busy session, let the current
operation finish before retrying. An incomplete report requires the remaining
jobs or reported coverage failures to be resolved; reconnecting alone does not
complete it.

The server uses newline-delimited JSON-RPC on stdin/stdout; diagnostics go to
stderr. A frame may contain at most 16 MiB before its newline. Oversized input
receives an error and closes the server. Request IDs must be strings or signed
64-bit integers. Batches, fractional IDs and null IDs are rejected. After
`initialize`, the client must send `notifications/initialized` before tools.

One tool operation runs at a time; concurrent calls receive a busy error.
Ping and cancellation remain responsive during that operation. Cancellation
suppresses its response but does not terminate analyzer subprocesses or roll
back a completed atomic state update. EOF ends the server without waiting
indefinitely for analyzer completion. Inspect the persisted run after restarting
before retrying a submission.

Official references: [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle),
[tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools),
[local-server configuration](https://modelcontextprotocol.io/docs/2026-07-28/develop/connect-local-servers).
