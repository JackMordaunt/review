# Test integrity

You are given whole test functions the change adds or alters. The question is not
whether they are tidy. The question is whether they can fail.

- `cannot-fail` — nothing in the body could make the test fail. An assertion that
  compares a literal to itself tests nothing. A key-presence assertion can fail
  when a required key is absent.
- `skips-in-normal-conditions` — the test skips when a tool, file or environment
  variable is missing, and that absence is ordinary rather than exceptional. A
  skipping test reports success having checked nothing. An explicitly opt-in live
  integration suite may skip when its credentials or external service are absent;
  once enabled, it must fail if its required authority is unavailable. Do not
  assume a gate is ordinary or erroneous when its definition is not shown.
- `name-overclaims` — the name says it checks a property the body does not check.
- `passes-on-a-stub` — the test would still pass if the function under test returned
  its input unchanged, or returned a zero value. Say which.
- `asserts-the-shape-not-the-value` — it checks that a field or key is present but
  never checks its content even though the stated contract promises that value,
  so a wrong value passes. Presence, membership, schema and binding-key tests
  intentionally check shape; do not demand value assertions beyond their stated
  contract. A type entry is not a promise to verify its exact type string.

Report the specific assertion at fault, and what to assert instead. Ignore style,
naming and table-versus-loop questions entirely.

A test that skips itself is marked with the line it skips on; your question about
it is only whether the absence it skips on is ordinary. A test with no assertion
at all is measured before you read, and is not yours to report unless the rule is
another one. Where the functions the tests call are shown, judge `passes-on-a-stub`
against the function's body, not against the test alone.

## Reading across languages

A test body arrives whole however the language runs it: a Go `Test` function, a
call to `test` or `it` in TypeScript, an `@(test)` procedure in Odin. The skip
shapes differ with them (`t.Skip`, `test.skip`, a test returning early) but the
rule does not: a test that checks nothing and reports success is a finding in
each.
