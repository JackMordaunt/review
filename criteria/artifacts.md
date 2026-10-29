# Build instructions, patches and test artifacts

Read the listed artifact paths in the supplied diff as source, not as opaque data.
Use surrounding source changes only to establish what an artifact must do. Report
concrete faults supported by the diff; missing context is not proof of a fault.

- `build-command-fault` — a build recipe invokes the wrong command, mishandles
  arguments, paths, quoting or failure status, or changes the intended execution
  order. Read embedded shell and interpolation as code.
- `patch-fault` — a stored patch introduces a concrete fault in the patched
  language, targets the wrong path, or contradicts the accompanying source change.
  Distinguish the outer commit diff from the patch's own added/removed lines.
- `fixture-misses-condition` — a test input no longer exercises the condition it
  claims to cover. Read source fixtures in their own language; intentional invalid
  code is valid evidence for a negative test, not a compilation fault to repair.
- `expected-output-hides-fault` — a golden output or snapshot blesses a concrete
  regression evidenced by the source change instead of asserting intended behavior.

A patch or snapshot may be a fragment of a package, not a standalone build target.
Do not invent missing declarations, dependencies or unspecified business rules.
