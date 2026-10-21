<h1 align="center">review</h1>

<p align="center"><b>review</b> reads a change before you commit it and says what a careful reviewer would.<br>Static checks first, narrow model readings second. Built for agent loops. The command is <code>review</code>.</p>

## Install

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/badge-linux-dark.svg">
  <img src="branding/badge-linux-light.svg" alt="Linux" height="36">
</picture>

```sh
curl -fsSL https://mordaunt.dev/code/review/install.sh | sh
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/badge-macos-dark.svg">
  <img src="branding/badge-macos-light.svg" alt="macOS" height="36">
</picture>

```sh
curl -fsSL https://mordaunt.dev/code/review/install.sh | sh
```

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="branding/badge-windows-dark.svg">
  <img src="branding/badge-windows-light.svg" alt="Windows" height="36">
</picture>

```powershell
irm https://mordaunt.dev/code/review/install.ps1 | iex
```

Each one downloads the release for your machine, checks every hash before
installing anything, and puts `review` and its three language sidecars in
`~/.local/bin`.

Then, in any git repository with something staged:

```sh
review
```

## What it looks at

Your compiler, linter and tests already say whether the code builds and
runs. review asks what they cannot:

- Does the repository already state this somewhere else?
- Could this test ever fail?
- Does the name say what the thing is?
- Does anything support what this comment claims?
- Does the commit message describe the commit?

Each question is its own narrow job, sent only the part of the change it
needs. A job that reads less costs less, and is harder to distract into
reporting what another job owns.

## Made to converge

An agent's loop is review, fix, review again. Everything here exists to make
that loop end.

- **Comparisons before judgement.** Deterministic checks of its own, and the repository's own compilers and linters, run before any model is asked, and still run when none can be.
- **Every finding cites a rule.** A finding that cites none is dropped before you see it. `review rules <rule>` prints what it was judged against.
- **A second reading.** Each finding is read again with its evidence. One that falls is reported as retracted, with the reason, never silently dropped.
- **The same answer twice.** Answers are cached by the exact question asked, so an unchanged change replays and costs nothing. Ids hash what a finding is about, not where it sits, so they survive edits.
- **Progress you can read.** `--baseline last.json` names which findings resolved, which persist, and which are new.
- **Dismissals live in the source.** `//review:ignore <rule> <why>` beside the code it justifies, not in a config file. One added by the change under review is itself a must-fix.
- **Advisory unless asked.** It never fails a build or blocks a commit until `--exit-code` says it should.
- **Any model.** The console API, the `claude`, `grok`, or `pi` CLIs, or any command that reads a prompt and prints an answer.
- **Keeps itself current.** `review update` fetches a signed release. It never updates unasked.

## What a review costs

The static checks cost nothing: they compare, they do not ask. The readings
are what cost money, measured over one job on a seven-file commit:

| provider | one job |
|----------|--------:|
| `claude`, default model | $0.19 |
| `claude`, smallest model | $0.06 |
| `api` | a fraction of a cent |
| replayed from the cache | nothing |

A whole change runs several jobs and costs a few times that. The gap between `claude` and `api` is the assistant's own harness, about
22,000 tokens a call, which these jobs do not use. The default model is the
middle one on purpose: the smallest found about two thirds of the wanted
duplicates, and never both halves of a pair in one reading.

A check that fires on everything is noise, so each one's fire rate is
measured rather than assumed. `review bench -n 500` runs them over your last
500 commits; `-rule <id>` lists the commits one rule fired on.

Odin reviews also check that `main` packages live under `cmd/` and that
command-line parsing belongs to one `cli` package. A focused `odin` job
judges avoidable allocations, temporary strings that can use stack buffers,
entry points that should delegate their logic, and allocator parameters that
make allocation visible and caller-controlled. It also checks that allocation
and release use matching allocators, respecting containers that retain theirs.
Borrowed-memory checks catch local array slices and strings that escape their
storage, with inference for other proven lifetime violations. Owning-copy checks
catch two local headers freeing the same explicitly heap-allocated container;
inference covers other established ownership violations. Partial-construction
checks catch heap storage lost on later failure returns; inference covers
other resources with established acquisition and cleanup contracts. Container
checks catch local borrows used after potentially reallocating growth, with
inference for established mutations through helpers. A 512-byte environment
buffer is a use-case assumption; replacements must preserve overflow handling
and keep borrowed strings within the buffer's lifetime.

## Use

```
review                          the staged change
review HEAD^..HEAD              the last commit
review --json                   one JSON object, for an agent
review --show                   what each job would be sent, and what the checks found
review --fresh                  ask again rather than replay the cache
review --exit-code              exit 1 when a must-fix finding stands, for a hook
review --baseline last.json     which findings resolved, persist, or are new
review --message-file "$1"      the staged change with a commit-msg hook's message
review rules [job | rule]       what a finding was judged against
review rules -dismissed         each rule's dismissals in this tree, and why
review bench [-n 200]           each check's fire rate over recent commits
review hook install             the commit-msg hook that makes review a gate
review agent                    what an agent's instructions should say
review version                  which release this is
review update                   fetch the latest release
```

Flags go before the revision. `--provider` and `--model` pick who answers;
`REVIEW_PROVIDER` and `REVIEW_MODEL` set the defaults.

## Give it to your agents

```sh
review agent >> AGENTS.md
```

That appends the paragraph an agent needs: run `review --json`, fix every
`must-fix`, weigh each `consider`, dismiss a wrong finding in the source,
and stop when nothing must-fix persists.

To make it a gate rather than advice:

```sh
review hook install
```

That writes a commit-msg hook that refuses a commit while a must-fix finding
stands, and prints the stanza that does the same for Claude Code before any
`git commit` it runs.

## Languages and tools

Go and Odin are read through their own parsers, shipped as sidecars.
TypeScript, JavaScript, Python, Rust, Java and shell are read through
[ast-grep](https://ast-grep.github.io) when it is installed. Any other
language still gets its comments, its commit message and its history
checked.

Whatever the repository already uses is run for it, at its strictest, and
kept to the lines the change touched: `go vet`, `staticcheck`, `odin check`,
`tsc`, `ruff`, `mypy`, `cargo clippy`, `semgrep`, `shellcheck`, `actionlint`
and `zizmor`. Each runs only when it is on PATH, and a skip is said on
stderr, so a check that is not running can be told from one that found
nothing.

## Releases

Releases are tagged by calendar, as Odin's are: `dev-2026-10`, then
`dev-2026-10a` for a second that month. A `dev-2026-10-rc1` tag is a release
candidate; the installers and `review update` never offer one unless it is
asked for by name:

```sh
curl -fsSL https://mordaunt.dev/code/review/install.sh | REVIEW_VERSION=dev-2026-10-rc1 sh
```

At a terminal, review checks once a day and says when a newer release is
out. Hooks, agents and pipes never see the check; `REVIEW_NO_UPDATE=1`
turns it off.

## Build from source

Needs [Odin](https://odin-lang.org), [Go](https://go.dev) and
[just](https://just.systems). CI builds with the Odin commit named by
`ODIN_PIN` in `.github/workflows/release.yml`; other versions may not link.

```sh
git clone --recursive https://mordaunt.dev/code/review && cd review
just install
```

## Learn more

[ARCHITECTURE.md](ARCHITECTURE.md) explains every check and job, the JSON
contract, the cache, the providers, how releases are signed, and what each
directory in this repository is for.

## Licence

Apache-2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
