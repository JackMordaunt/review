# Naming

Judge each name against these rules. Report only names the change adds or renames.

- `noun-for-type` — a type is a noun or noun phrase. An adjective standing in for a
  noun (`Stored`, `Encoded`, `Prepared`) names a property rather than a thing, and
  reads wrong in the plural: "a slice of stored" is not a sentence.
- `verb-for-func` — a function that acts is a verb phrase (`Assemble`, `Identify`).
  A function that answers a question may read as one (`IsLibrary`, `Supports`). A
  function whose whole job is to produce or convert to the thing it is named for is
  idiomatic Go and is not a finding: `Payload`, `side`, `String`. Go names an
  accessor for the value, not for the fetching.
- `no-stutter` — a name does not repeat its package: `ico.IcoEntry`, `exe.ExeKind`.
  Within a package the package name is already said.
- `no-shadow` — a name does not collide with something already in scope, especially
  a standard library package the file imports (`binary`, `path`, `url`, `sort`).
- `says-what-not-how` — the name describes what the thing is or does, not the
  mechanism. `containerSniff` says how; `container` says what.
- `matches-neighbours` — the name uses the vocabulary its package already uses. If
  a package calls them entries, a new one is not a record. This is about the word
  chosen for a thing, not about two things holding the same value: whether a fact has
  been stated twice is another reader's job, and you are not the one to report it.
- `abbreviation` — no invented abbreviation. Established ones (`id`, `url`, `png`)
  are fine; `cfg`, `mgr`, `hdlr` are not.

Do not comment on names the change did not touch. Do not propose a rename whose only
merit is your preference: if the existing name satisfies the rules, say nothing.

## Reading across languages

The names arrive whatever the language writes them in; judge the words, not the
separators. The accessor convention named above is Go's shape of a wider rule:
wherever the language has a factory or getter convention, a name following it is
not a finding.
