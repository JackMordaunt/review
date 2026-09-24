# review

Reads a change the way several narrow readers would, and reports what they noticed.

It is **advisory** unless asked to gate. By default it never fails a build and never
blocks a commit — the deterministic checks a repository already runs are what should do
that; `--exit-code` lets a hook make it one of them. It looks at what those checks
cannot: whether a name says what the thing is, whether a fact is already stated
somewhere else, whether a test can fail, whether a comment claims something nobody
verified — and, before any of that is asked of a model, at everything about the change
that a comparison can settle.

```
review                          the staged change
review HEAD^..HEAD              the last commit
review --json                   for an agent rather than a person
review --show                   what each job would be sent, and what the static checks found
review --fresh                  the change again, asking rather than replaying the cache
review --no-verify              skip the second reading that verifies the findings
review --message-file "$1"      the staged change with the message a commit-msg hook is given
review --exit-code              exit 1 when a must-fix finding stands, for a hook
review --baseline last.json     which findings resolved, persist, or are new since that report
review rules [job | rule]       what a finding was judged against
review rules -dismissed         how often each rule is dismissed in this tree, and why
review bench [-n 200] [-author x] [-rule id]   fire rate of every static check over recent commits
review hook install             the commit-msg hook that makes the review a gate
review agent                    what an agent's instructions should say about this tool
```

## Building

The tool is written in Odin, on the `jm` collection (`~/Source/Personal/jm`), and
reads each language through a sidecar built on that language's own parser. `just build`
compiles the four binaries into `build/`; `just install` puts them beside each other on
the path: `review`, `review-go` (Go's parser, from `sidecar/gofront`), `review-vet` (go
vet's multichecker, from `sidecar/govet`) and `odin-review-extract` (Odin's parser, from
`sidecar/odin`). `just test` type-checks and runs every package's tests and the Go
sidecar's. The repository's own `ols.json` names the collection for the editor and for
the `odin-check` analyser.

## The jobs

Each is a separate call, run at once, given only the part of the change it needs. A job
that reads less is cheaper and harder to distract into reporting something another job
owns.

| job | reads | asks |
|---|---|---|
| `duplication` | new declarations + existing ones that resemble them | does the repository already state this? |
| `tests` | whole test functions the change adds, with the functions they call and the line each skips on | could this test fail? |
| `namer` | new and renamed declarations, with their doc comments | does the name say what the thing is? |
| `claims` | comment lines the change adds, in their blocks, with the code beneath each | does anything support this assertion? |
| `hygiene` | the commit message, the file statistics, recent subjects | does the message match the commit? |

The candidate list the `duplication` job judges is built by parsing the repository, not
by searching it. A pattern over lines misses an indented constant inside a block, which
is exactly where a duplicated fact tends to live. The list is ranked: names sharing more
whole words first, then the same kind, then the same file — `cache` no longer pulls in
every `Cached` field — and cut at twelve. The `tests` job is shown the bodies of the
functions its tests call, found by name in the same index, so that whether a test passes
on a stub is judged against the function rather than guessed. The `claims` job is shown
two lines of code beneath each comment block, so that `stale` can be judged against what
the change does; a comment whose every word is in the line below it is never a claim, and
is kept out of the packet and measured by a static check instead.

## The static checks

Twenty-seven checks run before anything is asked of a provider, and whether or not one can
be asked. Seven measure the commit message; one measures the diff's shape; one measures
the change against the repository's history; two hold the review to itself; sixteen
measure the code the change adds. Then the repository's own compilers and analysers run,
each with its strictest settings and asked for JSON, over the units the change touched.
Static analysis is cheaper than a reading, so wherever a rule turned out to be a
comparison rather than a judgement it was moved here — three naming rules and the
plainest case of a test that cannot fail came out of the criteria that way.

