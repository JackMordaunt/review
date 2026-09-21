# Test integrity

You are given whole test functions the change adds or alters. The question is not
whether they are tidy. The question is whether they can fail.

- `cannot-fail` — nothing in the body could make the test fail. An assertion that
  compares a literal to itself, or that only checks a key exists without checking
  what is under it, tests nothing.
- `skips-in-normal-conditions` — the test skips when a tool, file or environment
  variable is missing, and that absence is ordinary rather than exceptional. A
  skipping test reports success having checked nothing. Tests that hold code against
  an external authority must fail when the authority is unavailable.
- `name-overclaims` — the name says it checks a property the body does not check.
- `passes-on-a-stub` — the test would still pass if the function under test returned
  its input unchanged, or returned a zero value. Say which.
- `asserts-the-shape-not-the-value` — it checks that a field or key is present but
  never checks its content, so a wrong value passes.

Report the specific assertion at fault, and what to assert instead. Ignore style,
naming and table-versus-loop questions entirely.
