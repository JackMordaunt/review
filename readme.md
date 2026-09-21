# review

Reads a change the way several narrow readers would, and reports what they noticed.

It is **advisory**. It never fails a build and never blocks a commit — the deterministic
checks a repository already runs are what should do that. This looks at what those
checks cannot: whether a name says what the thing is, whether a fact is already stated
somewhere else, whether a test can fail, whether a comment claims something nobody
verified.

```
review                 the staged change
review HEAD^..HEAD     the last commit
review --json          for an agent rather than a person
review --show          what each job would be sent, without asking anything
review --fresh         the change again, asking rather than replaying the cache
review --no-verify     skip the second reading that verifies the findings
```

## The jobs

Each is a separate call, run at once, given only the part of the change it needs. A job
that reads less is cheaper and harder to distract into reporting something another job
owns.

| job | reads | asks |
|---|---|---|
| `duplication` | new declarations + existing ones that resemble them | does the repository already state this? |
| `tests` | whole test functions the change adds | could this test fail? |
| `namer` | new and renamed declarations, with their doc comments | does the name say what the thing is? |
| `claims` | comment lines the change adds | does anything support this assertion? |
| `hygiene` | the commit message, the file statistics, recent subjects | does the message match the commit? |

The candidate list the `duplication` job judges is built by parsing the repository, not
by searching it. A pattern over lines misses an indented constant inside a block, which
is exactly where a duplicated fact tends to live.

## The static checks

Eleven checks run before anything is asked of a provider, and whether or not one can be
asked. Seven measure the commit message; one measures the change against the
repository's history; two hold the review to itself. A twelfth runs the repository's own
analyser when it is installed: staticcheck, on the packages the change touches.

| check | reads | asks |
|---|---|---|
| `staticcheck/<code>` | the analyser's findings, on the lines the change adds | is the code the analyser argues about? SA faults report as must-fix, unused code and simplifications as consider, style as note |
| `message-low-entropy` | the Shannon entropy of the message, in bits per byte | is this one phrase repeated rather than a description? |
| `message-boilerplate` | the share of its length the message keeps after zlib | is this one block of text pasted whole? |
| `message-common-words` | each word's rarity in the repository's own subject history | is this made only of the words this repository says most, naming nothing in the change? |
| `message-frustration` | the message's words against a short exclamation list | is this the author's reaction — oops, whoops, damn — rather than a description? |
| `message-not-imperative` | the subject's first word after its package prefix | does the subject open as a command — not past tense, not a gerund, not the author? |
| `message-no-body` | the diff's size in changed lines | does a change over 50 lines say anything below the subject at all? |
| `message-long-body` | the body's word count | is the body over 150 words, listing what the diff already shows? |
| `history-coupled-file` | each changed file's co-changes over the last 1,000 commits, as a Jaccard | does history tie this file to a partner the change does not touch — the test beside the code, the header beside the source, the golden file beside the renderer? |
| `suppression-added` | dismissal comments the change adds | is the change dismissing what the readers would have found, before the readers ran? |
| `test-deleted` | test functions the change removes, in Go, TypeScript and JavaScript | is the change deleting the tests that would have failed? |

The first two are calibrated against the 21,000 commit messages on this machine, and
fire below every one of them: under 3.2 bits per byte, where ordinary messages measure
3.7–4.9; under 20% of length, where none kept less than 26%. Entropy says nothing about
a message under 40 bytes, and zlib nothing about one under 400 — a short subject is
low-entropy whatever it says, and framing dominates the ratio below that.

The staticcheck check needs the binary on the path and a `go.mod` at the repository
root; without either it says nothing, and a run that cannot finish inside five minutes
is abandoned rather than holding the review. Findings land only on lines the change
adds — the analyser is free to say what it likes about the rest of the repository, and
the review's contract is the change. A range is analysed on the tree the range arrived
at, materialised to a scratch directory. Dismiss one where it is wrong:

```go
//review:ignore staticcheck/S1002 the comparison states the contract
```