| analyser | runs | reports |
|---|---|---|
| `go-build` | `go build -json` on the packages the change touched | a compile error, must-fix wherever it lands |
| `go-vet/<analyzer>` | `go vet -json`, with `-vettool=review-vet` when that is installed | vet's default set and `nilness` as must-fix; `shadow` and `unusedwrite` as consider; the `modernize` suite as note |
| `staticcheck/<code>` | `staticcheck -f json` on the same packages | SA as must-fix, S and U as consider, style as note |
| `odin-check` | `odin check <pkg> -vet -strict-style -json-errors -no-entry-point` per package touched | a type error must-fix wherever it lands; `/vet` (unused, shadowing) consider; `/style` note |
| `tsc/<code>` | `tsc --noEmit --pretty false -p tsconfig.json` per project touched, under the project's own strictness | a type error, must-fix wherever it lands; working tree only, since it needs `node_modules` |
| `ruff/<code>` | `ruff check --output-format json` on the changed files | pyflakes codes consider, style codes note |
| `mypy/<code>` | `mypy --output json --ignore-missing-imports` on the changed files | a type error must-fix; working tree only |
| `cargo/<code>` | `cargo clippy --message-format json`, or `cargo check` without clippy, per crate touched, into the repository's own target directory | an error must-fix wherever it lands, a warning consider |
| `semgrep/<rule>` | `semgrep scan --json` under the repository's `.semgrep.yml`, or `--config p/default` without one, on the changed files it can parse | the rule's own severity: ERROR must-fix, WARNING consider, INFO note |

Each analyser runs only when its binary is on the path and the tree has what it needs, and
says on stderr why it did not. The rule for what belongs to the change is the same for
all of them: a **fault** — the compiler cannot build the unit — is the change's wherever
the error lands, because the tree does not compile until it is answered; an **opinion**
is the change's only on a line the change added. A run that cannot finish inside five
minutes is abandoned rather than holding the review. A range is analysed on its
materialised tree; the two analysers that need the working tree's surroundings say so
and skip.

`review-vet` is the multichecker in `sidecar/govet`: vet's own analysers plus the ones
from `golang.org/x/tools/go/analysis/passes` that vet leaves out — `nilness` (nil
dereferences and impossible comparisons, from SSA), `atomicalign`, `deepequalerrors`,
`httpmux`, `reflectvaluecompare`, `scannererr`, `sortslice`, `sqlrowserr`, `shadow`,
`unusedwrite`, and the `modernize` suite. `just install` builds it and puts it on the
path beside `review`.

Without it, vet runs its default set. `fieldalignment` is left out on purpose: it is
noise on any struct not on a hot path.

| check | reads | asks |
|---|---|---|
| `message-low-entropy` | the Shannon entropy of the message, in bits per byte | is this one phrase repeated rather than a description? |
| `message-boilerplate` | the share of its length the message keeps after zlib | is this one block of text pasted whole? |
| `message-common-words` | each word's rarity in the repository's own subject history | is this made only of the words this repository says most, naming nothing in the change? |
| `message-frustration` | the message's words against a short exclamation list | is this the author's reaction — oops, whoops, damn — rather than a description? |
| `message-not-imperative` | the subject's first word after its package prefix | does the subject open as a command — not past tense, not a gerund, not the author? |
| `message-no-body` | the diff's size in changed lines | does a change over 50 lines say anything below the subject at all? |
| `message-long-body` | the body's word count | is the body over 150 words, listing what the diff already shows? |
| `message-names-unknown` | each identifier-shaped word of the message — camel or snake case, a path, a call, anything in backticks — against the diff and every file in the tree | does the message name code that is nowhere in the repository? |
| `formatting-mixed-in` | git's count of changed lines with and without whitespace | is half the diff reformatting, with at least ten lines of logic hidden in it? |
| `history-coupled-file` | each changed file's co-changes over the last 1,000 commits, as a Jaccard | does history tie this file to a partner the change does not touch — the test beside the code, the header beside the source, the golden file beside the renderer? |
| `suppression-added` | dismissal comments the change adds | is the change dismissing what the readers would have found, before the readers ran? |
| `test-deleted` | test functions the change removes, in Go, TypeScript, JavaScript, Python and Rust | is the change deleting the tests that would have failed? |
| `no-stutter` | each exported name's first word against its package | does `ico.IcoEntry` say ico twice? `time.Time` is the idiom and is spared |
| `no-shadow` | each new name against Go's predeclared identifiers and standard library packages, the JavaScript runtime's globals, or Python's builtins | does the name take a word the language already uses? |
| `abbreviation` | each word of a new name against a short list | is this `cfg`, `mgr`, `hdlr`, `svc`, `btn`, `cnt`: a word the reader expands rather than reads? |
| `test-no-assertion` | each added or altered test's body | is there any call in it that could fail it — or does it pass whatever the code does, and fail only by crashing? |
| `assertion-always-true` | each assertion in an added or altered test | does it assert a literal true, two literals, or a value against itself? |
| `duplicate-body` | each new function's tokens against every function in the repository and the change | is this body already written — token for token (must-fix), or in shape with every name changed (consider)? |
| `function-too-long` | each new function's line count | is it over 150 lines? 95% of measured functions fit in 109 |
| `nesting-too-deep` | each new function's block depth | does it nest more than 5 deep? 99% of measured functions stay within 6 |
| `comment-restates-code` | each added comment's words against the line below it | does the comment say only what the code says? |
| `todo-without-reference` | each added TODO, FIXME, XXX or HACK | does it name an issue, a ticket, a link or a person? |
| `commented-out-code` | runs of added comment lines | is this code kept as a comment — two statement-shaped lines, or one beyond doubt? |
| `debug-leftover` | added lines against the debugging shapes of each language | is this a `debugger`, a `breakpoint()`, a `dbg!`, a `spew.Dump`, a `console.log`, a `DEBUG` print? |
| `error-swallowed` | added lines against the dropping shapes of each language | is this `_ = err`, an empty `catch`, an `except` that passes? |
| `new-symbol-unreferenced` | each new declaration's name as a whole word over every text file in the tree | does anything refer to it but its own line? A doc comment does not count |
| `code-without-tests` | the added lines by file kind, and the tree's test files | does a change of 50 or more code lines touch no test, in a repository that keeps them? |

