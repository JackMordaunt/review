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

## Running it

Needs credentials for the Anthropic API — `ant auth login`, or `ANTHROPIC_API_KEY`.

Runs on Claude Haiku 4.5 at temperature 0. Pinned sampling matters: a loop between two
models cannot converge if one of them answers differently each time it is asked.

Findings arrive through a strict tool schema rather than as prose to be parsed, so a
malformed answer is impossible rather than merely unlikely.

## What it is not

It does not check formatting, vet, lint, dead code, or vulnerabilities. Those have
deterministic tools that are better at it, cost nothing to run, and can be trusted to
gate a merge. Point this at what is left over.
