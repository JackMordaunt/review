# Stanza spacing

You are given whole function bodies the change touches. Each line is numbered;
a `+` after the number marks a line the change adds. A body reads in stanzas: runs
of lines doing one step, separated by a single blank line. Report only stanzas an
added line joins or breaks, and cite the added line where the break belongs.
Every finding is `consider`: spacing never blocks a change.

- `stanza-glued-resource` — a resource's setup and teardown run straight into
  the loop or call that uses it, or into the code before it. Setup and teardown
  are a stanza of their own even when the teardown is not a `defer`: an open and
  its close, a lock and its unlock, a make and its delete.
- `stanza-glued-loop` — a loop runs straight into a different step before or
  after it. The loop's own state belongs to its stanza: the accumulator, cursor,
  builder or buffer declared just before it and filled by it. So does the line
  just after it that returns or hands on what it built.
- `stanza-glued-step` — two different steps run together with no blank line
  between them, each one a reader would name in its own phrase: parse the input,
  then write the report. A guard clause belongs to the work it guards, and a
  declaration to the line that uses it; neither is a separate step.
- `stanza-split` — a blank line splits one step in two, such as a declaration
  parted from the only line that fills it.

Judge against the spacing the surrounding unchanged code uses. If it glues the
same shapes the change glues, say nothing. A body of five lines or fewer is one
stanza. Lines the change did not add are not yours to report, nor is a stanza
only they form. A `defer` running straight into the code after it is measured
before you read (`stanza-glued-teardown`); do not report it again. Say nothing
about formatting a formatter owns: indentation, brace placement, line length.