The first two are calibrated against the 21,000 commit messages on this machine, and
fire below every one of them: under 3.2 bits per byte, where ordinary messages measure
3.7–4.9; under 20% of length, where none kept less than 26%. Entropy says nothing about
a message under 40 bytes, and zlib nothing about one under 400 — a short subject is
low-entropy whatever it says, and framing dominates the ratio below that.

Dismiss an analyser's finding where it is wrong, by its full id:

```go
//review:ignore staticcheck/S1002 the comparison states the contract
```

The common-words check needs a history to measure against, so it says nothing in a
repository younger than a hundred commits. Against 23,956 measured messages it fires on
sixteen, every one of them a message such as `fix`, `fix ci`, `Fix fix.` — and on
nothing else. A message is spared when any word is rarer than a fifth of the history,
when it names anything the diff adds, removes or touches (`Update requests.ts`), when it
carries a number (`Bump to 2.0.26`), or when it is a merge or squash subject, which is
git's prose rather than the commit's.

The formatting check is git's own count: the change's lines with `--numstat`, and again
with `-w`. Sampled over 1,853 local commits, a whitespace share of one half with at
least twenty whitespace-only lines and ten of logic fires on 0.7%, and the ones it fires
on are the mixed kind.

The coupling check is the one that is not about the message: it is counted from
`git log` alone, so it works for every language and sees pairs the compiler cannot —
a frontend component and the test beside it, a C source and its header, a renderer
and its golden files. It is counted over the last thousand commits before the change,
never over the change itself, and commits listing over a hundred files are left out:
a sweep touching everything once says nothing about any pair. It asks about at most
three pairs, and only those that still exist at the end of the change. Measured fire
rate on sampled history: 3.6% of commits at J ≥ 0.7 with at least 5 shared commits —
12% at J ≥ 0.5, which is why the threshold sits where it does.

The two about gaming the review itself: `suppression-added` reads every dismissal
comment the change adds — a suppression that the readers have not seen yet, nameable
before they run — and reports it as must-fix; the report carries no file and so cannot
be dismissed itself. The prose that documents the mechanism does not count, and neither
does a comment in a file no reader reads. `test-deleted` reads the test functions the
change removes and reports each file that lost one, must-fix; a test that was renamed
is spared, judged name-word by name-word, and a deleted test that survived as a new
test elsewhere in the change is spared the same way.

