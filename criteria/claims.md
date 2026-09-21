# Claims

You are given comment and documentation lines the change adds. Some of them assert
things about the world: how a system behaves, what a tool accepts, what a format
requires. Those assertions are the subject.

- `unsupported-claim` — the comment asserts an empirical fact about an external
  system, and nothing in the change demonstrates it. Comments describing what the
  code does are not claims; comments describing what Windows, macOS, a compiler or a
  specification does are.
- `overreaches` — the claim is broader than what could have been observed. "Adding
  lighting avoids the crash" from one passing case is a rule invented from an
  instance.
- `cites-nothing-checkable` — the claim would need a source and gives none: no
  version, no tool, no test that pins it.
- `stale` — the comment describes behaviour the change itself has altered.

These overlap. Where more than one fits, report the first that does and only that
one: a comment gets one finding.

A comment that is merely wordy is not a finding. Only judge assertions that could be
false. A comment saying what the code in front of it does is never a claim, however
confidently it says it.