The third needs a history to measure against, so it says nothing in a repository
younger than a hundred commits. Against 23,956 measured messages it fires on sixteen,
every one of them a message such as `fix`, `fix ci`, `Fix fix.` — and on nothing else.
A message is spared when any word is rarer than a fifth of the history, when it names
anything the diff adds, removes or touches (`Update requests.ts`), when it carries a
number (`Bump to 2.0.26`), or when it is a merge or squash subject, which is git's
prose rather than the commit's.

The coupling check is the one that is not about the message: it is counted from
`git log` alone, so it works for every language and sees pairs the compiler cannot —
a frontend component and the test beside it, a C source and its header, a renderer
and its golden files. It is counted over the last thousand commits before the change,
never over the change itself, and commits listing over a hundred files are left out:
a sweep touching everything once says nothing about any pair. It asks about at most
three pairs, and only those that still exist at the end of the change. Measured fire
rate on sampled history: 3.6% of commits at J ≥ 0.7 with at least 5 shared commits —
12% at J ≥ 0.5, which is why the threshold sits where it does.

The last two are about gaming the review itself. `suppression-added` reads every
dismissal comment the change adds — a suppression that the readers have not seen yet,
nameable before they run — and reports it as must-fix; the report carries no file and
so cannot be dismissed itself. The prose that documents the mechanism does not count,
and neither does a comment in a file no reader reads. `test-deleted` reads the test
functions the change removes and reports each file that lost one, must-fix; a test
that was renamed is spared, judged name-word by name-word, and a deleted test that
survived as a new test elsewhere in the change is spared the same way.

They catch a large change that never explains itself — unless the diff only moves
text around, which its subject describes — a body that explains past its point,
text repeated or pasted — `asdf asdf asdf`, a licence notice, a dumped log
— a message made only of the repository's usual words, and a message that is only an
exclamation. Words that history shows describing code legitimately are not markers:
Odin says `stupid UB` and implements `dumb PtrMap`, and `finally` and `eventually`
belong to real prose. Verbs whose past and imperative share a form — read,
set, split — are spared, as are articles, because an explainer may be a noun
phrase on purpose. They do not catch fluent emptiness: `do the needful` and
`updated the thing` measure like prose and their words are rare precisely because
nobody writes them, so no frequency count will hold them. That is the `hygiene` job's.

## Criteria

`criteria/*.md` holds the rules, one file per job, each rule with an id. **Every finding
must cite one**, and a finding citing anything else is dropped before you see it. That
is deliberate: it makes the criteria the thing you tune, rather than the prompt, and it
stops a job inventing a standard on the spot.

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
holds, or it does not, with a reason. A finding that falls is reported as a retraction
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
the ordinary way.

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
`id` (stable across runs while the finding stands), `verified` (only the verify pass can
say true; static checks are their own word), `severity`, and the `rule` id from the
criteria it cites. A retraction carries the finding it ends and the verdict's `reason`.
`usage` is always present, and counts `replayed` answers rather than tokens when the
answers were cached; `usd` is 0 unless the provider reports a cost.

## Who answers

Nothing here cares which model answers. A provider takes a prompt and returns text.

| `--provider` | how | credentials |
|---|---|---|
| `chain` (default) | probes the configured order — the console API first, then `pi` against the local gateway — and the first that answers serves the whole reading | whichever entry it lands on holds |
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

`eval_test.go` holds the cases with a known right answer — two revisions of a corpus
repository and three written for the purpose — and scores a reading against them. It is
off unless asked for, because it is the only thing here that spends money:

```
go test -run TestEval -eval=1              # one reading of each case
go test -run TestEval -eval=3 -eval.show   # three, printing every finding
go test -run TestEval -eval=1 -eval.cases=duplication
```

`REVIEW_EVAL_CORPUS` names the repository the corpus cases read; they skip without it.
More than one run per case is worth having: a single reading walks between the two
failure directions rather than sitting at one.

A case says what a reading must find and what it must not raise. The silences matter
more: the persistent failure is reporting something true and unwanted, and every rule
in `criteria/` that reads like an exception was written to stop one.

## What it is not

It does not check formatting, vet, lint, dead code, or vulnerabilities. Those have
deterministic tools that are better at it, cost nothing to run, and can be trusted to
gate a merge. Point this at what is left over.