The sixteen about the code read what the language frontends read — declarations with
their bodies, tests, comments — and the diff's added lines where a shape is enough.
Their thresholds were measured rather than guessed. Function length and depth were read
off 8,255 functions in the repositories on this machine: the 95th percentile of length
is 109 lines and the 99th is 257, so the cut is 150; the 99th percentile of depth is 6,
so the cut is 5. Two bodies are compared only past forty tokens, and compared in shape —
every identifier and literal replaced, the grammar's keywords kept — only past eighty:
two small wrappers share a shape because wrappers do, and the tool's own `decode` pair
is what taught it that. The reference count skips comment lines, because a Go doc
comment opens with the name it documents and a comment is not a caller; it reads every
text file in the tree, so a use from a template counts. Debugging shapes are the
statements that exist to be removed — `debugger`, `breakpoint()`, `dbg!`, `spew.Dump`
— and not ordinary printing, because a command's output and a debug print share a
function; only `console.log` is reported, and as a note. The code checks report as
consider or note: each is a comparison, and comparisons have exceptions the reader
knows and the tool does not. `duplicate-body`, token for token, and `assertion-always-true` are the must-fixes: a body
copied whole and an assertion that cannot fail have no exceptions. The tautology check
exists because of the assertion check: once a test must assert something, `assert True`
and `expect(true).toBe(true)` are what a reading that wants to pass reaches for.

Known misses of the message checks, measured against constructed bad messages: `wip`
and `temp` (under every floor — statistically indistinguishable from `coffee!`, a real
subject in the corpus); "fixed the bug by fixing the bug in the file" (43 bytes, 3.53
bits — lexically repetitive but character-diverse); fluent generic prose ("This commit
modifies the codebase…" at 4.2 bits and 0.73), which is the `hygiene` job's.

## Gating

A staged change has no commit message, and nothing measures one: the previous commit's
would be measured against work it never described, and a must-fix about a message the
author did not write is exactly what an agent will try to fix. A commit-msg hook is
given the message before the commit exists, and hands it over:

```sh
#!/bin/sh
# .git/hooks/commit-msg
exec review --message-file "$1" --exit-code
```

`--exit-code` is the one place the tool refuses: exit 1 when a must-fix finding stands
after dismissals, 0 otherwise. Without it the tool is advisory whatever it finds, and
the JSON `status` is what a stricter reader consults. An agent's harness can gate the
same way — a hook before `git commit` that runs `review --exit-code`, or one after that
runs `review HEAD^..HEAD --json` and feeds the findings back. The message file is read
the way git reads it: lines opening with `#` are the template's, not the author's.

`review hook install` writes that hook, naming the binary by its absolute path, and
prints the stanza a Claude Code harness takes, which reviews the staged change before
any `git commit` the agent runs. A hook already there is not replaced unasked. Where
`core.hooksPath` is set, git reads hooks from one directory for every repository and
ignores `.git/hooks`; the install then prints the hook and says where to put it rather
than writing to a place git will not read or to every repository at once.

The loop an agent runs is review, fix, review again, and `--baseline last.json` is what
tells it the fixes took: each finding of the new run is named against the previous
report's, and the report says which ids `resolved`, which `persisting`, and which are
`new`. Every finding also carries a `snippet`, the line it points at as it stands, so an
agent acts on most findings without opening the file.

The rules travel with the binary. `review rules` prints every deterministic check and
every job's criteria; `review rules tests` one job's; `review rules no-stutter` the one
rule a finding cited, with the lines that continue it; `review agent` the paragraph an
agent's instructions should hold — how to run the tool, how to read its report, how to
dismiss a finding, and when it may stop. An agent handed a finding can read what it was
judged against without leaving the terminal.

## Measuring the checks

The deterministic checks cost nothing to run, so their precision is measured rather
than assumed. `review bench -n 500` runs them over the last five hundred commits and
prints the fire rate per rule; `-rule message-frustration` lists the commits one rule
fired on with their subjects, which is how a threshold is argued about; `-author` narrows
the commits to one author's, which is how the checks are held against the population
they exist for — agent-authored commits, not the human history they were first
calibrated on. A rule firing on a tenth of ordinary commits is not measuring what it
claims to.

Measured on the first run of the bench, over 150 commits of the icns corpus: no message
check fired at all; `code-without-tests` fired on 9%, every one a command, a COM shell
extension or a wasm shim that has no test and was never going to; `new-symbol-unreferenced`
on 5%, of which two commits were interface methods an encoder calls by reflection and
functions cgo exports — both exempt since — and the rest exported library API and spec
constant tables, which the check cannot tell from a guess and reports as consider;
`duplicate-body` on 2%, one of them a `Decode` copied whole into a sibling package;
`message-names-unknown` once, on `gRPC`, which is a brand and exempt since.

`review rules -dismissed` is the other half of that: it counts the `review:ignore`
dismissals in the working tree per rule, with where each is and the reason given. A rule
dismissed everywhere is a rule to rewrite, and the argument against it is already
written in the source.

## Criteria

`criteria/*.md` holds the rules, one file per job, each rule with an id. **Every finding
must cite one**, and a finding citing anything else is dropped before you see it. That
is deliberate: it makes the criteria the thing you tune, rather than the prompt, and it
stops a job inventing a standard on the spot. A rule that turns out to be a comparison
leaves the criteria for a static check under the same id, and a job's criteria say which
of its former rules are measured before it reads.

## Dismissing a finding

Where a finding is wrong, say so in the source it concerns:

```go
//review:ignore already-named the zero value, taken by omission
```

Not a configuration file. The reason belongs beside the code it justifies, where a
reader meets it, and it survives a clone. `//review:ignore all <why>` dismisses
everything at that spot.

A dismissal reaches a few lines either side of itself, so one can answer a finding you
did not mean it to. `--verbose` names each finding it dismissed and the reason given.
The one dismissal that cannot be written is one that answers the suppression check
itself: a finding with no file behind it is not dismissible by anyone.

## A second reading verifies

After every job has answered, each job with findings is asked once more, with its
findings listed and the same evidence it read the first time, and answers for each: it
holds, or it does not, with a reason. A note is not put back: nothing gates on a note, so
a second reading of one buys nothing, and it stands marked unverified. A finding that falls is reported as a retraction
rather than deleted — the first reading's word and the second's are both on the record,
with the reason. The pass is advisory like the rest: a job that cannot be asked again
leaves its findings standing, marked unverified, and reports why.

A finding the verdict list omits stands rather than falls, marked verified: a strict
pass would let one dropped number retract everything the reading found. `--no-verify`
skips the pass — useful when the answer itself is being tested, since then the review is
one ask per job, deterministic against a frozen provider.

Retractions are verified like everything else: each retracted finding carries an id, so
an agent can answer it — restore the test, rewrite the comment — and read the next run
to confirm the finding stayed retracted.

## Packets that do not fit

A job's subject over 16 KB is asked in parts, cut file by file into runs that each fit,
and each part is asked, cached and verified on its own, against its own evidence. The
tests packet of one seven-file change measured 22 KB and was killed at the ask timeout on
a slow local gateway; in parts, each ask is one that gateway finishes, and a part whose
files did not change replays from the cache while the others are asked. The hygiene job
reads the message and cannot be cut.

## The answer cache

Every answer is keyed by the provider and the exact prompts that produced it, and
recorded under `os.UserCacheDir()/review/answers.json` (usually
`~/.cache/review/answers.json`). A second run of the same change asks nothing: it
replays the recorded answers, reports `replayed` in the usage instead of token counts,
and returns the same findings — ids and verdicts included. That is what makes a loop
deterministic: the finding and the retraction come back the same way until the change,
the criteria or the model changes.

`--fresh` asks rather than replays, and records what it learned, so the cache is
replaced rather than grown stale. The cache holds the 4,000 newest answers; a file it
cannot read is replaced on the next save, and a prompt the cache cannot answer is asked
the ordinary way. Only an answer the tool can read is recorded: a model that spent its
whole output budget and said nothing was once replayed on every run, and the job failed
the same way each time without asking again.

## The JSON contract

`--json` writes one object, so an agent can read the whole measurement without parsing
prose:

```json
{
  "version": 1,
  "provider": "pi/maple/glm-5-3-flash",
  "status": "complete",
  "findings": [],
  "retracted": [],
  "failed": [], "skipped": [], "uncovered": [], "dismissed": [],
  "truncated": false,
  "usage": {"in": 3327, "out": 15550, "cached": 0, "replayed": 5, "usd": 0}
}
```

`status` is what keeps an empty findings list from being read as a pass: `empty` (no
change), `complete` (every job answered, every file read), or `incomplete` — when a job
failed, a file no reader could read, or the diff was cut to fit. A finding carries its
`id`, `verified` (only the verify pass can say true; static checks are their own word),
`severity`, and the `rule` id from the criteria it cites. A retraction carries the
finding it ends and the verdict's `reason`; a dismissal carries the finding and the
reason written in the source, named like the rest. `usage` is always present, and counts
`replayed` answers rather than tokens when the answers were cached; `usd` is 0 unless
the provider reports a cost.

The id is a hash of what a finding is about, not where it sits or how it was worded:
job, rule, file and symbol. The line is left out because lines move under edits that do
not touch the finding; a model's message is left out because a fresh reading words the
same finding differently, and an id that changed with the wording would name nothing.
A finding with no symbol is told from its neighbours by its line; a deterministic
check's message is part of what it is about — the coupled partner, the measured number
— and stable, so it stays in. Two findings that still hash the same are told apart by a
counter: `a1b2c3d4e5f6`, `a1b2c3d4e5f6-2`.

## Who answers

Nothing here cares which model answers. A provider takes a prompt and returns text.

| `--provider` | how | credentials |
|---|---|---|
| `chain` (default) | probes the configured order — the console API, then `claude` on the path, then `pi` against the local gateway — and the first that answers serves the whole reading | whichever entry it lands on holds |
| `claude` | the coding assistant on the path, `-p --output-format json` | whatever it already holds |
| `api` | the console API directly | `ant auth login` or `ANTHROPIC_API_KEY` |
| `pi` | `pi -p --mode json`, which speaks to several providers of its own | its own; name the upstream in `REVIEW_PI_PROVIDER` |
| `command` | anything at all: `REVIEW_COMMAND` is the command line, `REVIEW_COMMAND_FIELD` the JSON field its answer arrives in | its own |

`--model` names the model in whatever form that provider uses. `REVIEW_PROVIDER` and
`REVIEW_MODEL` set the defaults.

The chain is for the hours when a limit is spent: one cheap ask per skipped entry,
the reason on stderr, and the reading happens on whatever still answers. `REVIEW_SERIAL`
asks a provider's jobs one at a time, for providers that cannot take concurrent reads.

The default model is the middle one, not the smallest. Against the eval set the
smallest reads the shortlist of duplicates and reports the first one it finds rather
than all of them — roughly two thirds of the wanted findings, and never both of a pair
in one reading. That is the one thing this tool is for, so it is not a saving.

Only the `api` provider can enforce the answer's shape, through a strict tool schema.
The rest are asked for JSON in the prompt and the object is taken out of whatever they
wrap it in, so every provider answers the same way whether or not it can be held to it.
It also pins sampling, which the others cannot: a loop between two models converges
faster when one of them answers the same way twice.

Measured, one job over a seven-file commit through `claude`: **$0.19 at the default
model**, $0.06 at the smallest. A whole change, all five jobs, is a few times that. The
same packet through `api` costs a fraction of a cent — the difference is the
assistant's own harness, which these jobs do not use. Convenience has a price and this
is it.

Prompt caching does work through `claude`, but what it caches is that harness: about
22,000 tokens, the same count on every job however different their criteria. The
criteria themselves are appended after it and are not cached. The `input_tokens` that
provider reports is 9 whatever it was sent, so `total_cost_usd` is the only figure from
it worth reading.

## The eval set

There is none yet. The Go implementation this tool replaced scored readings against
cases with a known right answer; that harness went with it. Until one exists here, the
measure of a reading is the side-by-side run the port was checked with: both tools on
the same change, the reports diffed field by field, and the answer cache shared so a
replayed answer is compared rather than re-asked.

## Languages

Go is read through the `review-go` sidecar, built from `sidecar/gofront` on Go's own
parser, and Odin through `odin-review-extract`, built from `sidecar/odin` on Odin's;
both print one JSON shape the tool reads. TypeScript and JavaScript — `.ts`,
`.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` — are read through ast-grep when it is on the
path, by pattern; Python and Rust through the same ast-grep, by node kind — a function
is whatever the grammar calls one, and its name is read out of the match.
Every other language gets its comments read by shape, the message and history checks,
and the line-shaped code checks; the jobs that need declarations or test bodies are
skipped for its files, with a line on stderr saying so, and the files are named in the
report's `uncovered` list. The repository is read by the
tool itself: git is asked for the diff, the history and one archive of the tree, and
everything after that is a loop over memory, the same on every system.

## What it is not

It does not format, and it writes no analyser of its own where a language already has
one: the compilers, vet, staticcheck, clippy, ruff, mypy and semgrep are run as they
are, with their strictest settings, and their word is kept to the change. The code
checks here measure what those tools leave alone — a test that asserts nothing, a body
written twice, a name nothing refers to — and hand the rest to the readings.
